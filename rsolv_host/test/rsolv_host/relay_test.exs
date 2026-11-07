defmodule RsolvHost.RelayTest do
  use ExUnit.Case, async: true

  import RsolvHost.PlatformStub

  alias RsolvHost.{FakeExec, Oidc, Platform, PlatformStub, Relay, Sandbox, TokenKeeper}

  @moduletag :tmp_dir
  @sbx %Sandbox{container: "rsolv-41-7-work", exec: FakeExec}
  @body %{"pipeline_run_id" => "0b0e5f7c-7d3c-4d8e-9a55-3f6f1b0c2a11", "issue_number" => 7}

  setup %{tmp_dir: dir} do
    {:ok, io} = StringIO.open("")
    Req.Test.stub(Oidc, &Req.Test.json(&1, %{value: "e30.e30.sig"}))

    %{
      env: %{
        "RUNNER_TEMP" => dir,
        "ACTIONS_ID_TOKEN_REQUEST_URL" => "https://token.actions.example/id?v=1",
        "ACTIONS_ID_TOKEN_REQUEST_TOKEN" => "t"
      },
      io: io
    }
  end

  # `streams` is a list of SSE bodies, served one per connection (the last repeats).
  defp platform(context, streams, extra \\ fn _conn -> nil end) do
    test = self()
    connections = :counters.new(1, [])

    Req.Test.stub(Platform, fn conn ->
      extra.(conn) ||
        case {conn.method, conn.request_path} do
          {"POST", "/api/v1/runs/token"} ->
            Req.Test.json(conn, PlatformStub.token())

          {"POST", "/api/v1/validation/start"} ->
            {body, conn} = body(conn)
            send(test, {:start, body})
            Req.Test.json(conn, %{session_id: "s1", stream_url: "/api/v1/validation/stream/s1"})

          {"GET", "/api/v1/validation/stream/s1"} ->
            :counters.add(connections, 1, 1)
            send(test, :connected)
            stream(conn, Enum.at(streams, :counters.get(connections, 1) - 1, List.last(streams)))

          {"POST", "/api/v1/validation/tool_response/s1"} ->
            {body, conn} = body(conn)
            send(test, {:tool_response, body})
            Req.Test.json(conn, %{success: true})

          {"GET", "/api/v1/validation/status/s1"} ->
            Req.Test.json(conn, %{status: "streaming"})
        end
    end)

    {:ok, keeper} =
      TokenKeeper.start(role: :work, issue: 7, env: context.env, io: context.io)

    keeper
  end

  defp run(keeper, opts \\ []) do
    Relay.run_session(
      keeper,
      @sbx,
      :validation,
      @body,
      Keyword.merge([backoff_ms: [0, 0, 0, 0, 0], io: :stdio], opts)
    )
  end

  defp sandbox_answers(output) do
    FakeExec.script([{fn {"docker", ["exec" | _], _} -> true end, output}])
  end

  defp tool_calls,
    do: for({"docker", ["exec" | _] = args, opts} <- FakeExec.calls(), do: {args, opts})

  describe "run_session/5" do
    test "runs each tool request in the sandbox and posts the result", context do
      keeper =
        platform(context, [
          sse([
            {:tool_request,
             tool_request("r1", "read_file", %{"path" => "a.rb"}, timeout_ms: 60_000)},
            {:complete, %{"validated" => true}}
          ])
        ])

      sandbox_answers({:ok, %{status: 0, output: "npm warn\n{\"content\":\"x\"}\n\n"}})

      assert run(keeper) == {:ok, %{"validated" => true}}
      assert_received {:start, @body}

      assert [{args, opts}] = tool_calls()

      assert args == [
               "exec",
               "-i",
               "rsolv-41-7-work",
               "timeout",
               "-k",
               "10",
               "60",
               "rsolv-sandbox",
               "tool"
             ]

      assert opts[:input] ==
               RsolvHost.Frame.encode(%{"tool" => "read_file", "input" => %{"path" => "a.rb"}})

      assert opts[:max_bytes] == 8 * 1024 * 1024

      assert_received {:tool_response,
                       %{
                         "request_id" => "r1",
                         "result" => %{"content" => "x"},
                         "error" => nil,
                         "protocol_version" => 1
                       }}
    end

    test "caps a tool's time at 15 minutes", context do
      keeper =
        platform(context, [
          sse([
            {:tool_request, tool_request("r1", "bash", %{}, timeout_ms: 1_800_000)},
            {:complete, %{}}
          ])
        ])

      sandbox_answers({:ok, %{status: 0, output: "{}"}})

      run(keeper)

      assert [{["exec", "-i", _, "timeout", "-k", "10", "900" | _], _}] = tool_calls()
    end

    test "when the session fails, returns its error", context do
      keeper = platform(context, [sse([{:error, %{"error" => "boom"}}])])
      FakeExec.script([])

      assert run(keeper) == {:error, {:session, %{"error" => "boom"}}}
    end

    test "answers an unknown tool without running anything", context do
      keeper =
        platform(context, [
          sse([{:tool_request, tool_request("r1", "rm_rf", %{})}, {:complete, %{}}])
        ])

      FakeExec.script([])

      assert run(keeper) == {:ok, %{}}
      assert tool_calls() == []

      assert_received {:tool_response,
                       %{"request_id" => "r1", "result" => %{"error" => "unknown tool"}}}
    end

    test "when a request speaks another protocol version, ends the session unrun", context do
      keeper =
        platform(context, [
          sse([
            {:tool_request, tool_request("r1", "bash", %{}, protocol_version: 2)},
            {:complete, %{}}
          ])
        ])

      FakeExec.script([])

      assert run(keeper) == {:error, {:protocol_version, 2}}
      assert tool_calls() == []
      refute_received {:tool_response, _}
    end

    test "drops malformed sandbox output and says so", context do
      keeper =
        platform(context, [
          sse([{:tool_request, tool_request("r1", "bash", %{})}, {:complete, %{}}])
        ])

      sandbox_answers({:ok, %{status: 0, output: "secret-ish junk\n[1,2]"}})

      run(keeper)

      assert_received {:tool_response, %{"result" => result}}
      assert result == %{"error" => "sandbox returned malformed output"}
    end

    test "reports a sandbox timeout or oversized output as the tool's error", context do
      answers = %{
        "r1" => {:error, :timeout},
        "r2" => {:ok, %{status: 124, output: ""}},
        "r3" => {:error, :output_too_large}
      }

      requests =
        for id <- Map.keys(answers), do: {:tool_request, tool_request(id, "bash", %{"id" => id})}

      keeper = platform(context, [sse(requests ++ [{:complete, %{}}])])

      FakeExec.script([
        {fn {"docker", ["exec" | _], _} -> true end,
         fn {_, _, opts} ->
           Enum.find_value(answers, fn {id, answer} -> opts[:input] =~ id && answer end)
         end}
      ])

      run(keeper)

      assert_received {:tool_response,
                       %{"request_id" => "r1", "result" => %{"error" => "timeout"}}}

      assert_received {:tool_response,
                       %{"request_id" => "r2", "result" => %{"error" => "timeout"}}}

      assert_received {:tool_response,
                       %{"request_id" => "r3", "result" => %{"error" => "output too large"}}}
    end

    test "returns a cached result without streaming", context do
      keeper =
        platform(context, [], fn
          %{request_path: "/api/v1/validation/start"} = conn ->
            Req.Test.json(conn, %{cached: true, result: %{is_false_positive: true}})

          _other ->
            nil
        end)

      FakeExec.script([])

      assert run(keeper) == {:ok, %{"is_false_positive" => true}}
      refute_received :connected
    end
  end

  describe "run_session/5 when the stream drops" do
    test "reconnects, and never runs a replayed request twice", context do
      request = {:tool_request, tool_request("r1", "bash", %{"command" => "make test"})}
      keeper = platform(context, [sse([request]), sse([request, {:complete, %{"ok" => true}}])])
      sandbox_answers({:ok, %{status: 0, output: "{}"}})

      assert run(keeper) == {:ok, %{"ok" => true}}
      assert_received :connected
      assert_received :connected
      assert [_one_run] = tool_calls()
      assert_received {:tool_response, %{"request_id" => "r1"}}
      refute_received {:tool_response, _}
    end

    test "never runs a request twice within one connection either", context do
      request = {:tool_request, tool_request("r1", "bash", %{})}
      keeper = platform(context, [sse([request, request, {:complete, %{}}])])
      sandbox_answers({:ok, %{status: 0, output: "{}"}})

      assert run(keeper) == {:ok, %{}}
      assert [_one_run] = tool_calls()
    end

    test "gives up after five reconnects", context do
      keeper = platform(context, [sse([{:progress, %{}}])])
      FakeExec.script([])

      assert run(keeper) == {:error, :stream_exhausted}
      for _connection <- 1..6, do: assert_received(:connected)
      refute_received :connected
    end

    test "when the session failed meanwhile, reports that instead of reconnecting", context do
      keeper =
        platform(context, [sse([{:progress, %{}}])], fn
          %{request_path: "/api/v1/validation/status/s1"} = conn ->
            Req.Test.json(conn, %{status: "failed"})

          _other ->
            nil
        end)

      FakeExec.script([])

      assert {:error, {:session, _}} = run(keeper)
      assert_received :connected
      refute_received :connected
    end
  end

  describe "run_session/5 budgets" do
    test "refuses a request id that isn't 1 to 128 of [A-Za-z0-9_-], before remembering it",
         context do
      sandbox_answers({:ok, %{status: 0, output: "{}"}})

      for id <- [String.duplicate("a", 129), "a b", "a\n", "ä", ""] do
        keeper =
          platform(context, [
            sse([{:tool_request, tool_request(id, "read_file", %{})}, {:complete, %{}}])
          ])

        assert run(keeper) == {:error, :malformed_tool_request}, inspect(id)
        assert tool_calls() == []
        refute_received {:tool_response, _}
      end
    end

    test "a stream of heartbeats ends at the session's deadline", context do
      keeper = platform(context, [sse([{:heartbeat, nil}, {:heartbeat, nil}])])
      started = System.monotonic_time(:millisecond)

      result =
        run(keeper,
          backoff_ms: List.duplicate(20, 500),
          deadline: System.monotonic_time(:millisecond) + 300
        )

      assert result == {:error, :session_timeout}
      assert System.monotonic_time(:millisecond) - started < 2_000
    end

    test "a stream that keeps dropping stops reconnecting at the deadline", context do
      keeper = platform(context, [""])
      started = System.monotonic_time(:millisecond)

      result =
        run(keeper,
          backoff_ms: List.duplicate(20, 500),
          deadline: System.monotonic_time(:millisecond) + 300
        )

      assert result == {:error, :session_timeout}
      assert System.monotonic_time(:millisecond) - started < 2_000
    end

    test "requests already received aren't run past the deadline", context do
      keeper =
        platform(context, [
          sse([
            {:tool_request, tool_request("r1", "bash", %{})},
            {:tool_request, tool_request("r2", "bash", %{})},
            {:complete, %{}}
          ])
        ])

      deadline = System.monotonic_time(:millisecond) + 200

      FakeExec.script([
        {fn {"docker", ["exec" | _], _} -> true end,
         fn _call ->
           Process.sleep(300)
           {:ok, %{status: 0, output: "{}"}}
         end}
      ])

      assert run(keeper, deadline: deadline) == {:error, :session_timeout}
      assert [_only_r1] = tool_calls()
    end

    test "a tool's time is capped by what's left of the session", context do
      keeper =
        platform(context, [
          sse([
            {:tool_request, tool_request("r1", "bash", %{}, timeout_ms: 600_000)},
            {:complete, %{}}
          ])
        ])

      sandbox_answers({:ok, %{status: 0, output: "{}"}})

      run(keeper, deadline: System.monotonic_time(:millisecond) + 60_000)

      assert [{["exec", "-i", _, "timeout", "-k", "10", seconds | _], _}] = tool_calls()
      assert String.to_integer(seconds) <= 60
    end
  end

  describe "run_session/5 budgets, against a server that answers over time" do
    alias RsolvHost.{DripServer, StaticKeeper}

    @routes %{
      {"POST", "/api/v1/validation/start"} =>
        {:json, 200, %{session_id: "s1", stream_url: "/api/v1/validation/stream/s1"}},
      {"GET", "/api/v1/validation/status/s1"} => {:json, 200, %{status: "streaming"}},
      {"POST", "/api/v1/validation/tool_response/s1"} => {:json, 200, %{success: true}}
    }

    # The platform's routes on a real server; `overrides` replaces any of them.
    defp drip_platform(overrides) do
      routes = Map.merge(@routes, overrides)
      port = DripServer.start(fn method, path -> Map.fetch!(routes, {method, path}) end)
      {:ok, keeper} = StaticKeeper.start_link(DripServer.req(port))
      keeper
    end

    defp timed_run(keeper, budget_ms) do
      started = System.monotonic_time(:millisecond)

      result =
        run(keeper,
          backoff_ms: List.duplicate(20, 500),
          deadline: System.monotonic_time(:millisecond) + budget_ms
        )

      {result, System.monotonic_time(:millisecond) - started}
    end

    @stream {"GET", "/api/v1/validation/stream/s1"}

    for {name, chunk} <- [
          {"keepalive comments", ": keepalive\n\n"},
          {"events of an unknown type", "event: unrecognized\ndata: {}\n\n"},
          {"a frame that never ends", "a"}
        ] do
      test "a stream of #{name}, every 100 ms, ends at the deadline" do
        keeper = drip_platform(%{@stream => {:drip, unquote(chunk), 100, 40}})

        assert {{:error, :session_timeout}, elapsed} = timed_run(keeper, 300)
        assert elapsed < 1_000
      end
    end

    test "a session ends at its deadline even while a tool runs over it" do
      keeper =
        drip_platform(%{
          @stream => {:drip, sse([{:tool_request, tool_request("r1", "bash", %{})}]), 100, 1}
        })

      FakeExec.script([
        {fn {"docker", ["exec" | _], _} -> true end,
         fn _call ->
           Process.sleep(3_000)
           {:ok, %{status: 0, output: "{}"}}
         end}
      ])

      assert {{:error, :session_timeout}, elapsed} = timed_run(keeper, 300)
      assert elapsed < 1_000
    end

    test "a start, status or tool response that doesn't answer ends at the deadline" do
      tool_stream = {:drip, sse([{:tool_request, tool_request("r1", "bash", %{})}]), 100, 1}
      sandbox_answers({:ok, %{status: 0, output: "{}"}})

      for overrides <- [
            %{{"POST", "/api/v1/validation/start"} => {:hang, 3_000}},
            %{
              @stream => {:drip, "", 100, 0},
              {"GET", "/api/v1/validation/status/s1"} => {:hang, 3_000}
            },
            %{
              @stream => tool_stream,
              {"POST", "/api/v1/validation/tool_response/s1"} => {:hang, 3_000}
            }
          ] do
        keeper = drip_platform(overrides)

        # A start isn't repeatable, so its timeout says so; either way, exit 3.
        assert {{:error, reason} = result, elapsed} = timed_run(keeper, 300)
        assert reason in [:session_timeout, {:transport, :timeout}]
        assert RsolvHost.Outcome.exit_code(result) == 3
        assert elapsed < 1_000, inspect(Map.keys(overrides))
      end
    end

    test "a retry's wait is cut to what's left of the session" do
      keeper =
        drip_platform(%{
          @stream => {:drip, sse([{:tool_request, tool_request("r1", "bash", %{})}]), 100, 1},
          {"POST", "/api/v1/validation/tool_response/s1"} =>
            {:json, 503, %{}, [{"retry-after", "60"}]}
        })

      sandbox_answers({:ok, %{status: 0, output: "{}"}})

      assert {{:error, :session_timeout}, elapsed} = timed_run(keeper, 300)
      assert elapsed < 1_000
    end
  end
end
