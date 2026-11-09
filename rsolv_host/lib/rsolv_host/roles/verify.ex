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
     the change set), under `$RUNNER_TEMP/rsolv`, named by the run attempt
     and written no-follow (`RsolvHost.Copies`).

  Then RED and GREEN each run in a fresh sandbox: bootstrap and `install`
  behind the proxy, disconnect, then `prepare`, `test` and the report
  offline. The host never builds a command, and never runs git or opens a
  path in a tree a sandbox has mounted; it removes a copy only once Docker
  has removed its sandbox.

  The verdicts are outcomes (exit 0): `verified`, `verify_failed` and
  `rejected` (by policy, or for want of a plan). What the code under test
  decides is never a verify error: a test past its time limit or its output
  cap is that side's result (`timed_out`, or an empty report), and an install
  or prepare step that fails, times out or floods its output is the side's
  install failure. A test that timed out is the platform's verify error,
  which the role ends as `verify_timed_out` (exit 2): running it again would
  time out again. Only the sandbox failing (Docker, the image, bootstrap) is
  reported as a verify error, which a new attempt may retry (exit 4).
  """

  alias RsolvCore.{BaseFacts, VerifyPlan}

  alias RsolvHost.{
    ActionsLog,
    BaseFactsReader,
    Copies,
    Http,
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
  # A test the host killed for its output: KILL's status.
  @killed_status 137
  # The role's time (RFC-150 §5), under `rsolv-verify.yml`'s
  # `timeout-minutes: 120`, in minutes:
  #
  #     job setup before the role (checkout, host download and check)  10
  #   + the role's budget: every platform request ends by it           100
  #   + margin                                                          10
  #   = 120
  #
  # Before any sandbox, nothing needs clamping: the token exchange and four
  # platform calls (each at most 4 attempts of 30 s connect and 120 s
  # receive, and 3 waits of at most 60 s: 13), the base-facts read (5) and
  # two copies (10 each) take at most 90, before the sandboxes' deadline at
  # 95 (`@reserve_ms` before the budget). RED gets half of what's left when
  # it starts and GREEN the rest, and every sandbox stage's own limit
  # (setup and image pulls, bootstrap 15, install up to 60, prepare 5, test
  # up to 60, report 1) is clamped to its side's deadline: unclamped, one
  # side could take 170. Past a deadline a step ends within timeout's 10 s
  # KILL grace and the host's 30 s, a report within 41 s more, and removing
  # the sandbox takes at most 2 minutes: 3.5, inside the 5-minute reserve
  # before the verification is posted.
  @budget_ms 100 * 60 * 1_000
  @reserve_ms 5 * 60 * 1_000
  # owner/name, as GitHub allows them: label values never carry more.
  @repository ~r/\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}\/[A-Za-z0-9_.][A-Za-z0-9_.-]{0,99}\z/
  @bound ~w(change_set_digest red_digest policy_version)
  @rejections ["issue_rejected", "not_eligible"]

  @doc """
  Runs the role. `deps`: `:io`, `:probe` and `:stat` (passed to
  `RsolvHost.Sandbox.start/1`), and `:budget_ms`, the role's deadline: every
  platform request, retries and their waits included, ends by it
  (`RsolvHost.Http.deadline/3`), or the role ends `session_timeout`.
  """
  @spec run(map(), map(), keyword()) :: Outcome.result()
  def run(%{issue: issue}, env, deps \\ []) do
    io = Keyword.get(deps, :io, :stdio)

    with {:ok, run_id} <- env_value(env, "GITHUB_RUN_ID", ~r/\A[0-9]{1,20}\z/),
         {:ok, attempt} <- env_value(env, "GITHUB_RUN_ATTEMPT", ~r/\A[0-9]{1,5}\z/),
         {:ok, repository} <- env_value(env, "GITHUB_REPOSITORY", @repository),
         {:ok, workspace} <- env_value(env, "GITHUB_WORKSPACE", ~r/\A\//),
         {:ok, root} <- copies_root(env, workspace),
         deadline = now() + Keyword.get(deps, :budget_ms, @budget_ms),
         {:ok, keeper} <- TokenKeeper.start(role: :verify, issue: issue, env: env, io: io) do
      ctx = %{
        issue: issue,
        env: env,
        io: io,
        deps: deps,
        keeper: keeper,
        workspace: workspace,
        root: root,
        deadline: deadline,
        stages: deadline - @reserve_ms,
        labels: %{
          "rsolv.repo" => repository,
          "rsolv.run" => run_id,
          "rsolv.issue" => Integer.to_string(issue),
          "rsolv.attempt" => attempt
        },
        names: "rsolv-#{run_id}-#{attempt}-#{issue}-verify"
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
      {:error, :digest_mismatch} -> {:error, :invalid_plan}
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
    with {:ok, %{req: req, raw: raw}} <- TokenKeeper.token(ctx.keeper) do
      req = Http.deadline(req, ctx.deadline, :session_timeout)
      apply(Platform, fun, [req, raw, ctx.run, ctx.issue | args])
    end
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

    dirs = %{
      red: Path.join(ctx.root, ctx.names <> "-red"),
      green: Path.join(ctx.root, ctx.names <> "-green")
    }

    with :ok <- Workspace.copy(ctx.workspace, dirs.red),
         :ok <- Workspace.copy(ctx.workspace, dirs.green),
         :ok <- Copies.write_images(dirs.red, red, images),
         :ok <- Copies.write_images(dirs.green, plan.change_set, images),
         do: {:ok, dirs}
  end

  defp prove(ctx, plan, dirs) do
    Sandbox.remove_stale(ctx.labels)
    trap = Sandbox.trap_sigterm()

    try do
      ctx |> Map.put(:created, created(trap)) |> sides(plan, dirs)
    after
      Sandbox.untrap_sigterm(trap)
    end
  end

  defp sides(ctx, plan, dirs) do
    red_deadline = now() + div(ctx.stages - now(), 2)

    with {:ok, red} <- side(ctx, plan, dirs.red, "red", red_deadline),
         {:ok, green} <- side(ctx, plan, dirs.green, "green", ctx.stages) do
      report(ctx, plan, %{"red" => red, "green" => green}, :verify_timed_out)
    else
      {:verify_error, kind, reason} -> report(ctx, plan, %{"error" => kind}, reason)
    end
  end

  defp created({:ok, %{created: created}}), do: created
  defp created({:error, _not_trapped}), do: nil

  defp side(ctx, plan, dir, side, deadline) do
    name = "#{ctx.names}-#{side}"

    [name: name, network: name <> "-net", copy_dir: dir, runner_temp: ctx.env["RUNNER_TEMP"]]
    |> Keyword.merge(labels: ctx.labels, created: ctx.created, deadline: deadline)
    |> Keyword.merge(Keyword.take(ctx.deps, [:probe, :stat]))
    |> Sandbox.start()
    |> case do
      {:ok, sbx} ->
        try do
          steps(ctx, sbx, plan, side, deadline)
        after
          with :ok <- Sandbox.stop(sbx), do: File.rm_rf(dir)
        end

      {:error, reason} ->
        {:verify_error, "sandbox", reason}
    end
  end

  defp steps(ctx, sbx, plan, side, deadline) do
    install = min(now() + plan.install_timeout_s * 1_000, deadline)

    with :ok <- bootstrap(ctx, sbx, deadline),
         :ok <- run_steps(ctx, sbx, plan.install, install, side),
         :ok <- offline(sbx),
         :ok <-
           run_steps(ctx, sbx, plan.prepare, min(now() + @prepare_timeout_ms, deadline), side),
         do: test(ctx, sbx, plan, deadline)
  end

  # Bootstrap sets up the sandbox's own toolchains, so its failure is the
  # sandbox's (retryable), never the project's install failing under the fix.
  defp bootstrap(ctx, sbx, deadline) do
    with {:ok, %{status: 0, output: output}} <-
           Sandbox.exec(sbx, ["rsolv-sandbox", "bootstrap"],
             input: Sandbox.bootstrap_input(ctx.env["RSOLV_EXACT_RUNTIME_VERSIONS"]),
             timeout_ms: min(@bootstrap_timeout_ms, deadline - now()),
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
  defp run_steps(ctx, sbx, argvs, deadline, side) do
    Enum.reduce_while(argvs, :ok, fn argv, :ok ->
      case timed(sbx, argv, deadline, @step_max_bytes) do
        {:ok, status, output} ->
          log(ctx, output)
          step_done(status, side)

        {:timed_out, _status} ->
          step_done(:timed_out, side)

        {:error, :output_too_large} ->
          step_done(:output_too_large, side)

        {:error, reason} ->
          {:halt, {:verify_error, "sandbox", {:sandbox, reason}}}
      end
    end)
  end

  defp step_done(0, _side), do: {:cont, :ok}

  defp step_done(_failed, side),
    do: {:halt, {:verify_error, "install_failed_" <> side, :verify_error}}

  defp offline(sbx) do
    case Sandbox.disconnect(sbx) do
      :ok -> :ok
      {:error, reason} -> {:verify_error, "sandbox", reason}
    end
  end

  defp test(ctx, sbx, plan, deadline) do
    case timed(
           sbx,
           plan.test,
           min(now() + plan.test_timeout_s * 1_000, deadline),
           @test_max_bytes
         ) do
      {:ok, status, output} ->
        log(ctx, output)
        {:ok, side_result(status, false, report_bytes(sbx, plan, output, deadline))}

      {:timed_out, status} ->
        {:ok, side_result(status, true, "")}

      {:error, :output_too_large} ->
        {:ok, side_result(@killed_status, false, "")}

      {:error, reason} ->
        {:verify_error, "sandbox", {:sandbox, reason}}
    end
  end

  defp side_result(status, timed_out, report),
    do: %{"exit_code" => status, "timed_out" => timed_out, "report" => Base.encode64(report)}

  # Runs `argv` with what's left before `deadline`, in whole seconds (the
  # sandbox's `timeout` takes seconds). A step stopped by `timeout` once its
  # time was up, or by the host past its grace, is `{:timed_out, status}`;
  # the same status any earlier is the step's own.
  defp timed(sbx, argv, deadline, max_bytes) do
    start = now()
    limit_ms = div(deadline - start, 1_000) * 1_000

    if limit_ms < 1_000 do
      {:timed_out, 124}
    else
      result = Sandbox.exec(sbx, argv, timeout_ms: limit_ms, max_bytes: max_bytes)
      timed_out(result, now() - start >= limit_ms)
    end
  end

  defp timed_out({:ok, %{status: status}}, true) when status in @timeout_statuses,
    do: {:timed_out, status}

  defp timed_out({:ok, %{status: status, output: output}}, _late), do: {:ok, status, output}
  defp timed_out({:error, :timeout}, _late), do: {:timed_out, 124}
  defp timed_out(error, _late), do: error

  defp report_bytes(_sbx, %{report: %{argv: nil}}, output, _deadline)
       when byte_size(output) <= @report_max_bytes,
       do: output

  defp report_bytes(_sbx, %{report: %{argv: nil}}, _output, _deadline), do: ""

  defp report_bytes(sbx, %{report: %{argv: argv}}, _output, deadline) do
    case timed(sbx, argv, min(now() + @report_timeout_ms, deadline), @report_max_bytes) do
      {:ok, 0, bytes} -> bytes
      _missing_late_or_too_large -> ""
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
