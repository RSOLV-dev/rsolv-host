defmodule RsolvHost.ScanRelayTest do
  use ExUnit.Case, async: true

  import RsolvHost.PlatformStub, only: [body: 1]

  alias RsolvHost.{FakeExec, Frame, GitHub, Oidc, Platform, ScanRelay, TokenKeeper}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    {:ok, io} = StringIO.open("")
    Req.Test.stub(Oidc, &Req.Test.json(&1, %{value: "jwt"}))

    env = %{
      "RUNNER_TEMP" => dir,
      "GITHUB_TOKEN" => "ghs_test",
      "GITHUB_REPOSITORY" => "acme/app",
      "ACTIONS_ID_TOKEN_REQUEST_URL" => "https://token.actions.example/id?v=1",
      "ACTIONS_ID_TOKEN_REQUEST_TOKEN" => "t"
    }

    %{env: env, io: io}
  end

  defp platform(fun \\ fn _conn -> nil end) do
    test = self()

    Req.Test.stub(Platform, fn conn ->
      case conn.request_path do
        "/api/v1/runs/token" ->
          Req.Test.json(conn, %{
            token: "rsolv_rt_scan",
            expires_at: "2099-01-01T00:00:00Z",
            protocol_version: 1
          })

        path ->
          fun.(conn) ||
            (
              send(test, {:platform, conn.method, path, conn.query_string})
              Req.Test.json(conn, %{route: path})
            )
      end
    end)
  end

  defp github(fun) do
    test = self()

    Req.Test.stub(GitHub, fn conn ->
      send(test, {:github, conn.method, conn.request_path})
      fun.(conn)
    end)
  end

  # Serves `frames` (the sandbox's side) and returns the relay's result and replies.
  defp serve(context, frames, opts \\ []) do
    platform(Keyword.get(opts, :platform, fn _conn -> nil end))
    {:ok, keeper} = TokenKeeper.start_link(role: :scan, env: context.env, io: context.io)
    {:ok, gh} = GitHub.new(context.env)
    for frame <- frames, do: send(self(), {self(), {:data, Frame.encode(frame)}})

    state =
      ScanRelay.new(
        channel: self(),
        exec: FakeExec,
        keeper: keeper,
        github: gh,
        repository: "acme/app",
        max_issues: Keyword.get(opts, :max_issues, 3)
      )

    result = ScanRelay.serve(state)
    {result, replies()}
  end

  defp replies do
    receive do
      {:command, data} -> [data |> Frame.decode(16 * 1024 * 1024) |> elem(1) | replies()]
    after
      0 -> []
    end
  end

  defp done(issues \\ []),
    do: %{
      "call" => "done",
      "args" => %{"issues" => issues, "manifest_files" => %{}, "files_scanned" => 2}
    }

  defp issue(title \\ "SQL injection in a.rb:3", labels \\ ["rsolv:detected", "security"]),
    do: %{
      "call" => "create_issue",
      "args" => %{"title" => title, "body" => "b", "labels" => labels}
    }

  defp created(conn) do
    {body, conn} = body(conn)
    send(self(), {:created, body})
    n = 100 + :erlang.phash2(body["title"], 100)

    conn
    |> Plug.Conn.put_status(201)
    |> Req.Test.json(%{number: n, html_url: "https://github.com/acme/app/issues/#{n}"})
  end

  describe "serve/1 and the platform calls" do
    test "patterns are fetched for a scanner language", context do
      {result, replies} =
        serve(context, [%{"call" => "patterns", "args" => %{"language" => "ruby"}}, done()])

      assert {:ok, %{"files_scanned" => 2}} = result
      assert [%{"ok" => %{"route" => "/api/v1/patterns"}}] = replies
      assert_received {:platform, "GET", "/api/v1/patterns", "language=ruby&format=enhanced"}
    end

    test "patterns for any other language are refused", context do
      {_result, replies} =
        serve(context, [%{"call" => "patterns", "args" => %{"language" => "cobol"}}, done()])

      assert replies == [%{"error" => "invalid arguments"}]
      refute_received {:platform, _, _, _}
    end

    test "severity tiers are fetched", context do
      {_result, replies} = serve(context, [%{"call" => "severity_tiers"}, done()])

      assert [%{"ok" => %{"route" => "/api/v1/vulnerability-types/severity-tiers"}}] = replies
    end

    test "validate is passed through, up to 20 calls", context do
      frames =
        List.duplicate(
          %{"call" => "validate", "args" => %{"body" => %{"vulnerabilities" => []}}},
          21
        )

      {_result, replies} = serve(context, frames ++ [done()])

      assert [%{"ok" => _} | _] = replies
      assert length(replies) == 21
      assert List.last(replies) == %{"error" => "call limit"}
    end

    test "plan always names the token's repository", context do
      test = self()

      plan = fn
        %{request_path: "/api/v1/scan/plan"} = conn ->
          {body, conn} = body(conn)
          send(test, {:plan, body})
          Req.Test.json(conn, %{selected: []})

        _other ->
          nil
      end

      serve(
        context,
        [
          %{
            "call" => "plan",
            "args" => %{"body" => %{"namespace" => "other/repo", "findings" => []}}
          },
          done()
        ],
        platform: plan
      )

      assert_received {:plan, %{"namespace" => "acme/app", "findings" => []}}
    end
  end

  describe "serve/1 and the GitHub calls" do
    test "list_issues pages through open issues, skipping pull requests", context do
      github(fn conn ->
        page = URI.decode_query(conn.query_string)["page"]

        items =
          if page == "1",
            do:
              for(
                n <- 1..100,
                do: %{
                  number: n,
                  title: "t#{n}",
                  labels: [%{name: "security"}],
                  state: "open",
                  html_url: "u",
                  body: "x"
                }
              ),
            else: [
              %{
                number: 101,
                title: "pr",
                labels: [],
                state: "open",
                html_url: "u",
                pull_request: %{}
              }
            ]

        Req.Test.json(conn, items)
      end)

      {result, [%{"ok" => issues}]} =
        serve(context, [
          %{"call" => "list_issues", "args" => %{"labels" => ["rsolv:detected"]}},
          done([%{"number" => 7}])
        ])

      assert length(issues) == 100

      assert hd(issues) == %{
               "number" => 1,
               "title" => "t1",
               "labels" => ["security"],
               "state" => "open",
               "html_url" => "u"
             }

      assert {:ok, %{"issues" => [%{"number" => 7}]}} = result
    end

    test "list_issues refuses a label outside the allowlist", context do
      github(fn _conn -> flunk("no GitHub call expected") end)

      {_result, replies} =
        serve(context, [%{"call" => "list_issues", "args" => %{"labels" => ["bug"]}}, done()])

      assert replies == [%{"error" => "label not allowed"}]
    end

    test "ensure_labels creates each allowlisted label", context do
      github(fn conn -> conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{}) end)

      label = %{
        "name" => "rsolv:detected",
        "color" => "d73a4a",
        "description" => "Found by RSOLV"
      }

      other = %{label | "name" => "security"}

      {_result, replies} =
        serve(context, [
          %{"call" => "ensure_labels", "args" => %{"labels" => [label, other, label]}},
          done()
        ])

      assert replies == [%{"ok" => true}]
      assert_received {:github, "POST", "/repos/acme/app/labels"}
      assert_received {:github, "POST", "/repos/acme/app/labels"}
    end

    test "ensure_labels refuses a bad color, a long description or a foreign label", context do
      github(fn _conn -> flunk("no GitHub call expected") end)

      frames =
        for label <- [
              %{"name" => "security", "color" => "red", "description" => ""},
              %{
                "name" => "security",
                "color" => "d73a4a",
                "description" => String.duplicate("a", 101)
              },
              %{"name" => "demo", "color" => "d73a4a", "description" => ""}
            ],
            do: %{"call" => "ensure_labels", "args" => %{"labels" => [label]}}

      {_result, replies} = serve(context, frames ++ [done()])

      assert replies == [
               %{"error" => "invalid arguments"},
               %{"error" => "invalid arguments"},
               %{"error" => "label not allowed"}
             ]
    end

    test "create_issue posts the issue and remembers its number", context do
      github(&created/1)
      n = 100 + :erlang.phash2("SQL injection in a.rb:3", 100)

      {result, replies} = serve(context, [issue(), done([%{"number" => n}])])

      assert [%{"ok" => %{"number" => ^n}}] = replies
      assert {:ok, %{"issues" => [%{"number" => ^n}]}} = result

      assert_received {:created,
                       %{
                         "title" => "SQL injection in a.rb:3",
                         "body" => "b",
                         "labels" => ["rsolv:detected", "security"]
                       }}
    end

    test "create_issue refuses an oversized title or body, or a foreign label", context do
      github(fn _conn -> flunk("no GitHub call expected") end)

      frames = [
        issue(String.duplicate("t", 257)),
        %{
          "call" => "create_issue",
          "args" => %{
            "title" => "t",
            "body" => String.duplicate("b", 65_537),
            "labels" => ["security"]
          }
        },
        issue("t", ["bug"]),
        issue("t", []),
        issue("evil\u202Etitle")
      ]

      {_result, replies} = serve(context, frames ++ [done()])

      assert replies == [
               %{"error" => "invalid arguments"},
               %{"error" => "invalid arguments"},
               %{"error" => "label not allowed"},
               %{"error" => "invalid arguments"},
               %{"error" => "invalid arguments"}
             ]
    end

    test "create_issue stops at max_issues", context do
      github(&created/1)

      {_result, replies} = serve(context, [issue("a"), issue("b"), done()], max_issues: 1)

      assert [%{"ok" => _}, %{"error" => "issue limit"}] = replies
    end

    test "a GitHub refusal ends the relay with its class", context do
      github(fn conn -> conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{}) end)

      {result, _replies} = serve(context, [issue(), done()])

      assert result == {:error, {:github, 403, :forbidden}}
    end
  end

  describe "serve/1 and the frames" do
    test "an unknown call is answered and the relay goes on", context do
      {result, replies} = serve(context, [%{"call" => "rm_rf"}, done()])

      assert replies == [%{"error" => "unknown call"}]
      assert {:ok, _} = result
    end

    test "a malformed frame ends the relay", context do
      platform()
      {:ok, keeper} = TokenKeeper.start_link(role: :scan, env: context.env, io: context.io)
      {:ok, gh} = GitHub.new(context.env)
      send(self(), {self(), {:data, "x\n{}"}})

      state =
        ScanRelay.new(
          channel: self(),
          exec: FakeExec,
          keeper: keeper,
          github: gh,
          repository: "acme/app",
          max_issues: 3
        )

      assert ScanRelay.serve(state) == {:error, :bad_frame}
    end

    test "done naming an issue the relay never saw is refused", context do
      {result, _replies} = serve(context, [done([%{"number" => 7}])])

      assert result == {:error, :unknown_issue}
    end

    test "the scanner exiting before done is a sandbox failure", context do
      platform()
      {:ok, keeper} = TokenKeeper.start_link(role: :scan, env: context.env, io: context.io)
      {:ok, gh} = GitHub.new(context.env)
      send(self(), {self(), {:exit_status, 1}})

      state =
        ScanRelay.new(
          channel: self(),
          exec: FakeExec,
          keeper: keeper,
          github: gh,
          repository: "acme/app",
          max_issues: 3
        )

      assert ScanRelay.serve(state) == {:error, {:sandbox, :scanner_exited}}
    end

    test "more than 2,000 frames end the relay", context do
      {result, _replies} = serve(context, List.duplicate(%{"call" => "severity_tiers"}, 2_001))

      assert result == {:error, :frame_limit}
    end
  end

  describe "allowed_label?/1" do
    test "accepts what IssueCreator produces" do
      for label <-
            ~w(security automated-scan critical high medium low rsolv:detected rsolv:vuln-sql_injection rsolv:cwe-89 rsolv:cwe-CWE-89) do
        assert ScanRelay.allowed_label?(label), label
      end
    end

    test "refuses everything else, demo-mode labels included" do
      for label <- [
            "rsolv:automate",
            "demo",
            "bug",
            "rsolv:cwe-123456",
            "rsolv:vuln-" <> String.duplicate("a", 41),
            "Security",
            7
          ] do
        refute ScanRelay.allowed_label?(label), inspect(label)
      end
    end
  end
end
