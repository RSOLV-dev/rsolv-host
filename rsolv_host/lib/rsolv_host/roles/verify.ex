defmodule RsolvHost.Roles.Verify do
  @moduledoc """
  The `verify` role (RFC-150 §5): proves RED→GREEN for one issue on a fresh
  checkout of `base_sha`, with the plan the platform built.

  Every platform read, host read and copy happens before the first sandbox
  starts:
  1. the touched paths;
  2. base facts for them, read from git objects in the untouched checkout
     (`RsolvHost.BaseFactsReader`), and the platform's policy verdict;
  3. the plan, run only once `RsolvCore.VerifyPlan.decode/1` accepts it and
     it names the change set policy accepted, and the post-images, checked
     against its change set (`RsolvHost.PostImages`);
  4. the RED copy (base plus the RED snapshot) and the GREEN copy (base plus
     the change set), under `$RUNNER_TEMP/rsolv`, written no-follow
     (`RsolvHost.Copies`).

  Then RED and GREEN each run in a fresh sandbox: bootstrap and `install`
  behind the proxy, disconnect, then `prepare`, `test` and the report
  offline. The host never builds a command, and never runs git or opens a
  path in a tree a sandbox has mounted.

  The verdicts are outcomes (exit 0): `verified`, `verify_failed` and
  `rejected` (by policy, or for want of a plan). A step past its time limit,
  or a sandbox that fails, is reported as a verify error, which a new
  attempt may retry; the role then exits 4.
  """

  alias RsolvCore.{BaseFacts, VerifyPlan}

  alias RsolvHost.{
    ActionsLog,
    BaseFactsReader,
    Copies,
    Outcome,
    Platform,
    PostImages,
    Relay,
    Runtimes,
    Sandbox,
    TokenKeeper,
    Workspace
  }

  @bootstrap_timeout_ms 900_000
  @bootstrap_max_bytes 1024 * 1024
  @prepare_timeout_ms 300_000
  @report_timeout_ms 60_000
  # ponytail: a step whose output passes its cap is killed (8 MiB of install
  # log, 16 MiB of test output). Raise with evidence.
  @step_max_bytes 8 * 1024 * 1024
  @test_max_bytes 16 * 1024 * 1024
  # Rsolv.Runners.VerifyReport's cap: a bigger report is refused there, so it goes up empty.
  @report_max_bytes 4 * 1024 * 1024
  @log_tail_bytes 64 * 1024
  # `timeout`'s status when it stopped a step: TERM, then KILL.
  @timeout_statuses [124, 137]
  @bound ~w(change_set_digest red_digest policy_version)
  @rejections ["issue_rejected", "not_eligible"]

  @doc "Runs the role. `deps`: `:io`, `:probe` and `:stat` (passed to `RsolvHost.Sandbox.start/1`)."
  @spec run(map(), map(), keyword()) :: Outcome.result()
  def run(%{issue: issue}, env, deps \\ []) do
    io = Keyword.get(deps, :io, :stdio)

    with {:ok, run_id} <- env_value(env, "GITHUB_RUN_ID", ~r/\A[0-9]{1,20}\z/),
         {:ok, workspace} <- env_value(env, "GITHUB_WORKSPACE", ~r/\A\//),
         {:ok, root} <- copies_root(env, workspace),
         {:ok, keeper} <- TokenKeeper.start(role: :verify, issue: issue, env: env, io: io) do
      ctx = %{
        issue: issue,
        env: env,
        io: io,
        deps: deps,
        keeper: keeper,
        workspace: workspace,
        root: root,
        names: "rsolv-#{run_id}-#{issue}-verify"
      }

      try do
        verify(ctx)
      after
        TokenKeeper.stop(keeper)
      end
    end
  end

  defp env_value(env, name, format) do
    case env[name] do
      value when is_binary(value) ->
        if value =~ format, do: {:ok, value}, else: {:error, {:missing_env, name}}

      nil ->
        {:error, {:missing_env, name}}
    end
  end

  # The copies must never land in the checkout base facts come from.
  defp copies_root(env, workspace) do
    with {:ok, temp} <- env_value(env, "RUNNER_TEMP", ~r/\A\//) do
      root = Path.expand(Path.join(temp, "rsolv"))
      workspace = Path.expand(workspace)

      if root == workspace or String.starts_with?(root, workspace <> "/"),
        do: {:error, {:missing_env, "RUNNER_TEMP"}},
        else: {:ok, root}
    end
  end

  defp verify(ctx) do
    with {:ok, ctx} <- bound(ctx),
         {:ok, paths} <- touched_paths(ctx),
         {:ok, facts} <- BaseFactsReader.read(ctx.workspace, ctx.base, paths),
         {:ok, verdict} <- call(ctx, :base_facts, [BaseFacts.to_json(facts)]),
         :ok <- accepted(verdict),
         {:ok, plan} <- plan(ctx, verdict),
         {:ok, %{"files" => files}} <- call(ctx, :post_images, []),
         {:ok, images} <- PostImages.checked(files, plan.change_set),
         {:ok, dirs} <- copies(ctx, plan, images) do
      prove(ctx, plan, dirs)
    else
      {:outcome, _outcome, _has_patch} = rejected -> rejected
      {:error, {:platform, 409, code}} when code in @rejections -> {:outcome, :rejected, false}
      {:ok, _malformed} -> {:error, :malformed_response}
      error -> error
    end
  end

  defp bound(ctx) do
    case TokenKeeper.token(ctx.keeper) do
      {:ok, %{binding: %{"pipeline_run_id" => run, "base_sha" => base}}} ->
        {:ok, Map.merge(ctx, %{run: run, base: base})}

      {:ok, _unbound} ->
        {:error, :run_unbound}

      error ->
        error
    end
  end

  defp call(ctx, fun, args) do
    with {:ok, %{req: req, raw: raw}} <- TokenKeeper.token(ctx.keeper),
         do: apply(Platform, fun, [req, raw, ctx.run, ctx.issue | args])
  end

  defp touched_paths(ctx) do
    case call(ctx, :touched_paths, []) do
      {:ok, %{"paths" => paths}} when is_list(paths) -> {:ok, paths}
      {:ok, _malformed} -> {:error, :malformed_response}
      error -> error
    end
  end

  defp accepted(%{"status" => "accepted"}), do: :ok
  defp accepted(%{"status" => "rejected"}), do: {:outcome, :rejected, false}
  defp accepted(_malformed), do: {:error, :malformed_response}

  defp plan(ctx, verdict) do
    with {:ok, json} <- call(ctx, :verify_plan, []),
         {:ok, plan} <- VerifyPlan.decode(json) do
      if Map.take(json, @bound) == Map.take(verdict, @bound),
        do: {:ok, plan},
        else: {:error, :invalid_plan}
    end
  end

  defp copies(ctx, plan, images) do
    {:ok, red} = VerifyPlan.red(plan.change_set, plan.red_paths)
    dirs = %{red: Path.join(ctx.root, "verify-red"), green: Path.join(ctx.root, "verify-green")}

    with :ok <- Workspace.copy(ctx.workspace, dirs.red),
         :ok <- Workspace.copy(ctx.workspace, dirs.green),
         :ok <- Copies.write_images(dirs.red, red, images),
         :ok <- Copies.write_images(dirs.green, plan.change_set, images),
         do: {:ok, dirs}
  end

  defp prove(ctx, plan, dirs) do
    with {:ok, red} <- side(ctx, plan, dirs.red, "red"),
         {:ok, green} <- side(ctx, plan, dirs.green, "green") do
      report(ctx, plan, %{"red" => red, "green" => green}, :verify_error)
    else
      {:verify_error, kind, reason} -> report(ctx, plan, %{"error" => kind}, reason)
    end
  end

  defp side(ctx, plan, dir, side) do
    name = "#{ctx.names}-#{side}"

    [name: name, network: name <> "-net", copy_dir: dir, runner_temp: ctx.env["RUNNER_TEMP"]]
    |> Keyword.merge(Keyword.take(ctx.deps, [:probe, :stat]))
    |> Sandbox.start()
    |> case do
      {:ok, sbx} ->
        try do
          steps(ctx, sbx, plan, side)
        after
          Sandbox.stop(sbx)
        end

      {:error, reason} ->
        {:verify_error, "sandbox", reason}
    end
  end

  defp steps(ctx, sbx, plan, side) do
    with :ok <- bootstrap(ctx, sbx),
         :ok <- run_steps(ctx, sbx, plan.install, plan.install_timeout_s * 1_000, side),
         :ok <- offline(sbx),
         :ok <- run_steps(ctx, sbx, plan.prepare, @prepare_timeout_ms, side),
         {:ok, status, output} <- test(ctx, sbx, plan) do
      report = sbx |> report_bytes(plan, output) |> Base.encode64()
      {:ok, %{"exit_code" => status, "timed_out" => false, "report" => report}}
    end
  end

  # Bootstrap sets up the sandbox's own toolchains, so its failure is the
  # sandbox's (retryable), never the project's install failing under the fix.
  defp bootstrap(ctx, sbx) do
    with {:ok, %{status: 0, output: output}} <-
           Sandbox.exec(sbx, ["rsolv-sandbox", "bootstrap"],
             input: Sandbox.bootstrap_input(ctx.env["RSOLV_EXACT_RUNTIME_VERSIONS"]),
             timeout_ms: @bootstrap_timeout_ms,
             max_bytes: @bootstrap_max_bytes
           ),
         %{"ok" => true, "log_tail" => tail} = result when is_binary(tail) <-
           Relay.last_object(output) do
      ActionsLog.untrusted(tail, ctx.io)
      Runtimes.annotate(result["runtimes"], ctx.io)
    else
      _failed -> {:verify_error, "sandbox", {:sandbox, :bootstrap}}
    end
  end

  # One deadline for all of a stage's steps.
  defp run_steps(ctx, sbx, argvs, budget_ms, side) do
    deadline = now() + budget_ms

    Enum.reduce_while(argvs, :ok, fn argv, :ok ->
      case timed(sbx, argv, deadline, @step_max_bytes) do
        {:ok, 0, output} -> {:cont, log(ctx, output)}
        {:ok, _status, output} -> {:halt, install_failed(log(ctx, output), side)}
        {:error, :output_too_large} -> {:halt, install_failed(:ok, side)}
        {:error, :timeout} -> {:halt, {:verify_error, "timeout", :verify_error}}
        {:error, reason} -> {:halt, {:verify_error, "sandbox", {:sandbox, reason}}}
      end
    end)
  end

  defp install_failed(:ok, side), do: {:verify_error, "install_failed_" <> side, :verify_error}

  defp offline(sbx) do
    case Sandbox.disconnect(sbx) do
      :ok -> :ok
      {:error, reason} -> {:verify_error, "sandbox", reason}
    end
  end

  defp test(ctx, sbx, plan) do
    case timed(sbx, plan.test, now() + plan.test_timeout_s * 1_000, @test_max_bytes) do
      {:ok, status, output} ->
        log(ctx, output)
        {:ok, status, output}

      {:error, :timeout} ->
        {:verify_error, "timeout", :verify_error}

      {:error, reason} ->
        {:verify_error, "sandbox", {:sandbox, reason}}
    end
  end

  # Runs `argv` with what's left before `deadline`, in whole seconds (the
  # sandbox's `timeout` takes seconds). A step stopped by `timeout` once its
  # time was up is `{:error, :timeout}`; the same status any earlier is the
  # step's own.
  defp timed(sbx, argv, deadline, max_bytes) do
    start = now()
    limit_ms = div(deadline - start, 1_000) * 1_000

    if limit_ms < 1_000 do
      {:error, :timeout}
    else
      result = Sandbox.exec(sbx, argv, timeout_ms: limit_ms, max_bytes: max_bytes)
      timed_out(result, now() - start >= limit_ms)
    end
  end

  defp timed_out({:ok, %{status: status}}, true) when status in @timeout_statuses,
    do: {:error, :timeout}

  defp timed_out({:ok, %{status: status, output: output}}, _late), do: {:ok, status, output}
  defp timed_out(error, _late), do: error

  defp report_bytes(_sbx, %{report: %{argv: nil}}, output)
       when byte_size(output) <= @report_max_bytes,
       do: output

  defp report_bytes(_sbx, %{report: %{argv: nil}}, _output), do: ""

  defp report_bytes(sbx, %{report: %{argv: argv}}, _output) do
    case Sandbox.exec(sbx, argv, timeout_ms: @report_timeout_ms, max_bytes: @report_max_bytes) do
      {:ok, %{status: 0, output: bytes}} -> bytes
      _missing_or_too_large -> ""
    end
  end

  defp log(ctx, output) when byte_size(output) > @log_tail_bytes,
    do: log(ctx, binary_part(output, byte_size(output) - @log_tail_bytes, @log_tail_bytes))

  defp log(ctx, output), do: ActionsLog.untrusted(output, ctx.io)

  defp report(ctx, plan, body, reason) do
    body =
      Map.merge(body, %{
        "change_set_digest" => plan.change_set_digest,
        "red_digest" => plan.red_digest,
        "policy_version" => plan.policy_version
      })

    case call(ctx, :verification, [body]) do
      {:ok, %{"verification" => "green"}} -> {:outcome, :verified, false}
      {:ok, %{"verification" => "failed"}} -> {:outcome, :verify_failed, false}
      {:ok, %{"verification" => "verify_error"}} -> {:error, reason}
      {:ok, _malformed} -> {:error, :malformed_response}
      error -> error
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
