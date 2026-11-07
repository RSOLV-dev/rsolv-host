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
      [backoff_ms: [0, 0, 0, 0, 0], io: :stdio] ++ opts
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
end
