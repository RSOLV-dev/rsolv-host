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
      "GITHUB_RUN_ATTEMPT" => "2",
      "GITHUB_REPOSITORY" => "acme/app",
      "ACTIONS_ID_TOKEN_REQUEST_URL" => "https://token.actions.example/id?v=1",
      "ACTIONS_ID_TOKEN_REQUEST_TOKEN" => "t"
    }

    %{env: env, io: io, workspace: workspace, base: base}
  end

  # The platform's verify endpoints; `answers` replaces any of them with
  # `{status, json}`, or `:busy` (503 with a day's Retry-After). Every
  # request is sent to the test as {:request, name, body}.
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

  defp answer(conn, _method, _name, :busy, _test) do
    conn
    |> Plug.Conn.put_resp_header("retry-after", "86400")
    |> Plug.Conn.put_status(503)
    |> Req.Test.json(%{error: "busy"})
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

  # A `docker exec`'s container, its `-e` values and its argv.
  defp exec_call({"docker", ["exec", "-i" | rest], _}), do: exec_rest(rest, [])
  defp exec_call(_call), do: nil

  defp exec_rest(["-e", value | rest], env), do: exec_rest(rest, [value | env])

  defp exec_rest([container, "timeout", "-k", _kill, _s | argv], env),
    do: {container, Enum.reverse(env), argv}

  defp exec_rest(_other, _env), do: nil

  # An exec in one of `side`'s sandboxes, BUILD or TEST.
  defp side?(call, side) do
    case exec_call(call) do
      {container, _env, _argv} -> String.contains?(container, "-#{side}-")
      nil -> false
    end
  end

  defp test_phase?(call) do
    case exec_call(call) do
      {container, _env, _argv} -> String.ends_with?(container, "-test")
      nil -> false
    end
  end

  defp runs?(call, exe) do
    case exec_call(call) do
      {_container, _env, [^exe | _]} -> true
      _other -> false
    end
  end

  # What coreutils `timeout` in the sandbox answers once a step's time is up:
  # it waits out the seconds the host gave it, then exits `status`.
  defp in_container_timeout(status \\ 124) do
    fn {"docker", args, _} ->
      [_timeout, "-k", _kill, seconds | _argv] = Enum.drop_while(args, &(&1 != "timeout"))
      Process.sleep(String.to_integer(seconds) * 1_000 + 50)
      {:ok, %{status: status, output: ""}}
    end
  end

  # `docker inspect` answering that a container it's asked about is gone.
  defp gone,
    do:
      {fn {"docker", ["inspect", "--type", "container" | _], _} -> true end,
       fn {"docker", args, _} ->
         {:ok,
          %{
            status: 1,
            output: "Error response from daemon: No such container: #{List.last(args)}\n"
          }}
       end}

  # git and cp run for real; docker answers as a sandbox whose RED test fails
  # and whose GREEN test passes. `overrides` come first.
  defp sandbox(overrides \\ []) do
    real = fn {exe, args, opts} -> Exec.run(exe, args, opts) end

    FakeExec.script(
      overrides ++
        [
          {fn {exe, _, _} -> exe in ["env", "cp"] end, real},
          {fn {"du", _, _} -> true end,
           {:ok, %{status: 0, output: "4096\t/c\n4096\t/h\n8192\ttotal\n"}}},
          {fn {"df", _, _} -> true end,
           {:ok, %{status: 0, output: "   Used  IUsed\n1000000 5000\n"}}},
          gone(),
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

  # Whether a SIGTERM trap (`RsolvHost.Sandbox.trap_sigterm/2`) that suspends
  # `pid` is installed: the trap's function closes over the process it suspends.
  defp sigterm_trapped_by?(pid) do
    :erl_signal_server
    |> :sys.get_state()
    |> Enum.any?(fn
      {System.SignalHandler, _id, {:sigterm, fun}} -> pid in elem(:erlang.fun_info(fun, :env), 1)
      _other -> false
    end)
  end

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
      test = self()

      sandbox([
        {fn {"docker", ["run", "-d", "--name", "rsolv-41-2-7-verify-" <> side | _], _} ->
           side in ["red-test", "green-test"]
         end,
         fn {"docker", args, _} ->
           [copy] =
             for mount <- args,
                 String.ends_with?(mount, ":/work"),
                 do: String.trim_trailing(mount, ":/work")

           send(
             test,
             {:copy, Path.basename(copy), File.read!(Path.join(copy, "src/a.js")),
              File.read!(Path.join(copy, "test/a.test.js"))}
           )

           {:ok, %{status: 0, output: FakeExec.docker_id(Path.basename(copy))}}
         end}
      ])

      run(context)

      assert_received {:copy, "rsolv-41-2-7-verify-red-test", @source, @test}
      assert_received {:copy, "rsolv-41-2-7-verify-green-test", @fixed, @test}
      assert File.read!(Path.join(context.workspace, "src/a.js")) == @source
      refute File.exists?(Path.join(context.workspace, "test"))
    end

    test "names its copies, homes and containers by the run attempt, and removes them once their sandboxes are gone",
         context do
      platform(context)
      sandbox()

      run(context)

      assert [
               "rsolv-41-2-7-verify-red-build",
               "rsolv-41-2-7-verify-red-test",
               "rsolv-41-2-7-verify-green-build",
               "rsolv-41-2-7-verify-green-test"
             ] =
               for(
                 {"docker", ["run", "-d", "--name", name | _], _} <- docker_calls(),
                 not String.ends_with?(name, "-proxy"),
                 do: name
               )

      # Only the run token's hand-off file, which the CLI discards, is left.
      assert File.ls!(Path.join(context.tmp_dir, "rsolv")) == ["run-token-verify-7.json"]
    end

    test "removes a copy and home the code under test left unreadable", context do
      platform(context)
      rsolv = Path.join(context.tmp_dir, "rsolv")

      # What `mkdir -p d/e && chmod 000 d/e d` leaves, made by the sandbox user (us).
      locked = fn {"docker", ["exec", "-i", container | _], _} ->
        for dir <- [container, container <> "-home"] do
          File.mkdir_p!(Path.join([rsolv, dir, "d/e"]))
          File.write!(Path.join([rsolv, dir, "d/e/f"]), "x")
          File.chmod!(Path.join([rsolv, dir, "d/e"]), 0o000)
          File.chmod!(Path.join([rsolv, dir, "d"]), 0o000)
        end

        {:ok, %{status: 0, output: "PASS"}}
      end

      sandbox([{&(runs?(&1, "npx") and "jest" in elem(&1, 1) and side?(&1, "green")), locked}])

      assert run(context) == {:outcome, :verified, false}
      assert File.ls!(rsolv) == ["run-token-verify-7.json"]
    end

    test "warns, naming the path, when it can't remove a copy, and keeps the verdict", context do
      platform(context)
      rsolv = Path.join(context.tmp_dir, "rsolv")
      on_exit(fn -> File.chmod(rsolv, 0o700) end)

      # A copy the host can't remove: its parent no longer writable.
      readonly = fn _call ->
        File.chmod!(rsolv, 0o500)
        {:ok, %{status: 0, output: "PASS"}}
      end

      sandbox([{&(runs?(&1, "npx") and "jest" in elem(&1, 1) and side?(&1, "green")), readonly}])

      assert run(context) == {:outcome, :verified, false}

      {:ok, {_in, out}} = StringIO.close(context.io)

      assert out =~
               "::warning title=RSOLV::Couldn't remove " <>
                 Path.join(rsolv, "rsolv-41-2-7-verify-green-test")
    end

    test "keeps what a sandbox it couldn't confirm removed, and a retry on the same runner doesn't collide",
         context do
      platform(context, %{
        "verification" => {200, %{verification: "verify_error", reasons: ["sandbox"]}}
      })

      sandbox([{fn {"docker", ["rm", "-f" | _], _} -> true end, {:ok, %{status: 1, output: ""}}}])

      assert run(context) == {:error, {:sandbox, :teardown}}
      assert_received {:request, "verification", %{"error" => "sandbox"}}
      kept = File.ls!(Path.join(context.tmp_dir, "rsolv"))

      assert "rsolv-41-2-7-verify-red-build" in kept and
               "home-rsolv-41-2-7-verify-red-build" in kept

      env = Map.put(context.env, "GITHUB_RUN_ATTEMPT", "3")
      assert Verify.run(%{issue: 7}, env, deps(context)) == {:error, {:sandbox, :teardown}}
    end

    test "runs no git once the first sandbox has started, and copies only the checkout or a BUILD Docker confirmed gone (acceptance 5a, B3)",
         context do
      platform(context)
      sandbox()

      run(context)

      after_first_sandbox =
        Enum.drop_while(FakeExec.calls(), &(not match?({"docker", ["run" | _], _}, &1)))

      assert after_first_sandbox != []

      assert for({exe, _, _} <- after_first_sandbox, exe != "docker", do: exe)
             |> Enum.uniq()
             |> Enum.sort() == ["cp", "df", "du"]

      rsolv = Path.join(context.tmp_dir, "rsolv")

      for {{"cp", ["-a", "--", src, _dest], _}, i} <- Enum.with_index(after_first_sandbox),
          src = String.trim_trailing(src, "/."),
          src != context.workspace do
        assert [_, side] = Regex.run(~r/verify-(red|green)-build\z/, src)
        id = FakeExec.docker_id("rsolv-41-2-7-verify-#{side}-build")

        assert Enum.any?(Enum.take(after_first_sandbox, i), fn call ->
                 match?({"docker", ["inspect", "--type", "container", _, _, ^id], _}, call)
               end),
               "#{src} copied before its BUILD was confirmed gone"

        assert String.starts_with?(src, rsolv)
      end
    end

    test "removes every sandbox and proxy, by ID, and each BUILD's network", context do
      platform(context)
      sandbox()

      run(context)

      removed = for {"docker", ["rm", "-f" | names], _} <- docker_calls(), do: names
      networks = for {"docker", ["network", "rm", net], _} <- docker_calls(), do: net

      id = &FakeExec.docker_id/1

      assert removed == [
               [id.("rsolv-41-2-7-verify-red-build"), id.("rsolv-41-2-7-verify-red-build-proxy")],
               [id.("rsolv-41-2-7-verify-red-test")],
               [
                 id.("rsolv-41-2-7-verify-green-build"),
                 id.("rsolv-41-2-7-verify-green-build-proxy")
               ],
               [id.("rsolv-41-2-7-verify-green-test")]
             ]

      assert networks == [
               id.("rsolv-41-2-7-verify-red-build-net"),
               id.("rsolv-41-2-7-verify-green-build-net")
             ]
    end

    test "prints sandbox output only as untrusted text", context do
      platform(context)
      sandbox()

      run(context)

      {:ok, {_in, out}} = StringIO.close(context.io)
      assert out =~ ~r/::stop-commands::([0-9a-f]{32})\nFAIL\n::\1::\n/
    end
  end

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

    test "needs the run attempt, which names its containers", context do
      platform(context)
      sandbox()
      env = Map.delete(context.env, "GITHUB_RUN_ATTEMPT")

      assert Verify.run(%{issue: 7}, env, deps(context)) ==
               {:error, {:missing_env, "GITHUB_RUN_ATTEMPT"}}
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

  describe "run/3's deadline" do
    for name <- ~w(touched-paths base-facts verify-plan post-images verification) do
      test "#{name} answering 503 with a day's Retry-After ends at the role's deadline, transient (exit 3)",
           context do
        platform(context, %{unquote(name) => :busy})
        sandbox()
        start = System.monotonic_time(:millisecond)

        result = Verify.run(%{issue: 7}, context.env, deps(context) ++ [budget_ms: 1_500])

        assert Outcome.exit_code(result) == 3
        assert System.monotonic_time(:millisecond) - start < 3_000
      end
    end
  end

  describe "run/3's containers and time" do
    test "labels each sandbox, proxy and network with its repository, run, issue, attempt and instance",
         context do
      platform(context)
      sandbox()

      run(context)

      labelled =
        for {"docker", args, _} <- docker_calls(),
            match?(["run" | _], args) or match?(["network", "create" | _], args),
            do: for([flag, value] <- Enum.chunk_every(args, 2, 1), flag == "--label", do: value)

      # Each side's BUILD sandbox, proxy and network, and its TEST sandbox.
      assert length(labelled) == 8

      assert [[attempt, "rsolv.instance=" <> instance | rest]] = Enum.uniq(labelled)

      assert [attempt | rest] ==
               ~w(rsolv.attempt=2 rsolv.issue=7 rsolv.repo=acme/app rsolv.run=41)

      assert instance =~ ~r/\A[0-9a-f]{16}\z/
    end

    for repository <- ["acme", "acme/app/x", "acme/a b", "acme/app\n", "-x/app"] do
      test "refuses GITHUB_REPOSITORY #{inspect(repository)}, which labels its containers",
           context do
        platform(context)
        sandbox()
        env = Map.put(context.env, "GITHUB_REPOSITORY", unquote(repository))

        assert Verify.run(%{issue: 7}, env, deps(context)) ==
                 {:error, {:missing_env, "GITHUB_REPOSITORY"}}

        assert FakeExec.calls() == []
      end
    end

    test "first removes, by ID, what an earlier attempt of this issue left, and nothing else",
         context do
      platform(context)

      sandbox([
        {fn {"docker", ["ps", "-a" | _], _} -> true end,
         {:ok, %{status: 0, output: "aaa\t1\nbbb\t2\nccc\t3\nddd\t\n"}}},
        {fn {"docker", ["network", "ls" | _], _} -> true end,
         {:ok, %{status: 0, output: "nnn\t1\nmmm\t2\n"}}}
      ])

      run(context)

      identity =
        ~w(--filter label=rsolv.repo=acme/app --filter label=rsolv.run=41 --filter label=rsolv.issue=7)

      assert [
               {"docker", ["ps", "-a" | ps], _},
               {"docker", ["rm", "-f", "aaa"], _},
               {"docker", ["network", "ls" | ls], _},
               {"docker", ["network", "rm", "nnn"], _} | _
             ] = docker_calls()

      assert Enum.take(ps, 6) == identity and Enum.take(ls, 6) == identity
    end

    test "traps SIGTERM before it removes what an earlier attempt left", context do
      platform(context)

      sandbox([
        {fn {"docker", ["ps", "-a" | _], _} ->
           send(self(), {:stale_cleanup, sigterm_trapped_by?(self())})
           false
         end, :unused}
      ])

      run(context)

      assert_received {:stale_cleanup, true}
    end

    test "fits every sandbox stage in the role's budget, RED in half of it", context do
      platform(context)
      sandbox()
      # Five minutes are kept for removing the sandboxes and reporting.
      budget_ms = 5 * 60_000 + 60_000

      Verify.run(%{issue: 7}, context.env, deps(context) ++ [budget_ms: budget_ms])

      limits =
        for {"docker", ["exec", "-i", container, "timeout", "-k", _, s | _], opts} <-
              docker_calls(),
            do: {String.contains?(container, "-red-"), String.to_integer(s), opts[:timeout_ms]}

      assert length(limits) == 8

      for {red?, seconds, host_ms} <- limits do
        assert seconds <= if(red?, do: 30, else: 60)
        assert host_ms < (seconds + 1) * 1_000 + 30_000
      end

      assert for({"docker", ["run" | _], opts} <- docker_calls(), do: opts[:timeout_ms])
             |> Enum.all?(&(&1 <= 60_000))

      # Each side's copies are clamped to its deadline: RED's 30 s, GREEN's 60.
      assert [red_build, red_home, green_build, green_home] =
               for(
                 {"cp", ["-a", "--", src, _], opts} <- FakeExec.calls(),
                 String.contains?(src, "-build"),
                 do: opts[:timeout_ms]
               )

      assert red_build <= 30_000 and red_home <= 30_000
      assert green_build <= 60_000 and green_home <= 60_000
    end
  end

  describe "run/3's disk budget" do
    defp du(bytes), do: {:ok, %{status: 0, output: "#{bytes}\t/c\n0\t/h\n#{bytes}\ttotal\n"}}

    test "measures the copy and its home with a no-follow du before bootstrap, which runs under the watchdog (review: Kimi HIGH)",
         context do
      platform(context)
      sandbox()

      run(context)

      calls = FakeExec.calls()
      first_du = Enum.find_index(calls, &match?({"du", _, _}, &1))

      first_bootstrap =
        Enum.find_index(calls, &match?({"docker", ["exec" | _], _}, &1))

      assert first_du < first_bootstrap
      assert [{"du", args, opts} | _] = for({"du", _, _} = call <- calls, do: call)
      copy = Path.join([context.tmp_dir, "rsolv", "rsolv-41-2-7-verify-red-build"])
      home = Path.join([context.tmp_dir, "rsolv", "home-rsolv-41-2-7-verify-red-build"])
      assert args == ["-s", "-c", "-x", "-P", "-B1", "--", copy, home]
      assert opts[:timeout_ms] <= 30_000
    end

    test "a TEST writing past its budget is killed, and is a sandbox error, never a side result (review: Kimi HIGH)",
         context do
      platform(context, %{
        "verification" => {200, %{verification: "verify_error", reasons: ["sandbox"]}}
      })

      testing = :counters.new(1, [])

      sandbox([
        {fn {"du", _, _} -> true end,
         fn _call ->
           # 5 GiB and one byte past the baseline, once RED's test runs.
           if :counters.get(testing, 1) == 1, do: du(1_000 + 5 * 1024 ** 3 + 1), else: du(1_000)
         end},
        {&(runs?(&1, "npx") and "jest" in elem(&1, 1) and side?(&1, "red")),
         fn _call ->
           :counters.put(testing, 1, 1)
           Process.sleep(300)
           {:ok, %{status: 137, output: ""}}
         end}
      ])

      result = Verify.run(%{issue: 7}, context.env, deps(context) ++ [disk_poll_ms: 20])

      assert result == {:error, {:sandbox, :disk_limit}}
      assert Outcome.exit_code(result) == 4
      assert_received {:request, "verification", %{"error" => "sandbox"} = body}
      refute Map.has_key?(body, "red")

      red = FakeExec.docker_id("rsolv-41-2-7-verify-red-test")
      assert Enum.any?(docker_calls(), &match?({"docker", ["kill", ^red], _}, &1))

      {:ok, {_in, out}} = StringIO.close(context.io)
      assert out =~ "disk_limit"
    end

    test "a BUILD bootstrap writing past its budget is a sandbox error (review: Kimi HIGH)",
         context do
      platform(context, %{
        "verification" => {200, %{verification: "verify_error", reasons: ["sandbox"]}}
      })

      booting = :counters.new(1, [])

      sandbox([
        {fn {"du", _, _} -> true end,
         fn _call ->
           if :counters.get(booting, 1) == 1, do: du(1_000 + 5 * 1024 ** 3 + 1), else: du(1_000)
         end},
        {fn {"docker", ["exec" | args], _} = call ->
           List.last(args) == "bootstrap" and side?(call, "red")
         end,
         fn _call ->
           :counters.put(booting, 1, 1)
           Process.sleep(300)
           {:ok, %{status: 0, output: ~s({"ok":true,"ecosystems":[],"log_tail":""})}}
         end}
      ])

      result = Verify.run(%{issue: 7}, context.env, deps(context) ++ [disk_poll_ms: 20])

      assert result == {:error, {:sandbox, :disk_limit}}
      assert_received {:request, "verification", %{"error" => "sandbox"}}

      refute Enum.any?(
               docker_calls(),
               &match?(
                 {"docker", ["run", "-d", "--name", "rsolv-41-2-7-verify-red-test" | _], _},
                 &1
               )
             )
    end

    for {label, over} <- [
          {"blocks (a file unlinked while open, which du can't see)",
           "#{1_000_000 + 5 * 1024 ** 3 + 1} 5000"},
          {"inodes", "1000000 #{5000 + 1_000_001}"}
        ] do
      test "a TEST that grows its filesystem's used #{label} past the budget is a sandbox error (review round 2: Kimi)",
           context do
        platform(context, %{
          "verification" => {200, %{verification: "verify_error", reasons: ["sandbox"]}}
        })

        testing = :counters.new(1, [])

        sandbox([
          {fn {"df", _, _} -> true end,
           fn _call ->
             used = if :counters.get(testing, 1) == 1, do: unquote(over), else: "1000000 5000"
             {:ok, %{status: 0, output: "   Used  IUsed\n#{used}\n"}}
           end},
          {&(runs?(&1, "npx") and "jest" in elem(&1, 1) and side?(&1, "red")),
           fn _call ->
             :counters.put(testing, 1, 1)
             Process.sleep(300)
             {:ok, %{status: 0, output: ""}}
           end}
        ])

        result = Verify.run(%{issue: 7}, context.env, deps(context) ++ [disk_poll_ms: 20])

        assert result == {:error, {:sandbox, :disk_limit}}
        assert_received {:request, "verification", %{"error" => "sandbox"}}
      end
    end

    test "a side within its budget is never killed", context do
      platform(context)
      sandbox()

      assert Verify.run(%{issue: 7}, context.env, deps(context) ++ [disk_poll_ms: 5]) ==
               {:outcome, :verified, false}

      refute Enum.any?(docker_calls(), &match?({"docker", ["kill" | _], _}, &1))
    end
  end

  describe "run/3 verify errors" do
    test "a RED test past its time limit is a timed-out side, GREEN still runs, and the platform fails it",
         context do
      platform(context, %{
        "verify-plan" => {200, Map.put(plan(), "test_timeout_s", 1)},
        "verification" => {200, %{verification: "failed", reasons: ["red_timed_out"]}}
      })

      sandbox([
        {&(runs?(&1, "npx") and "jest" in elem(&1, 1) and side?(&1, "red")),
         in_container_timeout()}
      ])

      result = run(context)

      assert_received {:request, "verification", %{"red" => red, "green" => green}}
      assert red == %{"exit_code" => 124, "timed_out" => true, "report" => ""}
      assert %{"exit_code" => 0, "timed_out" => false} = green
      assert result == {:outcome, :verify_failed, false}
    end

    test "a RED test stopped by its time limit keeps the status timeout gave it", context do
      platform(context, %{
        "verify-plan" => {200, Map.put(plan(), "test_timeout_s", 1)},
        "verification" => {200, %{verification: "failed", reasons: ["red_timed_out"]}}
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

    # Both sides ran, so the platform's reasons, not the host, say why it
    # judged nothing (staging run arubis/rsolv-v5-pytest-demo 44467074623:
    # build_evidence_invalid ended as "tests ran past their time limit").
    for {reasons, error, code} <- [
          {["build_evidence_invalid:red", "build_evidence_invalid:green"],
           :build_evidence_refused, 2},
          {["build_evidence_invalid:green"], :build_evidence_refused, 2},
          {["build_evidence_unsupported:jest"], :build_evidence_unsupported, 2},
          {["report_timeout_red", "build_evidence_invalid:green"], :build_evidence_refused, 2},
          {["build_env_drift"], :build_env_drift, 3},
          {["report_timeout_red"], :verify_error, 4},
          {[], :verify_error, 4},
          {"not a list", :verify_error, 4}
        ] do
      test "the platform's verify error for #{inspect(reasons)} after both sides ran is #{error} (exit #{code})",
           context do
        platform(context, %{
          "verification" =>
            {200, %{verification: "verify_error", reasons: unquote(Macro.escape(reasons))}}
        })

        sandbox()

        result = run(context)

        assert_received {:request, "verification", %{"red" => _red, "green" => _green}}
        assert result == {:error, unquote(error)}
        assert Outcome.exit_code(result) == unquote(code)
      end
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
          {"past its time limit", quote(do: in_container_timeout())},
          {"over its output cap", Macro.escape({:error, :output_too_large})}
        ] do
      test "an install #{label} is the side's install failure, never a timeout", context do
        platform(context, %{
          "verify-plan" => {200, Map.put(plan(), "install_timeout_s", 1)},
          "verification" => {200, %{verification: "failed", reasons: ["install_failed_green"]}}
        })

        sandbox([
          {&(runs?(&1, "npx") and "--yes" in elem(&1, 1) and side?(&1, "green")), unquote(answer)}
        ])

        assert run(context) == {:outcome, :verify_failed, false}
        assert_received {:request, "verification", %{"error" => "install_failed_green"}}
      end
    end

    for {step, matcher} <- [
          {"install", quote(do: &(runs?(&1, "npx") and "--yes" in elem(&1, 1)))},
          {"test_prepare", quote(do: &runs?(&1, "bundle"))},
          {"test", quote(do: &(runs?(&1, "npx") and "jest" in elem(&1, 1)))},
          {"report", quote(do: &runs?(&1, "cat"))}
        ] do
      test "a #{step} docker exec the host stops past its grace is a sandbox error (exit 4), never a test timeout (review: Kimi MEDIUM)",
           context do
        v2(context, %{
          "verification" => {200, %{verification: "verify_error", reasons: ["sandbox"]}}
        })

        sandbox([{unquote(matcher), {:error, :timeout}}])

        result = run(context)

        assert body()["error"] == "sandbox"
        assert result == {:error, {:sandbox, :timeout}}
        assert Outcome.exit_code(result) == 4
      end
    end

    for {phase, name} <- [
          {"BUILD", "rsolv-41-2-7-verify-red-build"},
          {"TEST", "rsolv-41-2-7-verify-red-test"}
        ] do
      test "a #{phase} sandbox that can't start, once Docker confirms nothing by its name is left, leaves no copy or HOME (review: Kimi LOW)",
           context do
        platform(context, %{
          "verification" => {200, %{verification: "verify_error", reasons: ["sandbox"]}}
        })

        sandbox([
          {fn {"docker", ["run", "-d", "--name", unquote(name) | _], _} -> true end,
           {:ok, %{status: 1, output: ""}}}
        ])

        assert run(context) == {:error, {:sandbox_setup, :sandbox_run}}
        assert body()["error"] == "sandbox"
        assert File.ls!(Path.join(context.tmp_dir, "rsolv")) == ["run-token-verify-7.json"]
      end

      test "a #{phase} sandbox that can't start, with a container by its name still there, keeps its copy and HOME",
           context do
        platform(context, %{
          "verification" => {200, %{verification: "verify_error", reasons: ["sandbox"]}}
        })

        sandbox([
          {fn {"docker", ["run", "-d", "--name", unquote(name) | _], _} -> true end,
           {:error, :timeout}},
          {fn {"docker", ["inspect", "--type", "container", _, _, unquote(name)], _} -> true end,
           {:ok, %{status: 0, output: "abc\n"}}}
        ])

        assert run(context) == {:error, {:sandbox, :teardown}}
        assert unquote(name) in File.ls!(Path.join(context.tmp_dir, "rsolv"))
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

    test "a setup step its side's deadline stops is still a sandbox error (exit 4)", context do
      platform(context, %{
        "verification" => {200, %{verification: "verify_error", reasons: ["sandbox"]}}
      })

      sandbox([
        {fn {"docker", ["network", "create" | _], opts} ->
           Process.sleep(opts[:timeout_ms])
           true
         end, {:error, :timeout}}
      ])

      result =
        Verify.run(%{issue: 7}, context.env, deps(context) ++ [budget_ms: 5 * 60_000 + 1_000])

      assert_received {:request, "verification", %{"error" => "sandbox"}}
      assert result == {:error, {:sandbox, :deadline}}
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

  # A v2 plan: project tooling in BUILD's prepare, two TEST prepare steps and
  # an env, as the platform's Rails template has.
  defp plan_v2(overrides \\ %{}) do
    plan()
    |> Map.merge(%{
      "v" => 2,
      "prepare" => [["npx", "--no-install", "tsc", "-b"], ["rm", "-rf", "--", "build/cache"]],
      "test_prepare" => [
        ["rm", "-f", "--", "/tmp/r.json"],
        ["bundle", "exec", "rake", "db:prepare"]
      ],
      "env" => %{"RAILS_ENV" => "test"}
    })
    |> Map.merge(overrides)
  end

  defp v2(context, answers \\ %{}),
    do: platform(context, Map.merge(%{"verify-plan" => {200, plan_v2()}}, answers))

  # Each Docker or cp call `side` made, named by its step.
  defp events(side) do
    rsolv_side = "rsolv-41-2-7-verify-#{side}"
    build = FakeExec.docker_id(rsolv_side <> "-build")
    proxy = FakeExec.docker_id(rsolv_side <> "-build-proxy")
    test = FakeExec.docker_id(rsolv_side <> "-test")

    for call <- FakeExec.calls(), event = event(call, rsolv_side, {build, proxy, test}), do: event
  end

  defp event({"docker", ["run", "-d", "--name", name | args], _}, rsolv_side, _ids) do
    cond do
      name == rsolv_side <> "-build" ->
        {:run_build, "--read-only" in args}

      name == rsolv_side <> "-test" ->
        {:run_test, ["--network", "none"] in Enum.chunk_every(args, 2, 1), "--read-only" in args}

      true ->
        nil
    end
  end

  defp event({"docker", ["network", "disconnect", _net, name], _}, rsolv_side, _ids),
    do: if(name == rsolv_side <> "-build", do: :disconnect)

  defp event({"docker", ["rm", "-f" | ids], _}, _rsolv_side, {build, proxy, test}) do
    cond do
      ids == [build, proxy] -> :rm_build
      ids == [test] -> :rm_test
      true -> nil
    end
  end

  defp event({"docker", ["inspect", "--type", "container", _, _, id], _}, _side, {b, p, t}) do
    cond do
      id in [b, p] -> :gone_build
      id == t -> :gone_test
      true -> nil
    end
  end

  defp event({"cp", ["-a", "--", src, _dest], _}, rsolv_side, _ids) do
    cond do
      String.ends_with?(src, "/" <> rsolv_side <> "-build/.") -> :cp_copy
      String.ends_with?(src, "/home-" <> rsolv_side <> "-build/.") -> :cp_home
      true -> nil
    end
  end

  defp event(call, rsolv_side, _ids) do
    case exec_call(call) do
      {container, env, argv} ->
        if String.starts_with?(container, rsolv_side <> "-"),
          do: {exec_step(argv), String.ends_with?(container, "-test"), env}

      nil ->
        nil
    end
  end

  defp exec_step(["rsolv-sandbox", "bootstrap"]), do: :bootstrap
  defp exec_step(["npx", "--yes" | _]), do: :install
  defp exec_step(["npx", "--no-install", "tsc" | _]), do: :prepare
  defp exec_step(["rm", "-rf", "--", "build/cache"]), do: :prepare
  defp exec_step(["rm", "-f", "--", "/tmp/r.json"]), do: :test_prepare
  defp exec_step(["bundle", "exec", "rake", "db:prepare"]), do: :test_prepare
  defp exec_step(["npx", "--no-install", "jest" | _]), do: :test
  defp exec_step(["cat" | _]), do: :report

  defp body do
    assert_received {:request, "verification", body}
    body
  end

  describe "run/3's two-phase side (BUILD on the base, then TEST)" do
    test "runs each side's BUILD, confirms it gone, copies it, then runs TEST offline and read-only, RED before GREEN",
         context do
      v2(context)
      sandbox()

      assert run(context) == {:outcome, :verified, false}

      env = ["RAILS_ENV=test"]

      for side <- ["red", "green"] do
        assert events(side) == [
                 {:run_build, true},
                 {:bootstrap, false, []},
                 {:install, false, []},
                 :disconnect,
                 {:prepare, false, []},
                 {:prepare, false, []},
                 :rm_build,
                 :gone_build,
                 :gone_build,
                 :cp_copy,
                 :cp_home,
                 {:run_test, true, true},
                 {:test_prepare, true, env},
                 {:test_prepare, true, env},
                 {:test, true, env},
                 {:report, true, env},
                 :rm_test,
                 :gone_test
               ]
      end

      calls = FakeExec.calls()

      last_red =
        Enum.find_index(
          calls,
          &(event(
              &1,
              "rsolv-41-2-7-verify-red",
              {nil, nil, FakeExec.docker_id("rsolv-41-2-7-verify-red-test")}
            ) == :gone_test)
        )

      first_green =
        Enum.find_index(
          calls,
          &match?(
            {"docker", ["run", "-d", "--name", "rsolv-41-2-7-verify-green-build" | _], _},
            &1
          )
        )

      assert last_red < first_green
    end

    test "a v1 plan follows the same flow, with no TEST prepare and no env", context do
      platform(context)
      sandbox()

      run(context)

      for side <- ["red", "green"] do
        assert events(side) == [
                 {:run_build, true},
                 {:bootstrap, false, []},
                 {:install, false, []},
                 :disconnect,
                 :rm_build,
                 :gone_build,
                 :gone_build,
                 :cp_copy,
                 :cp_home,
                 {:run_test, true, true},
                 {:test, true, []},
                 {:report, true, []},
                 :rm_test,
                 :gone_test
               ]
      end
    end

    test "walks nothing in a tree BUILD wrote: a symlinked .git/refs it planted is copied as a link, and what it names is untouched",
         context do
      platform(context)
      host = Path.join(context.tmp_dir, "host")
      File.mkdir_p!(host)
      File.write!(Path.join(host, "x.lock"), "host's own\n")
      rsolv = Path.join(context.tmp_dir, "rsolv")

      sandbox([
        {&(runs?(&1, "npx") and "--yes" in elem(&1, 1) and side?(&1, "red")),
         fn _call ->
           git = Path.join([rsolv, "rsolv-41-2-7-verify-red-build", ".git"])
           File.write!(Path.join(git, "index.lock"), "BUILD's\n")
           File.rm_rf!(Path.join(git, "refs"))
           File.ln_s!(host, Path.join(git, "refs"))
           {:ok, %{status: 0, output: ""}}
         end}
      ])

      test = self()

      observe = fn %{side: side, test: copy} ->
        send(test, {:lock, side, File.read(Path.join(copy, ".git/index.lock"))})
      end

      Verify.run(%{issue: 7}, context.env, deps(context) ++ [observe: observe])

      assert File.read!(Path.join(host, "x.lock")) == "host's own\n"
      assert_received {:lock, "red", {:ok, "BUILD's\n"}}
    end

    test "BUILD never sees a fix byte: every change-set path holds its base", context do
      platform(context)
      test = self()

      sandbox([
        {fn {"docker", ["run", "-d", "--name", "rsolv-41-2-7-verify-" <> rest | _], _} ->
           String.ends_with?(rest, "-build")
         end,
         fn {"docker", ["run", "-d", "--name", name | args], _} ->
           [copy] =
             for m <- args, String.ends_with?(m, ":/work"), do: String.trim_trailing(m, ":/work")

           send(
             test,
             {:build, name, File.read!(Path.join(copy, "src/a.js")),
              File.exists?(Path.join(copy, "test/a.test.js"))}
           )

           {:ok, %{status: 0, output: FakeExec.docker_id(name)}}
         end}
      ])

      run(context)

      assert_received {:build, "rsolv-41-2-7-verify-red-build", @source, false}
      assert_received {:build, "rsolv-41-2-7-verify-green-build", @source, false}
    end

    test "no container mounts another phase's or another side's directories", context do
      platform(context)
      sandbox()

      run(context)

      mounts =
        for {"docker", ["run", "-d", "--name", name | args], _} <- docker_calls(),
            not String.ends_with?(name, "-proxy"),
            into: %{},
            do:
              {name,
               for(["-v", m] <- Enum.chunk_every(args, 2, 1), do: m |> String.split(":") |> hd())}

      rsolv = Path.join(context.tmp_dir, "rsolv")

      for side <- ["red", "green"], phase <- ["build", "test"] do
        name = "rsolv-41-2-7-verify-#{side}-#{phase}"

        home =
          if phase == "build",
            do: Path.join(rsolv, "home-" <> name),
            else: Path.join(rsolv, name <> "-home")

        assert mounts[name] == [Path.join(rsolv, name), home]
      end

      all = mounts |> Map.values() |> List.flatten()
      assert length(all) == length(Enum.uniq(all))
    end

    test "removes each BUILD's directories after copying them, before the overlay and TEST",
         context do
      platform(context)
      test = self()
      rsolv = Path.join(context.tmp_dir, "rsolv")

      sandbox([
        {fn {"docker", ["run", "-d", "--name", "rsolv-41-2-7-verify-red-test" | _], _} ->
           true
         end,
         fn {"docker", ["run", "-d", "--name", name | _], _} ->
           send(test, {:at_test_run, File.ls!(rsolv) |> Enum.sort()})
           {:ok, %{status: 0, output: FakeExec.docker_id(name)}}
         end}
      ])

      run(context)

      assert_received {:at_test_run, dirs}
      refute "rsolv-41-2-7-verify-red-build" in dirs
      refute "home-rsolv-41-2-7-verify-red-build" in dirs

      assert "rsolv-41-2-7-verify-red-test" in dirs and
               "rsolv-41-2-7-verify-red-test-home" in dirs
    end

    test "deps[:observe] sees both copies after cp -a and before BUILD's are removed", context do
      platform(context)
      sandbox()
      test = self()

      observe = fn %{side: side, build: build, test: copy, build_home: bh, test_home: th} ->
        send(
          test,
          {:observed, side, File.dir?(build), File.dir?(bh),
           File.read!(Path.join(copy, "src/a.js")), File.dir?(th)}
        )
      end

      Verify.run(%{issue: 7}, context.env, deps(context) ++ [observe: observe])

      # Before the overlay: TEST's copy still holds the base.
      assert_received {:observed, "red", true, true, @source, true}
      assert_received {:observed, "green", true, true, @source, true}
    end

    test "a failing install ends the side as install_failed before prepare, and no TEST starts",
         context do
      v2(context, %{
        "verification" => {200, %{verification: "failed", reasons: ["install_failed_red"]}}
      })

      sandbox([
        {&(runs?(&1, "npx") and "--yes" in elem(&1, 1) and side?(&1, "red")),
         {:ok, %{status: 1, output: "E404"}}}
      ])

      assert run(context) == {:outcome, :verify_failed, false}
      assert %{"error" => "install_failed_red"} = body()

      assert Enum.map(events("red"), &((is_tuple(&1) && elem(&1, 0)) || &1)) == [
               :run_build,
               :bootstrap,
               :install,
               :rm_build,
               :gone_build,
               :gone_build
             ]

      assert events("green") == []
      assert File.ls!(Path.join(context.tmp_dir, "rsolv")) == ["run-token-verify-7.json"]
    end

    for {phase, names} <- [
          {"BUILD", ["rsolv-41-2-7-verify-red-build", "rsolv-41-2-7-verify-red-build-proxy"]},
          {"TEST", ["rsolv-41-2-7-verify-red-test"]}
        ] do
      test "a #{phase} teardown Docker can't confirm is a sandbox error, and nothing later starts",
           context do
        platform(context, %{
          "verification" => {200, %{verification: "verify_error", reasons: ["sandbox"]}}
        })

        ids = Enum.map(unquote(names), &FakeExec.docker_id/1)

        sandbox([
          {fn {"docker", ["rm", "-f" | removed], _} -> removed == ids end,
           {:ok, %{status: 1, output: ""}}}
        ])

        assert run(context) == {:error, {:sandbox, :teardown}}
        assert body() |> Map.take(["error", "red", "green"]) == %{"error" => "sandbox"}
        assert events("green") == []

        {:ok, {_in, out}} = StringIO.close(context.io)
        assert out =~ "::warning"
        kept = File.ls!(Path.join(context.tmp_dir, "rsolv"))

        if unquote(phase) == "BUILD" do
          assert "rsolv-41-2-7-verify-red-build" in kept
          refute Enum.any?(kept, &String.contains?(&1, "-test"))
          refute Enum.any?(events("red"), &match?({:run_test, _, _}, &1))
        else
          assert "rsolv-41-2-7-verify-red-test" in kept
          refute "rsolv-41-2-7-verify-red-build" in kept
        end
      end
    end

    for side <- ["red", "green"],
        {label, answer} <- [
          {"exits 1", Macro.escape({:ok, %{status: 1, output: "boom"}})},
          {"times out", quote(do: in_container_timeout())},
          {"floods its output", Macro.escape({:error, :output_too_large})}
        ] do
      test "a #{side} TEST prepare step that #{label} is prepare_failed_#{side}, and the test never runs",
           context do
        v2(context, %{"verification" => {200, %{verification: "verify_error", reasons: []}}})

        sandbox([
          {&(runs?(&1, "bundle") and side?(&1, unquote(side))), unquote(answer)}
        ])

        # A budget that leaves each side seconds, so a step that times out
        # does so on its clamped limit.
        Verify.run(%{issue: 7}, context.env, deps(context) ++ [budget_ms: 5 * 60_000 + 8_000])

        assert body()["error"] == "prepare_failed_" <> unquote(side)
        refute Enum.any?(events(unquote(side)), &match?({:test, _, _}, &1))
        assert :gone_test in events(unquote(side))
      end
    end

    for side <- ["red", "green"] do
      test "a #{side} TEST prepare step past the disk budget is a sandbox error, never prepare_failed (review: Kimi HIGH)",
           context do
        v2(context, %{"verification" => {200, %{verification: "verify_error", reasons: []}}})
        preparing = :counters.new(1, [])

        sandbox([
          {fn {"du", _, _} -> true end,
           fn _call ->
             if :counters.get(preparing, 1) == 1,
               do: {:ok, %{status: 0, output: "#{5 * 1024 ** 3 + 9_000}\ttotal\n"}},
               else: {:ok, %{status: 0, output: "1000\ttotal\n"}}
           end},
          {&(runs?(&1, "bundle") and side?(&1, unquote(side))),
           fn _call ->
             :counters.put(preparing, 1, 1)
             Process.sleep(200)
             {:ok, %{status: 0, output: ""}}
           end}
        ])

        Verify.run(%{issue: 7}, context.env, deps(context) ++ [disk_poll_ms: 20])

        assert body()["error"] == "sandbox"
        refute Enum.any?(events(unquote(side)), &match?({:test, _, _}, &1))
      end
    end

    test "TEST prepare output goes only to the log, as untrusted text, never to the platform",
         context do
      v2(context)

      sandbox([
        {&(runs?(&1, "bundle") and test_phase?(&1)),
         {:ok, %{status: 0, output: "PREPARE-ONLY-MARKER"}}}
      ])

      run(context)

      body = body()
      refute JSON.encode!(body) =~ "PREPARE-ONLY-MARKER"
      refute JSON.encode!(body) =~ Base.encode64("PREPARE-ONLY-MARKER")

      {:ok, {_in, out}} = StringIO.close(context.io)
      assert out =~ ~r/::stop-commands::([0-9a-f]{32})\nPREPARE-ONLY-MARKER\n::\1::\n/
    end

    test "sets the plan's env on every TEST exec and on no BUILD exec", context do
      v2(context)
      sandbox()

      run(context)

      for call <- docker_calls(), {_container, env, _argv} <- [exec_call(call)] do
        if test_phase?(call), do: assert(env == ["RAILS_ENV=test"]), else: assert(env == [])
      end
    end

    test "execs only test_prepare, test and report in TEST", context do
      v2(context)
      sandbox()

      run(context)

      allowed = plan_v2()["test_prepare"] ++ [plan_v2()["test"], plan_v2()["report"]["argv"]]

      for call <- docker_calls(), test_phase?(call) do
        {_container, _env, argv} = exec_call(call)
        assert argv in allowed
      end
    end

    test "a BUILD that rewrites a fix target makes the overlay refuse: install_failed with overlay_refused",
         context do
      v2(context, %{"verification" => {200, %{verification: "verify_error", reasons: []}}})
      rsolv = Path.join(context.tmp_dir, "rsolv")

      sandbox([
        {&(runs?(&1, "npx") and "tsc" in elem(&1, 1) and side?(&1, "green")),
         fn _call ->
           File.write!(
             Path.join([rsolv, "rsolv-41-2-7-verify-green-build", "src/a.js"]),
             "planted\n"
           )

           {:ok, %{status: 0, output: ""}}
         end}
      ])

      assert run(context) == {:error, :overlay_refused}
      assert body()["error"] == "install_failed_green"
      refute Enum.any?(events("green"), &match?({:run_test, _, _}, &1))
      assert File.ls!(rsolv) == ["run-token-verify-7.json"]
    end
  end

  describe "run/3's build evidence (spec §3.1)" do
    test "reports every install and prepare step's output, per side, base64", context do
      v2(context)

      sandbox([
        {&(runs?(&1, "npx") and "--yes" in elem(&1, 1)),
         fn call ->
           {:ok, %{status: 0, output: "installed " <> if(side?(call, "red"), do: "r", else: "g")}}
         end},
        {&(runs?(&1, "npx") and "tsc" in elem(&1, 1)), {:ok, %{status: 0, output: "compiled"}}}
      ])

      run(context)

      assert body()["build_evidence"] == %{
               "red" => %{
                 "install" => [Base.encode64("installed r")],
                 "prepare" => [Base.encode64("compiled"), ""]
               },
               "green" => %{
                 "install" => [Base.encode64("installed g")],
                 "prepare" => [Base.encode64("compiled"), ""]
               }
             }
    end

    test "records a step over 256 KiB, or past 1 MiB in all, as truncated", context do
      big = String.duplicate("x", 256 * 1024 + 1)
      fits = String.duplicate("y", 256 * 1024)
      install = for i <- 1..6, do: ["npx", "--yes", "step#{i}"]
      v2(context, %{"verify-plan" => {200, plan_v2(%{"install" => install})}})

      sandbox([
        {&(runs?(&1, "npx") and "step1" in elem(&1, 1)), {:ok, %{status: 0, output: big}}},
        {&(runs?(&1, "npx") and "--yes" in elem(&1, 1)), {:ok, %{status: 0, output: fits}}}
      ])

      run(context)

      truncated = %{"truncated" => true}
      fit = Base.encode64(fits)
      # step1 is over its own cap; steps 2-5 make 1 MiB; step 6 would pass it.
      assert body()["build_evidence"]["red"]["install"] == [
               truncated,
               fit,
               fit,
               fit,
               fit,
               truncated
             ]
    end

    test "is captured before TEST runs, so nothing TEST does changes it", context do
      v2(context)
      rsolv = Path.join(context.tmp_dir, "rsolv")

      sandbox([
        {&(runs?(&1, "npx") and "--yes" in elem(&1, 1)), {:ok, %{status: 0, output: "built"}}},
        {&(runs?(&1, "npx") and "jest" in elem(&1, 1)),
         fn call ->
           {container, _env, _argv} = exec_call(call)
           File.write!(Path.join([rsolv, container, "evidence"]), "forged")
           File.write!(Path.join([rsolv, container <> "-home", "evidence"]), "forged")
           {:ok, %{status: if(side?(call, "red"), do: 1, else: 0), output: ""}}
         end}
      ])

      run(context)

      evidence = body()["build_evidence"]
      assert evidence["red"]["install"] == [Base.encode64("built")]
      assert evidence["green"]["install"] == [Base.encode64("built")]
    end
  end
end
