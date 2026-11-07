defmodule RsolvHost.Roles.ScanTest do
  use ExUnit.Case, async: true

  import RsolvHost.PlatformStub, only: [body: 1]

  alias RsolvHost.{FakeExec, Frame, GitHub, Oidc, Platform}
  alias RsolvHost.Roles.Scan

  @moduletag :tmp_dir
  @run "0b0e5f7c-7d3c-4d8e-9a55-3f6f1b0c2a11"

  setup %{tmp_dir: dir} do
    workspace = Path.join(dir, "checkout")
    File.mkdir_p!(workspace)
    {:ok, io} = StringIO.open("")
    Req.Test.stub(Oidc, &Req.Test.json(&1, %{value: "jwt"}))

    env = %{
      "RUNNER_TEMP" => dir,
      "GITHUB_WORKSPACE" => workspace,
      "GITHUB_RUN_ID" => "41",
      "GITHUB_REPOSITORY" => "acme/app",
      "GITHUB_TOKEN" => "ghs_test",
      "GITHUB_OUTPUT" => Path.join(dir, "output"),
      "ACTIONS_ID_TOKEN_REQUEST_URL" => "https://token.actions.example/id?v=1",
      "ACTIONS_ID_TOKEN_REQUEST_TOKEN" => "t"
    }

    %{env: env, io: io}
  end

  defp platform do
    test = self()

    Req.Test.stub(Platform, fn conn ->
      case conn.request_path do
        "/api/v1/runs/token" ->
          {body, conn} = body(conn)
          send(test, {:exchanged, body})

          Req.Test.json(conn, %{
            token: "rsolv_rt_scan",
            expires_at: "2099-01-01T00:00:00Z",
            protocol_version: 1
          })

        "/api/v1/runs/register" ->
          {body, conn} = body(conn)
          send(test, {:registered, body})

          Req.Test.json(conn, %{
            pipeline_run_id: @run,
            base_sha: String.duplicate("b", 40),
            target_branch: "main"
          })
      end
    end)
  end

  defp github(status \\ 201) do
    Req.Test.stub(GitHub, fn conn ->
      conn
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(%{number: 7, html_url: "https://github.com/acme/app/issues/7"})
    end)
  end

  # The scanner: reads the config frame, files issues for `titles`, then reports done.
  defp scanner(titles) do
    test = self()

    sim =
      spawn_link(fn ->
        receive do: ({:command, config} -> send(test, {:config, config}))

        numbers =
          for title <- titles do
            issue = %{"title" => title, "body" => "b", "labels" => ["rsolv:detected"]}

            send(
              test,
              {self(), {:data, Frame.encode(%{"call" => "create_issue", "args" => issue})}}
            )

            receive do: ({:command, reply} ->
                           reply |> Frame.decode(1_000_000) |> elem(1) |> get_in(["ok", "number"]))
          end

        issues = for n <- numbers, do: %{"number" => n, "cwe_id" => "CWE-89"}

        done = %{
          "issues" => issues,
          "manifest_files" => %{"Gemfile" => "x"},
          "files_scanned" => 12
        }

        send(test, {self(), {:data, Frame.encode(%{"call" => "done", "args" => done})}})
      end)

    FakeExec.script([
      {fn {"docker", ["exec" | args], _} -> List.last(args) == "scan" end, {:ok, sim}}
    ])
  end

  defp deps(context), do: [io: context.io, probe: fn _ip -> :ok end]

  defp outputs(context), do: File.read!(context.env["GITHUB_OUTPUT"])

  describe "run/3" do
    test "files the scanner's issues and registers them", context do
      platform()
      github()
      scanner(["SQL injection in a.rb:3"])

      assert Scan.run(%{max_issues: 2}, context.env, deps(context)) == :ok

      assert_received {:exchanged, %{"issue" => nil}}
      assert [{"cp", ["-a", "--", _, copy], _} | _] = FakeExec.calls()
      assert copy == Path.join([context.tmp_dir, "rsolv", "scan"])

      assert {"docker", ["run", "-d", "--name", "rsolv-41-scan", "--network", "none" | _], _} =
               Enum.find(FakeExec.calls(), &match?({"docker", ["run" | _], _}, &1))

      assert {"docker",
              [
                "exec",
                "-i",
                "rsolv-41-scan",
                "timeout",
                "-k",
                "10",
                "1800",
                "rsolv-sandbox",
                "scan"
              ], _} =
               Enum.find(FakeExec.calls(), &match?({"docker", ["exec" | _], _}, &1))

      assert_received {:config, config}

      assert Frame.decode(config, 1_000) ==
               {:ok,
                %{
                  "repository" => "acme/app",
                  "max_issues" => 2,
                  "issue_label" => "rsolv:detected"
                }, ""}

      assert_received {:registered,
                       %{
                         "issues" => [%{"number" => 7, "cwe_id" => "CWE-89"}],
                         "manifest_files" => %{"Gemfile" => "x"},
                         "files_scanned" => 12
                       }}

      assert outputs(context) == "pipeline_run_id=#{@run}\nissues=[7]\n"
      assert {"docker", ["rm", "-f", "rsolv-41-scan"], _} = List.last(FakeExec.calls())
    end

    test "with no findings, registers nothing and outputs no issues", context do
      platform()
      github()
      scanner([])

      assert Scan.run(%{}, context.env, deps(context)) == :ok
      refute_received {:registered, _}
      assert outputs(context) == "issues=[]\n"
    end

    test "defaults to 3 issues, and refuses more than 50", context do
      platform()
      github()
      scanner([])

      assert Scan.run(%{}, context.env, deps(context)) == :ok
      assert_received {:config, config}
      assert {:ok, %{"max_issues" => 3}, ""} = Frame.decode(config, 1_000)

      assert Scan.run(%{max_issues: 51}, context.env, deps(context)) == {:error, :usage}
      assert Scan.run(%{max_issues: 0}, context.env, deps(context)) == {:error, :usage}
    end

    test "when GitHub refuses to create an issue, fails as configuration", context do
      platform()
      github(403)
      scanner(["SQL injection in a.rb:3"])

      result = Scan.run(%{}, context.env, deps(context))

      assert result == {:error, {:github, 403, :forbidden}}
      assert RsolvHost.Outcome.exit_code(result) == 2
      refute_received {:registered, _}
    end
  end
end
