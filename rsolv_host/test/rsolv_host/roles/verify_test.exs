defmodule RsolvHost.Roles.VerifyTest do
  use ExUnit.Case, async: true

  import RsolvHost.PlatformStub

  alias RsolvCore.ChangeSet
  alias RsolvHost.{Exec, FakeExec, Oidc, Outcome, Platform}
  alias RsolvHost.Roles.Verify

  @moduletag :tmp_dir
  @run "0b0e5f7c-7d3c-4d8e-9a55-3f6f1b0c2a11"
  @source "eval(x)\n"
  @fixed "String(x)\n"
  @test "test('x', () => {});\n"
  @policy "2026-11-v1"

  defp change_set do
    [
      %{
        "path" => "src/a.js",
        "op" => "modify",
        "base_mode" => "100644",
        "base_blob_sha" => ChangeSet.blob_sha(@source),
        "mode" => "100644",
        "new_blob_sha" => ChangeSet.blob_sha(@fixed)
      },
      %{
        "path" => "test/a.test.js",
        "op" => "add",
        "base_mode" => nil,
        "base_blob_sha" => nil,
        "mode" => "100644",
        "new_blob_sha" => ChangeSet.blob_sha(@test)
      }
    ]
  end

  defp digest(json), do: json |> ChangeSet.from_json() |> elem(1) |> ChangeSet.digest()

  defp plan do
    %{
      "v" => 1,
      "framework" => "jest",
      "install" => [["npx", "--yes", "npm@10", "ci"]],
      "prepare" => [],
      "test" => ["npx", "--no-install", "jest", "--ci", "--json", "--outputFile=/tmp/r.json"],
      "report" => %{"format" => "jest_json", "argv" => ["cat", "--", "/tmp/r.json"]},
      "install_timeout_s" => 60,
      "test_timeout_s" => 60,
      "change_set" => change_set(),
      "change_set_digest" => digest(change_set()),
      "red_paths" => ["test/a.test.js"],
      "red_digest" => digest([Enum.at(change_set(), 1)]),
      "policy_version" => @policy
    }
  end

  defp verdict(status \\ "accepted") do
    %{
      status: status,
      reasons: [],
      flags: [],
      change_set_digest: plan()["change_set_digest"],
      red_digest: plan()["red_digest"],
      policy_version: @policy
    }
  end

  defp images,
    do: %{"src/a.js" => Base.encode64(@fixed), "test/a.test.js" => Base.encode64(@test)}

  defp git(dir, args) do
    env = [
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_AUTHOR_NAME", "t"},
      {"GIT_AUTHOR_EMAIL", "t@example.com"},
      {"GIT_COMMITTER_NAME", "t"},
      {"GIT_COMMITTER_EMAIL", "t@example.com"}
    ]

    {out, 0} = System.cmd("git", args, cd: dir, env: env, stderr_to_stdout: true)
    String.trim(out)
  end

  setup %{tmp_dir: dir} do
    workspace = Path.join(dir, "checkout")
    File.mkdir_p!(Path.join(workspace, "src"))
    File.write!(Path.join(workspace, "src/a.js"), @source)
    git(workspace, ["init", "-q"])
    git(workspace, ["add", "-A"])
    git(workspace, ["commit", "-q", "-m", "base"])
    base = git(workspace, ["rev-parse", "HEAD"])

    {:ok, io} = StringIO.open("")
    Req.Test.stub(Oidc, &Req.Test.json(&1, %{value: "e30.e30.sig"}))

    env = %{
      "RUNNER_TEMP" => dir,
      "GITHUB_WORKSPACE" => workspace,
      "GITHUB_RUN_ID" => "41",
      "ACTIONS_ID_TOKEN_REQUEST_URL" => "https://token.actions.example/id?v=1",
      "ACTIONS_ID_TOKEN_REQUEST_TOKEN" => "t"
    }

    %{env: env, io: io, workspace: workspace, base: base}
  end

  # The platform's verify endpoints; `answers` replaces any of them with
  # `{status, json}`. Every request is sent to the test as {:request, name, body}.
  defp platform(context, answers \\ %{}) do
    test = self()

    defaults = %{
      "touched-paths" => {200, %{paths: ["src/a.js", "test/a.test.js"], work_attempt: 1}},
      "base-facts" => {200, verdict()},
      "verify-plan" => {200, plan()},
      "post-images" => {200, %{files: images()}},
      "verification" => {200, %{verification: "green", reasons: []}}
    }

    answers = Map.merge(defaults, answers)

    Req.Test.stub(Platform, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/api/v1/runs/token"} ->
          Req.Test.json(conn, Map.put(token(), :base_sha, context.base))

        {method, "/api/v1/runs/" <> @run <> "/issues/7/" <> name} ->
          answer(conn, method, name, answers[name], test)
      end
    end)
  end

  defp answer(conn, method, name, {status, json}, test) do
    {body, conn} = if method == "POST", do: body(conn), else: {nil, conn}
    send(test, {:request, name, body})
    conn |> Plug.Conn.put_status(status) |> Req.Test.json(json)
  end

  defp report(status) do
    JSON.encode!(%{
      "testResults" => [
        %{
          "name" => "/work/test/a.test.js",
          "status" => status,
          "assertionResults" => [%{"fullName" => "x", "status" => status}]
        }
      ]
    })
  end

  defp side?({"docker", ["exec", "-i", container | _], _}, side),
    do: String.ends_with?(container, "-" <> side)

  defp side?(_call, _side), do: false

  defp runs?({"docker", ["exec", "-i", _container, "timeout", "-k", _kill, _s | argv], _}, exe),
    do: hd(argv) == exe

  defp runs?(_call, _exe), do: false

  # git and cp run for real; docker answers as a sandbox whose RED test fails
  # and whose GREEN test passes. `overrides` come first.
  defp sandbox(overrides \\ []) do
    real = fn {exe, args, opts} -> Exec.run(exe, args, opts) end

    FakeExec.script(
      overrides ++
        [
          {fn {exe, _, _} -> exe in ["env", "cp"] end, real},
          {fn {"docker", ["inspect", "-f", t, _], _} -> t =~ "bridge" end,
           {:ok, %{status: 0, output: "172.17.0.5"}}},
          {fn {"docker", ["inspect" | _], _} -> true end,
           {:ok, %{status: 0, output: "172.18.0.2"}}},
          {fn {"docker", ["exec" | args], _} -> List.last(args) == "bootstrap" end,
           {:ok, %{status: 0, output: ~s({"ok":true,"ecosystems":["node"],"log_tail":""})}}},
          {&(runs?(&1, "npx") and "jest" in elem(&1, 1) and side?(&1, "red")),
           {:ok, %{status: 1, output: "FAIL"}}},
          {&(runs?(&1, "npx") and "jest" in elem(&1, 1) and side?(&1, "green")),
           {:ok, %{status: 0, output: "PASS"}}},
          {&(runs?(&1, "cat") and side?(&1, "red")),
           {:ok, %{status: 0, output: report("failed")}}},
          {&(runs?(&1, "cat") and side?(&1, "green")),
           {:ok, %{status: 0, output: report("passed")}}}
        ]
    )
  end

  defp deps(context), do: [io: context.io, probe: fn _ip -> :ok end, stat: &File.stat!/1]

  defp run(context), do: Verify.run(%{issue: 7}, context.env, deps(context))

  defp docker_calls, do: for({"docker", _args, _opts} = call <- FakeExec.calls(), do: call)

  defp requests(acc \\ []) do
    receive do
      {:request, name, _body} -> requests([name | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "run/3" do
    test "proves RED then GREEN, and reports both bound to the plan", context do
      platform(context)
      sandbox()

      assert run(context) == {:outcome, :verified, false}

      assert_received {:request, "verification", %{"red" => red, "green" => green} = body}

      assert red == %{
               "exit_code" => 1,
               "timed_out" => false,
               "report" => Base.encode64(report("failed"))
             }

      assert green == %{
               "exit_code" => 0,
               "timed_out" => false,
               "report" => Base.encode64(report("passed"))
             }

      assert Map.take(body, ~w(change_set_digest red_digest policy_version)) ==
               Map.take(plan(), ~w(change_set_digest red_digest policy_version))
    end

    test "calls the platform in RFC-150 §5's order", context do
      platform(context)
      sandbox()

      run(context)

      assert requests() ==
               ~w(touched-paths base-facts verify-plan post-images verification)
    end

    test "submits base facts read from git for exactly the touched paths", context do
      platform(context)
      sandbox()

      run(context)

      assert_received {:request, "base-facts", facts}
      assert facts["base_sha"] == context.base

      assert facts["paths"] == %{
               "src" => %{"type" => "tree"},
               "src/a.js" => %{
                 "type" => "blob",
                 "mode" => "100644",
                 "sha" => ChangeSet.blob_sha(@source),
                 "content" => Base.encode64(@source)
               },
               "test" => %{"type" => "missing"},
               "test/a.test.js" => %{"type" => "missing"}
             }
    end

    test "gives RED the base and the RED snapshot, GREEN the whole change set, and leaves the checkout alone",
         context do
      platform(context)
      sandbox()

      run(context)

      red = Path.join([context.tmp_dir, "rsolv", "verify-red"])
      green = Path.join([context.tmp_dir, "rsolv", "verify-green"])
      assert File.read!(Path.join(red, "src/a.js")) == @source
      assert File.read!(Path.join(red, "test/a.test.js")) == @test
      assert File.read!(Path.join(green, "src/a.js")) == @fixed
      assert File.read!(Path.join(green, "test/a.test.js")) == @test
      assert File.read!(Path.join(context.workspace, "src/a.js")) == @source
      refute File.exists?(Path.join(context.workspace, "test"))
    end

    test "runs no git and copies nothing once the first sandbox has started (acceptance 5a)",
         context do
      platform(context)
      sandbox()

      run(context)

      after_first_sandbox =
        Enum.drop_while(FakeExec.calls(), &(not match?({"docker", ["run" | _], _}, &1)))

      assert after_first_sandbox != []
      assert for({exe, _, _} <- after_first_sandbox, exe != "docker", do: exe) == []
    end

    test "installs online, then disconnects, then tests offline, on each side", context do
      platform(context)
      sandbox()

      run(context)

      for side <- ["red", "green"] do
        container = "rsolv-41-7-verify-" <> side

        steps =
          for {"docker", args, _} = call <- docker_calls(),
              step = step(call, container),
              step != nil,
              do: {step, args}

        assert Enum.map(steps, &elem(&1, 0)) ==
                 [:run, :bootstrap, :install, :disconnect, :test, :report, :remove]
      end
    end

    test "removes both sandboxes, their proxies and networks", context do
      platform(context)
      sandbox()

      run(context)

      removed = for {"docker", ["rm", "-f" | names], _} <- docker_calls(), do: names
      networks = for {"docker", ["network", "rm", net], _} <- docker_calls(), do: net

      assert removed == [
               ["rsolv-41-7-verify-red", "rsolv-41-7-verify-red-proxy"],
               ["rsolv-41-7-verify-green", "rsolv-41-7-verify-green-proxy"]
             ]

      assert networks == ["rsolv-41-7-verify-red-net", "rsolv-41-7-verify-green-net"]
    end

    test "prints sandbox output only as untrusted text", context do
      platform(context)
      sandbox()

      run(context)

      {:ok, {_in, out}} = StringIO.close(context.io)
      assert out =~ ~r/::stop-commands::([0-9a-f]{32})\nFAIL\n::\1::\n/
    end
  end

  defp step({"docker", ["run", "-d", "--name", container | _], _}, container), do: :run

  defp step({"docker", ["exec", "-i", container | args], _}, container) do
    case args do
      [_timeout, _k, _kill, _s, "rsolv-sandbox", "bootstrap"] -> :bootstrap
      [_timeout, _k, _kill, _s, "npx", "--yes" | _] -> :install
      [_timeout, _k, _kill, _s, "npx", "--no-install" | _] -> :test
      [_timeout, _k, _kill, _s, "cat" | _] -> :report
    end
  end

  defp step({"docker", ["network", "disconnect", _net, container], _}, container), do: :disconnect
  defp step({"docker", ["rm", "-f", container | _], _}, container), do: :remove
  defp step(_call, _container), do: nil

  describe "run/3 before any sandbox" do
    test "runs a plan only once RsolvCore.VerifyPlan accepts it", context do
      platform(context, %{"verify-plan" => {200, Map.put(plan(), "test", ["sh", "-c", "id"])}})
      sandbox()

      assert run(context) == {:error, :invalid_plan}
      assert docker_calls() == []
      refute_received {:request, "verification", _}
    end

    test "refuses a plan for another change set than the one policy accepted", context do
      other = %{verdict() | change_set_digest: "sha256:" <> String.duplicate("0", 64)}
      platform(context, %{"base-facts" => {200, other}})
      sandbox()

      assert run(context) == {:error, :invalid_plan}
      assert docker_calls() == []
    end

    test "refuses post-images that don't match the plan", context do
      platform(context, %{"post-images" => {200, %{files: %{"src/a.js" => Base.encode64("x")}}}})
      sandbox()

      assert run(context) == {:error, :invalid_plan}
      assert docker_calls() == []
    end

    test "refuses to make its copies inside the checkout", context do
      platform(context)
      sandbox()
      env = Map.put(context.env, "RUNNER_TEMP", Path.join(context.workspace, "tmp"))

      assert Verify.run(%{issue: 7}, env, deps(context)) ==
               {:error, {:missing_env, "RUNNER_TEMP"}}

      assert FakeExec.calls() == []
      refute_received {:request, _name, _body}
    end

    test "refuses a touched path before any git", context do
      platform(context, %{"touched-paths" => {200, %{paths: ["../x"], work_attempt: 1}}})
      sandbox()

      assert run(context) == {:error, :invalid_touched_paths}
      assert FakeExec.calls() == []
    end

    test "a policy rejection is the rejected outcome, and nothing runs", context do
      platform(context, %{"base-facts" => {200, verdict("rejected")}})
      sandbox()

      assert run(context) == {:outcome, :rejected, false}
      assert docker_calls() == []
      assert requests() == ~w(touched-paths base-facts)
    end

    for {name, code} <- [{"touched-paths", "issue_rejected"}, {"verify-plan", "not_eligible"}] do
      test "#{name} answering 409 #{code} is the rejected outcome", context do
        platform(context, %{unquote(name) => {409, %{error: unquote(code)}}})
        sandbox()

        assert run(context) == {:outcome, :rejected, false}
        assert docker_calls() == []
      end
    end

    test "an issue already ended is configuration (exit 2)", context do
      platform(context, %{"touched-paths" => {409, %{error: "issue_not_open"}}})
      sandbox()

      result = run(context)
      assert result == {:error, {:platform, 409, "issue_not_open"}}
      assert Outcome.exit_code(result) == 2
    end
  end

  describe "run/3 verify errors" do
    test "a RED test past its time limit is a timed-out side, GREEN still runs, and the platform's verify error isn't retried",
         context do
      platform(context, %{
        "verification" => {200, %{verification: "verify_error", reasons: ["timeout_red"]}}
      })

      sandbox([
        {&(runs?(&1, "npx") and "jest" in elem(&1, 1) and side?(&1, "red")), {:error, :timeout}}
      ])

      result = run(context)

      assert_received {:request, "verification", %{"red" => red, "green" => green}}
      assert red == %{"exit_code" => 124, "timed_out" => true, "report" => ""}
      assert %{"exit_code" => 0, "timed_out" => false} = green
      assert result == {:error, :verify_timed_out}
      assert Outcome.exit_code(result) == 2
    end

    test "a RED test stopped by its time limit keeps the status timeout gave it", context do
      platform(context, %{
        "verify-plan" => {200, Map.put(plan(), "test_timeout_s", 1)},
        "verification" => {200, %{verification: "verify_error", reasons: ["timeout_red"]}}
      })

      sandbox([
        {&(runs?(&1, "npx") and "jest" in elem(&1, 1) and side?(&1, "red")),
         fn _call ->
           Process.sleep(1_100)
           {:ok, %{status: 137, output: ""}}
         end}
      ])

      run(context)

      assert_received {:request, "verification",
                       %{"red" => %{"exit_code" => 137, "timed_out" => true, "report" => ""}}}
    end

    test "a test whose output passes its cap is a side with an empty report, which the platform fails",
         context do
      platform(context, %{
        "verification" => {200, %{verification: "failed", reasons: ["unparseable_report_red"]}}
      })

      sandbox([
        {&(runs?(&1, "npx") and "jest" in elem(&1, 1) and side?(&1, "red")),
         {:error, :output_too_large}}
      ])

      assert run(context) == {:outcome, :verify_failed, false}

      assert_received {:request, "verification",
                       %{"red" => %{"exit_code" => 137, "timed_out" => false, "report" => ""}}}
    end

    for {label, answer} <- [
          {"past its time limit", {:error, :timeout}},
          {"over its output cap", {:error, :output_too_large}}
        ] do
      test "an install #{label} is the side's install failure, never a timeout", context do
        platform(context, %{
          "verification" => {200, %{verification: "failed", reasons: ["install_failed_green"]}}
        })

        sandbox([
          {&(runs?(&1, "npx") and "--yes" in elem(&1, 1) and side?(&1, "green")),
           unquote(Macro.escape(answer))}
        ])

        assert run(context) == {:outcome, :verify_failed, false}
        assert_received {:request, "verification", %{"error" => "install_failed_green"}}
      end
    end

    test "a docker exec that fails is a sandbox error (exit 4)", context do
      platform(context, %{
        "verification" => {200, %{verification: "verify_error", reasons: ["sandbox"]}}
      })

      sandbox([
        {&(runs?(&1, "npx") and "jest" in elem(&1, 1) and side?(&1, "red")), {:error, :enoent}}
      ])

      result = run(context)

      assert_received {:request, "verification", %{"error" => "sandbox"}}
      assert Outcome.exit_code(result) == 4
    end

    test "a test that exits 124 inside its time limit is an ordinary failure", context do
      platform(context)

      sandbox([
        {&(runs?(&1, "npx") and "jest" in elem(&1, 1) and side?(&1, "red")),
         {:ok, %{status: 124, output: ""}}}
      ])

      run(context)

      assert_received {:request, "verification",
                       %{"red" => %{"exit_code" => 124, "timed_out" => false}}}
    end

    test "a GREEN install failure is reported, and a failed verdict is the verify_failed outcome",
         context do
      platform(context, %{
        "verification" => {200, %{verification: "failed", reasons: ["install_failed_green"]}}
      })

      sandbox([
        {&(runs?(&1, "npx") and "--yes" in elem(&1, 1) and side?(&1, "green")),
         {:ok, %{status: 1, output: "E404"}}}
      ])

      assert run(context) == {:outcome, :verify_failed, false}
      assert_received {:request, "verification", %{"error" => "install_failed_green"}}
    end

    test "a failed bootstrap is a sandbox error, which a new attempt may retry", context do
      platform(context, %{"verification" => {200, %{verification: "verify_error", reasons: []}}})

      sandbox([
        {fn {"docker", ["exec" | args], _} = call ->
           List.last(args) == "bootstrap" and side?(call, "red")
         end, {:ok, %{status: 0, output: ~s({"ok":false,"log_tail":""})}}}
      ])

      run(context)

      assert_received {:request, "verification", %{"error" => "sandbox"}}
    end

    test "a sandbox that can't start is reported, and its setup step is the exit reason",
         context do
      platform(context, %{
        "verification" => {200, %{verification: "verify_error", reasons: ["sandbox"]}}
      })

      sandbox([
        {fn {"docker", ["network", "create" | _], _} -> true end, {:ok, %{status: 1, output: ""}}}
      ])

      result = run(context)

      assert_received {:request, "verification", %{"error" => "sandbox"}}
      assert result == {:error, {:sandbox_setup, :network_create}}
      assert Outcome.exit_code(result) == 4
    end

    for {label, answer} <- [
          {"missing", {:ok, %{status: 1, output: "cat: /tmp/r.json: No such file"}}},
          {"over the platform's 4 MiB cap", {:error, :output_too_large}}
        ] do
      test "a #{label} report goes up empty", context do
        platform(context)
        sandbox([{&(runs?(&1, "cat") and side?(&1, "red")), unquote(Macro.escape(answer))}])

        run(context)

        assert_received {:request, "verification", %{"red" => %{"report" => ""}}}
      end
    end

    test "reads each report at most 4 MiB", context do
      platform(context)
      sandbox()

      run(context)

      assert for(
               {"docker", _, opts} = call <- docker_calls(),
               runs?(call, "cat"),
               do: opts[:max_bytes]
             ) ==
               [4 * 1024 * 1024, 4 * 1024 * 1024]
    end
  end
end
