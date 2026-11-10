defmodule RsolvHost.Roles.WorkTest do
  use ExUnit.Case, async: true

  import RsolvHost.PlatformStub

  alias RsolvHost.{FakeExec, Frame, Oidc, Platform, TokenKeeper}
  alias RsolvHost.Roles.Work

  @moduletag :tmp_dir
  @run "0b0e5f7c-7d3c-4d8e-9a55-3f6f1b0c2a11"
  @base String.duplicate("b", 40)
  @patch "diff --git a/a.rb b/a.rb\n"
  @red_patch "diff --git a/test/a_test.rb b/test/a_test.rb\n"
  @validated %{"validated" => true, "classification" => "validated"}

  setup %{tmp_dir: dir} do
    workspace = Path.join(dir, "checkout")
    File.mkdir_p!(workspace)
    {:ok, io} = StringIO.open("")
    Req.Test.stub(Oidc, &Req.Test.json(&1, %{value: "e30.e30.sig"}))

    env = %{
      "RUNNER_TEMP" => dir,
      "GITHUB_WORKSPACE" => workspace,
      "GITHUB_RUN_ID" => "41",
      "ACTIONS_ID_TOKEN_REQUEST_URL" => "https://token.actions.example/id?v=1",
      "ACTIONS_ID_TOKEN_REQUEST_TOKEN" => "t"
    }

    %{env: env, io: io, workspace: workspace}
  end

  # The platform: validation and mitigation each complete with the given data
  # (or an SSE body), and the upload answers with `upload`.
  defp platform(opts \\ []) do
    test = self()
    validation = Keyword.get(opts, :validation, @validated)
    mitigation = Keyword.get(opts, :mitigation, %{"success" => true})
    upload = Keyword.get(opts, :upload, {201, %{patch_bytes: 1}})

    Req.Test.stub(Platform, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/api/v1/runs/token"} ->
          Process.sleep(Keyword.get(opts, :exchange_ms, 0))
          Req.Test.json(conn, token())

        {"POST", "/api/v1/runs/token/refresh"} ->
          send(test, :refreshed)
          Req.Test.json(conn, token("rsolv_rt_resumedAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))

        {"POST", "/api/v1/" <> phase_start} ->
          handle_post(conn, phase_start, upload, test)

        {"GET", "/api/v1/validation/stream/sv"} ->
          stream(conn, events(validation))

        {"GET", "/api/v1/mitigation/stream/sm"} ->
          stream(conn, events(mitigation))
      end
    end)
  end

  defp handle_post(conn, "validation/start", _upload, test) do
    {body, conn} = body(conn)
    send(test, {:started, :validation, body})
    Req.Test.json(conn, %{session_id: "sv", stream_url: "/api/v1/validation/stream/sv"})
  end

  defp handle_post(conn, "mitigation/start", _upload, test) do
    {body, conn} = body(conn)
    send(test, {:started, :mitigation, body})
    Req.Test.json(conn, %{session_id: "sm", stream_url: "/api/v1/mitigation/stream/sm"})
  end

  defp handle_post(conn, "runs/" <> _results, {status, json}, test) do
    {body, conn} = body(conn)
    send(test, {:uploaded, conn.request_path, body})
    conn |> Plug.Conn.put_status(status) |> Req.Test.json(json)
  end

  defp events(body) when is_binary(body), do: body
  defp events(data), do: sse([{:complete, data}])

  # The sandbox: docker answers, with the bootstrap and patch results given.
  # The first `rsolv-sandbox patch` is the red patch (VALIDATE has ended), and
  # every later one the final patch.
  defp sandbox(opts \\ []) do
    final = Keyword.get(opts, :patch, patch_output(@patch))
    red = Keyword.get(opts, :red_patch, patch_output(@red_patch))
    patches = :counters.new(1, [])

    patch = fn call ->
      :counters.add(patches, 1, 1)
      answer(if(:counters.get(patches, 1) == 1, do: red, else: final), call)
    end

    FakeExec.script([
      {fn {"docker", ["inspect", "-f", t, _], _} -> t =~ "bridge" end,
       {:ok, %{status: 0, output: "172.17.0.5"}}},
      {fn {"docker", ["inspect" | _], _} -> true end, {:ok, %{status: 0, output: "172.18.0.2"}}},
      {fn {"docker", ["exec" | args], _} -> List.last(args) == "bootstrap" end,
       Keyword.get(
         opts,
         :bootstrap,
         {:ok,
          %{status: 0, output: ~s({"ok":true,"ecosystems":["ruby"],"log_tail":"::add-mask::x"})}}
       )},
      {fn {"docker", ["exec" | args], _} -> List.last(args) == "patch" end, patch}
    ])
  end

  defp answer(answer, call) when is_function(answer, 1), do: answer.(call)
  defp answer(answer, _call), do: answer

  defp patch_output(bytes),
    do: {:ok, %{status: 0, output: ~s({"patch":"#{Base.encode64(bytes)}"})}}

  defp deps(context, extra \\ []) do
    [io: context.io, probe: fn _ip -> :ok end, stat: &stat/1, backoff_ms: []] ++ extra
  end

  # Records each stat in FakeExec's log, so its order against process calls shows.
  defp stat(path) do
    FakeExec.run("fs.stat", [path], [])
    File.stat!(path)
  end

  defp io_text(io), do: io |> StringIO.contents() |> elem(1)

  defp docker_runs, do: for({"docker", ["run" | _] = args, _} <- FakeExec.calls(), do: args)

  describe "run/3" do
    test "goes from OIDC to the uploaded patch, in order", context do
      platform()
      sandbox()

      assert Work.run(%{issue: 7}, context.env, deps(context)) == {:outcome, :mitigated, true}

      copy = Path.join([context.tmp_dir, "rsolv", "work"])
      calls = FakeExec.calls()

      assert [{"cp", ["-a", "--", src, ^copy], _} | _] = calls
      assert src == context.workspace <> "/."

      assert ["run", "-d", "--name", "rsolv-41-7-work-proxy" | _] = hd(docker_runs())

      assert ["run", "-d", "--name", "rsolv-41-7-work", "--network", "rsolv-41-7-net" | _] =
               List.last(docker_runs())

      assert_received {:started, :validation, %{"pipeline_run_id" => @run, "issue_number" => 7}}
      assert_received {:started, :mitigation, %{"pipeline_run_id" => @run, "issue_number" => 7}}

      assert {_, _, bootstrap_opts} = Enum.find(calls, &match?({"docker", ["exec" | _], _}, &1))
      assert bootstrap_opts[:input] == "0\n"

      assert {_, _, patch_opts} =
               Enum.find(calls, fn {_, args, _} -> List.last(args) == "patch" end)

      assert patch_opts[:input] == Frame.encode(%{"base_sha" => @base})

      assert_received {:uploaded, "/api/v1/runs/" <> @run <> "/issues/7/results",
                       %{"patch" => patch}}

      assert Base.decode64!(patch) == @patch

      assert {"docker", ["network", "rm", net], _} = List.last(calls)
      assert net == FakeExec.docker_id("rsolv-41-7-net")
    end

    test "prints the bootstrap log only as untrusted text", context do
      platform()
      sandbox()

      Work.run(%{issue: 7}, context.env, deps(context))

      assert io_text(context.io) =~ ~r/::stop-commands::([0-9a-f]{32})\n::add-mask::x\n::\1::\n/
    end

    test "asks bootstrap for exact runtime versions when the job requires them", context do
      platform()
      sandbox()
      env = Map.put(context.env, "RSOLV_EXACT_RUNTIME_VERSIONS", "true")

      Work.run(%{issue: 7}, env, deps(context))

      assert {_, _, opts} = Enum.find(FakeExec.calls(), &match?({"docker", ["exec" | _], _}, &1))
      assert opts[:input] == Frame.encode(%{"exact_runtime_versions" => true})
    end

    test "requires exactly \"true\" for exact runtime versions", context do
      platform()
      sandbox()
      env = Map.put(context.env, "RSOLV_EXACT_RUNTIME_VERSIONS", "1")

      Work.run(%{issue: 7}, env, deps(context))

      assert {_, _, opts} = Enum.find(FakeExec.calls(), &match?({"docker", ["exec" | _], _}, &1))
      assert opts[:input] == "0\n"
    end

    test "annotates the runtime installs bootstrap reports", context do
      platform()

      result = %{
        "ok" => true,
        "ecosystems" => ["python"],
        "log_tail" => "",
        "runtimes" => [
          %{
            "runtime" => "python",
            "requested" => "3.11.9",
            "actual" => "3.11.11",
            "status" => "fallback"
          }
        ]
      }

      sandbox(bootstrap: {:ok, %{status: 0, output: JSON.encode!(result)}})

      Work.run(%{issue: 7}, context.env, deps(context))

      assert io_text(context.io) =~
               "::warning title=RSOLV runtime::Python 3.11.9 has no published build attestations, so 3.11.11"
    end

    test "never touches the mounted tree once the sandbox starts (acceptance 5a)", context do
      platform()
      sandbox()

      Work.run(%{issue: 7}, context.env, deps(context))

      calls = FakeExec.calls()

      assert calls |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort() == [
               "cp",
               "docker",
               "fs.stat"
             ]

      sandbox_run =
        Enum.find_index(
          calls,
          &match?({"docker", ["run", "-d", "--name", "rsolv-41-7-work", "--network" | _], _}, &1)
        )

      copy = Path.join([context.tmp_dir, "rsolv", "work"])

      touched_after =
        for {exe, args, _} <- Enum.drop(calls, sandbox_run),
            exe in ["cp", "fs.stat"] or Enum.any?(args, &String.starts_with?(&1, copy <> "/")),
            do: {exe, args}

      assert touched_after == []
    end
  end

  describe "run/3 outcomes" do
    test "a false positive is reported without mitigating or uploading", context do
      platform(
        validation: %{
          "validated" => false,
          "classification" => "false_positive_counter_indicator"
        }
      )

      sandbox()

      assert Work.run(%{issue: 7}, context.env, deps(context)) ==
               {:outcome, :false_positive, false}

      refute_received {:started, :mitigation, _}
      refute_received {:uploaded, _, _}
    end

    test "a cached false positive is reported the same way", context do
      Req.Test.stub(Platform, fn conn ->
        case conn.request_path do
          "/api/v1/runs/token" ->
            Req.Test.json(conn, token())

          "/api/v1/validation/start" ->
            Req.Test.json(conn, %{cached: true, result: %{is_false_positive: true}})
        end
      end)

      sandbox()

      assert Work.run(%{issue: 7}, context.env, deps(context)) ==
               {:outcome, :false_positive, false}
    end

    test "an unconfirmed vulnerability is not_validated", context do
      platform(validation: %{"validated" => false, "classification" => "inconclusive"})
      sandbox()

      assert Work.run(%{issue: 7}, context.env, deps(context)) ==
               {:outcome, :not_validated, false}
    end

    test "a failed mitigation, max_turns included, uploads nothing", context do
      platform(mitigation: %{"success" => false, "error" => "max_turns"})
      sandbox()

      assert Work.run(%{issue: 7}, context.env, deps(context)) ==
               {:outcome, :mitigation_failed, false}

      refute_received {:uploaded, _, _}
    end

    test "an empty diff is a failed mitigation", context do
      platform()
      sandbox(patch: {:ok, %{status: 0, output: ~s({"patch":""})}})

      assert Work.run(%{issue: 7}, context.env, deps(context)) ==
               {:outcome, :mitigation_failed, false}

      refute_received {:uploaded, _, _}
    end

    test "uploads the red patch taken when VALIDATE ended, beside the final patch", context do
      platform()
      sandbox()

      assert Work.run(%{issue: 7}, context.env, deps(context)) == {:outcome, :mitigated, true}

      assert_received {:uploaded, _path, %{"patch" => patch, "red_patch" => red_patch}}
      assert Base.decode64!(patch) == @patch
      assert Base.decode64!(red_patch) == @red_patch
    end

    test "takes the red patch before MITIGATE starts", context do
      platform()
      sandbox()

      Work.run(%{issue: 7}, context.env, deps(context))

      assert_received {:started, :mitigation, _body}

      patches =
        for {"docker", ["exec" | args], _} <- FakeExec.calls(),
            List.last(args) == "patch",
            do: args

      assert length(patches) == 2
    end

    test "a red patch over 512 KiB is a failed mitigation, with a warning, and MITIGATE never starts",
         context do
      platform()
      sandbox(red_patch: patch_output(:binary.copy("x", 512 * 1024 + 1)))

      assert Work.run(%{issue: 7}, context.env, deps(context)) ==
               {:outcome, :mitigation_failed, false}

      refute_received {:started, :mitigation, _body}
      refute_received {:uploaded, _, _}

      assert io_text(context.io) =~
               "::warning title=RSOLV::The failing test was larger than 512 KiB and was not uploaded.\n"
    end

    test "a red patch the sandbox can't produce records validated and exits 4", context do
      platform()
      sandbox(red_patch: {:ok, %{status: 1, output: "boom"}})

      result = Work.run(%{issue: 7}, context.env, deps(context))

      assert result == {:error, :malformed_patch, :validated}
      assert RsolvHost.Outcome.exit_code(result) == 4
      refute_received {:started, :mitigation, _body}
    end

    test "a diff over 5 MiB is a failed mitigation, with a warning", context do
      platform()
      big = Base.encode64(:binary.copy("a", 5 * 1024 * 1024 + 1))
      sandbox(patch: {:ok, %{status: 0, output: ~s({"patch":"#{big}"})}})

      assert Work.run(%{issue: 7}, context.env, deps(context)) ==
               {:outcome, :mitigation_failed, false}

      refute_received {:uploaded, _, _}

      assert io_text(context.io) =~
               "::warning title=RSOLV::The fix was larger than 5 MiB and was not uploaded.\n"
    end
  end

  describe "run/3 failures" do
    test "a session error is transient", context do
      platform(validation: sse([{:error, %{"error" => "boom"}}]))
      sandbox()

      assert {:error, {:session, _}} = Work.run(%{issue: 7}, context.env, deps(context))
    end

    for {status, code} <- [{503, 3}, {422, 2}] do
      test "once VALIDATE confirmed, an upload answered #{status} records validated and exits #{code}",
           context do
        platform(upload: {unquote(status), %{error: "x"}})
        sandbox()

        result = Work.run(%{issue: 7}, context.env, deps(context))

        assert {:error, {:platform, unquote(status), _}, :validated} = result
        assert RsolvHost.Outcome.exit_code(result) == unquote(code)
      end
    end

    test "once VALIDATE confirmed, a failed MITIGATE session records validated", context do
      platform(mitigation: sse([{:error, %{"error" => "boom"}}]))
      sandbox()

      assert {:error, {:session, _}, :validated} =
               Work.run(%{issue: 7}, context.env, deps(context))

      refute_received {:uploaded, _, _}
    end

    test "the sandbox is removed even when the role crashes", context do
      platform()
      sandbox(bootstrap: fn _call -> raise "boom" end)

      assert_raise RuntimeError, fn -> Work.run(%{issue: 7}, context.env, deps(context)) end
      assert {"docker", ["network", "rm", net], _} = List.last(FakeExec.calls())
      assert net == FakeExec.docker_id("rsolv-41-7-net")
    end
  end

  describe "run/3 with --resume" do
    test "refreshes the first token, and reuses nothing from the first attempt", context do
      path = TokenKeeper.handoff_path(context.env, :work, 7)
      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        JSON.encode!(%{
          raw: "rsolv_rt_firstAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
          expires_at: "2026-11-06T12:00:00Z",
          binding: %{}
        })
      )

      platform(upload: {409, %{error: "already_uploaded"}})
      sandbox()

      assert Work.run(%{issue: 7, resume: true}, context.env, deps(context)) ==
               {:outcome, :mitigated, true}

      assert_received :refreshed

      copy = Path.join([context.tmp_dir, "rsolv", "work-2"])
      assert [{"cp", ["-a", "--", _, ^copy], _} | _] = FakeExec.calls()

      assert ["run", "-d", "--name", "rsolv-41-7-work-2", "--network", "rsolv-41-7-net-2" | _] =
               List.last(docker_runs())
    end
  end

  describe "run/3 and its time budget" do
    # rsolv-work.yml runs the role, waits 30 s and runs it once more with
    # --resume, all inside `timeout-minutes: 120`. The module's comment holds
    # the table: the role ends at most 8 minutes past its budget.
    test "fits both attempts, and the wait between them, in the job's 120 minutes" do
      source = File.read!(Path.expand("../../../lib/rsolv_host/roles/work.ex", __DIR__))
      [_, minutes] = Regex.run(~r/@budget_ms (\d+) \* 60 \* 1_000/, source)
      attempt = String.to_integer(minutes) + 8

      assert 10 + attempt + 0.5 + attempt + 10 <= 120
    end

    test "counts the token exchange in the budget", context do
      platform(exchange_ms: 400)
      sandbox()

      result = Work.run(%{issue: 7}, context.env, deps(context, budget_ms: 300))

      assert result == {:error, :session_timeout}
      refute_received {:started, :validation, _}
    end

    test "clamps every sandbox setup step and bootstrap to the budget", context do
      platform()
      sandbox()

      Work.run(%{issue: 7}, context.env, deps(context, budget_ms: 60_000))

      assert for({"docker", ["run" | _], opts} <- FakeExec.calls(), do: opts[:timeout_ms])
             |> Enum.all?(&(&1 <= 60_000))

      assert {"docker",
              ["exec", "-i", _, "timeout", "-k", _, seconds, "rsolv-sandbox", "bootstrap"], _} =
               Enum.find(FakeExec.calls(), &match?({"docker", ["exec" | _], _}, &1))

      assert String.to_integer(seconds) <= 60
    end

    test "a patch ready after the role's deadline isn't uploaded", context do
      platform()

      sandbox(
        patch: fn _call ->
          Process.sleep(400)
          {:ok, %{status: 0, output: ~s({"patch":"#{Base.encode64(@patch)}"})}}
        end
      )

      result = Work.run(%{issue: 7}, context.env, deps(context, budget_ms: 300))

      assert result == {:error, :session_timeout, :validated}
      refute_received {:uploaded, _, _}
    end
  end
end
