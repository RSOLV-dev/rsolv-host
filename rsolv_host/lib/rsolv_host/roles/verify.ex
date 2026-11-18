defmodule RsolvHost.Roles.Verify do
  @moduledoc """
  The `verify` role (RFC-150 §5): proves RED→GREEN for one issue on a fresh
  checkout of `base_sha`, with the plan the platform built.

  Before any sandbox starts it reads, in order: the touched paths; base facts
  for them, from git objects in the untouched checkout
  (`RsolvHost.BaseFactsReader`), and the platform's policy verdict; the plan,
  run only once `RsolvCore.VerifyPlan.decode/1` accepts it and it names the
  change set policy accepted; and the post-images, checked against its
  change set (`RsolvHost.PostImages`).

  Then RED, and only after it GREEN, each run two phases (design spec §3,
  B1-B10), every directory under `$RUNNER_TEMP/rsolv`, named by the run
  attempt, issue, side and phase:

  1. **BUILD**, on base code only: a pristine copy of the checkout and a new
     HOME. Bootstrap and `install` run behind the proxy, then the sandbox is
     disconnected and `prepare` runs. Every `install` and `prepare` step's
     output is kept as that side's build evidence, which the host never
     interprets. Docker must then confirm the sandbox gone
     (`RsolvHost.Sandbox.stop_confirmed/3`) before anything reads what it
     wrote; if it can't, the side is a sandbox error and its directories stay.
  2. The copy and HOME are copied (`cp -a`) into new TEST directories no
     sandbox has mounted, the BUILD ones are removed, and the side's change
     set is written in (`RsolvHost.Copies`: RED gets its snapshot, GREEN the
     whole change set): a path BUILD linked or rewrote is refused.
  3. **TEST**, the one hostile phase: no network, a read-only root, and only
     `test_prepare` (each step its own exec), `test` and the report, every
     one with the plan's `env`. Docker must confirm it gone before its
     directories are removed and before anything later starts.

  The host never builds a command, and never runs git or opens a path in a
  tree a sandbox has mounted: only the disk watchdog's `du` walks one,
  following no symlink and reading no content (`RsolvHost.Sandbox.watched/4`),
  and a phase past its disk budget is judged like an output flood.

  The verdicts are outcomes (exit 0): `verified`, `verify_failed` and
  `rejected` (by policy, or for want of a plan). What the code under test
  decides is never a verify error: a test past its time limit or its output
  cap is that side's result (`timed_out`, or an empty report). A BUILD
  `install` or `prepare` step that fails, times out or floods its output, or
  an overlay refused, is the side's install failure; a `test_prepare` step
  that does is its `prepare_failed`. A test that timed out is the platform's
  verify error, which the role ends as `verify_timed_out` (exit 2): running it
  again would time out again. The sandbox failing (Docker, the image,
  bootstrap, a teardown Docker can't confirm) is a verify error a new attempt
  may retry (exit 4).
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
  # Build evidence (spec §3.1): each step's output up to 256 KiB, 1 MiB a side.
  @evidence_step_bytes 256 * 1024
  @evidence_max_bytes 1024 * 1024
  # `timeout`'s status when it stopped a step: TERM, then KILL.
  @timeout_statuses [124, 137]
  # A test the host killed for its output or its disk: KILL's status.
  @killed_status 137
  # ponytail: the project's steps may grow the copy and HOME by 5 GiB past
  # what they use after bootstrap, measured every 5 s (`Sandbox.watched/4`
  # names the overshoot). A GitHub-hosted runner has about 14 GB free.
  @disk_allowance_bytes 5 * 1024 * 1024 * 1024
  @disk_poll_ms 5_000
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
  # receive, and 3 waits of at most 60 s: 13) and the base-facts read (5)
  # take at most 70, before the sandboxes' deadline at 95 (`@reserve_ms`
  # before the budget). RED gets half of what's left when it starts and
  # GREEN the rest. Within a side every stage's own limit is clamped to the
  # side's deadline: BUILD's copy of the checkout (10), its setup and image
  # pulls, bootstrap (15), install (up to 60) and prepare (5); the two
  # copies for TEST (10 each); TEST's setup, test_prepare (5), test (up to
  # 60) and report (1). Unclamped, one side could take over 3 hours.
  # Confirming a sandbox gone is clamped to the role's deadline instead, so
  # a side that used its time is still torn down: at most 4 minutes for
  # BUILD (rm, two inspects, network rm) and 2 for TEST.
  #
  # Past the sandboxes' deadline, a step ends within timeout's 10 s KILL
  # grace and the host's 30 s, a report within 41 s more, the disk
  # baseline's du at most 30 s, the watchdog's last measure at most 35 s,
  # and TEST's teardown at most 2 minutes: 4.5, inside the 5-minute reserve
  # before the verification is posted. A BUILD the deadline cuts short
  # skips TEST, but its teardown may take 4: then the post can outrun the
  # reserve and end `session_timeout` (exit 3), never a verdict.
  #
  # Measured (plan H7, the pinned sandbox image on a workstation, H0's
  # trees): a side's time is bootstrap's (the pytest demo about 25 s,
  # railsgoat at #324's base about 150 s, nearly all Ruby and its gems).
  # BUILD's teardown took about 0.6 s, TEST's 0.2 s, the copies for TEST at
  # most 1 s, and the whole role 60 s (pytest) and 328 s (railsgoat).
  @budget_ms 100 * 60 * 1_000
  @reserve_ms 5 * 60 * 1_000
  @bound ~w(change_set_digest red_digest policy_version)
  @rejections ["issue_rejected", "not_eligible"]

  @doc """
  Runs the role. `deps`: `:io`, `:probe` and `:stat` (passed to
  `RsolvHost.Sandbox.start/1`), `:budget_ms`, the role's deadline: every
  platform request, retries and their waits included, ends by it
  (`RsolvHost.Http.deadline/3`), or the role ends `session_timeout`; and, for
  tests, `:disk_poll_ms` and `:observe`, called with a side's directories
  once its BUILD is copied for TEST and before the BUILD's are removed.
  """
  @spec run(map(), map(), keyword()) :: Outcome.result()
  def run(%{issue: issue}, env, deps \\ []) do
    io = Keyword.get(deps, :io, :stdio)

    with {:ok, labels} <- Sandbox.labels(env, issue),
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
        labels: labels,
        names: "rsolv-#{labels["rsolv.run"]}-#{labels["rsolv.attempt"]}-#{issue}-verify"
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
         ctx = Map.put(ctx, :base_bytes, base_bytes(facts)),
         {:ok, verdict} <- call(ctx, :base_facts, [BaseFacts.to_json(facts)]),
         :ok <- accepted(verdict),
         {:ok, plan} <- plan(ctx, verdict),
         {:ok, %{"files" => files}} <- call(ctx, :post_images, []),
         {:ok, images} <- PostImages.checked(files, plan.change_set) do
      prove(ctx, plan, images)
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

  # Every touched regular base blob's bytes, read from git before any sandbox:
  # what `Copies` checks an overlay target against.
  defp base_bytes(facts),
    do:
      for(
        {path, %{type: :blob, content: bytes}} <- facts.paths,
        is_binary(bytes),
        into: %{},
        do: {path, bytes}
      )

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

  defp prove(ctx, plan, images) do
    trap = Sandbox.trap_sigterm(ctx.labels)

    try do
      Sandbox.remove_stale(ctx.labels)
      ctx |> Map.put(:created, created(trap)) |> sides(plan, images)
    after
      Sandbox.untrap_sigterm(trap)
    end
  end

  defp sides(ctx, plan, images) do
    {:ok, red_entries} = VerifyPlan.red(plan.change_set, plan.red_paths)
    red_deadline = now() + div(ctx.stages - now(), 2)

    with {:ok, red, red_built} <- side(ctx, plan, {red_entries, images}, "red", red_deadline),
         {:ok, green, green_built} <-
           side(ctx, plan, {plan.change_set, images}, "green", ctx.stages) do
      body = %{
        "red" => red,
        "green" => green,
        "build_evidence" => %{"red" => red_built, "green" => green_built}
      }

      report(ctx, plan, body, :verify_timed_out)
    else
      {:verify_error, kind, reason} -> report(ctx, plan, %{"error" => kind}, reason)
    end
  end

  defp created({:ok, %{created: created}}), do: created
  defp created({:error, _not_trapped}), do: nil

  # One side: BUILD on the base, then TEST on a copy of it with `overlay`
  # written in.
  defp side(ctx, plan, overlay, side, deadline) do
    name = "#{ctx.names}-#{side}"

    dirs = %{
      name: name,
      build: Path.join(ctx.root, name <> "-build"),
      build_home: Path.join(ctx.root, "home-" <> name <> "-build"),
      test: Path.join(ctx.root, name <> "-test"),
      test_home: Path.join(ctx.root, name <> "-test-home")
    }

    with {:ok, evidence} <- build(ctx, plan, side, dirs, deadline),
         {:ok, result} <- test(ctx, plan, overlay, side, dirs, deadline),
         do: {:ok, result, evidence}
  end

  # BUILD (B1): a pristine copy of the checkout and a new HOME, online for
  # bootstrap and `install`, then offline for `prepare`. Once Docker has
  # confirmed it gone (B2), its copy and HOME are copied for TEST (B3) and
  # removed.
  defp build(ctx, plan, side, dirs, deadline) do
    with :ok <- home(ctx, dirs.name <> "-build"),
         :ok <- copy(ctx.workspace, dirs.build, deadline) |> or_remove(ctx, dirs) do
      ctx
      |> start(dirs.name <> "-build", dirs.build, dirs.build_home, deadline, [])
      |> contained(ctx, &build_steps(ctx, &1, plan, side, deadline))
      |> built(ctx, side, dirs, deadline)
    end
  end

  # No sandbox has mounted them yet.
  defp or_remove(:ok, _ctx, _dirs), do: :ok

  defp or_remove(failed, ctx, dirs) do
    remove(ctx, [dirs.build, dirs.build_home])
    failed
  end

  defp home(ctx, name) do
    case Sandbox.make_home(ctx.env["RUNNER_TEMP"], name) do
      {:ok, _home} -> :ok
      {:error, :exists} -> {:verify_error, "sandbox", {:sandbox_setup, :home}}
    end
  end

  # A copy gets what's left of its side's time.
  defp copy(src, dest, deadline) do
    with left when left > 0 <- deadline - now(),
         :ok <- Workspace.copy(src, dest, timeout_ms: left) do
      :ok
    else
      left when is_integer(left) -> {:verify_error, "sandbox", {:sandbox, :deadline}}
      {:error, :exists} -> {:verify_error, "sandbox", {:sandbox_setup, :copy}}
      {:error, reason} -> {:verify_error, "sandbox", reason}
    end
  end

  defp built({{:ok, evidence}, :ok}, ctx, side, dirs, deadline) do
    result =
      with :ok <- copy(dirs.build, dirs.test, deadline),
           :ok <- copy(dirs.build_home, dirs.test_home, deadline) do
        if observe = ctx.deps[:observe], do: observe.(Map.put(dirs, :side, side))
        {:ok, evidence}
      end

    remove(ctx, [dirs.build, dirs.build_home])
    if result != {:ok, evidence}, do: remove(ctx, [dirs.test, dirs.test_home])
    result
  end

  defp built({failed, :ok}, ctx, _side, dirs, _deadline) do
    remove(ctx, [dirs.build, dirs.build_home])
    failed
  end

  defp built({_result, :error}, ctx, side, dirs, _deadline),
    do: unconfirmed(ctx, side <> " BUILD", [dirs.build, dirs.build_home])

  defp built({failed, :not_started}, _ctx, _side, _dirs, _deadline), do: failed

  # TEST (B4-B7): the overlay, then an offline sandbox with a read-only root,
  # running only `test_prepare`, `test` and the report, with the plan's env.
  defp test(ctx, plan, {entries, images}, side, dirs, deadline) do
    case Copies.write_images(dirs.test, entries, images, ctx.base_bytes) do
      :ok ->
        ctx
        |> start(dirs.name <> "-test", dirs.test, dirs.test_home, deadline,
          egress: :none,
          read_only: true
        )
        |> contained(ctx, &test_steps(ctx, &1, plan, side, deadline))
        |> tested(ctx, side, dirs)

      {:error, {:unsafe_path, _path}} ->
        remove(ctx, [dirs.test, dirs.test_home])
        {:verify_error, "install_failed_" <> side, :overlay_refused}
    end
  end

  defp tested({result, :ok}, ctx, _side, dirs) do
    remove(ctx, [dirs.test, dirs.test_home])
    result
  end

  defp tested({_result, :error}, ctx, side, dirs),
    do: unconfirmed(ctx, side <> " TEST", [dirs.test, dirs.test_home])

  defp tested({failed, :not_started}, _ctx, _side, _dirs), do: failed

  defp start(ctx, name, copy, home, deadline, opts) do
    [name: name, network: name <> "-net", copy_dir: copy, home_dir: home]
    |> Keyword.merge(runner_temp: ctx.env["RUNNER_TEMP"], labels: ctx.labels)
    |> Keyword.merge(created: ctx.created, deadline: deadline)
    |> Keyword.merge(Keyword.take(ctx.deps, [:probe, :stat]))
    |> Keyword.merge(opts)
    |> Sandbox.start()
  end

  # Runs `fun` in the sandbox, then has Docker confirm it gone (B2, B7):
  # `{result, :ok | :error}`, or `:not_started`. Teardown is clamped to the
  # role's deadline, not the side's, so a side that used all its time is
  # still torn down.
  defp contained({:ok, sbx}, ctx, fun) do
    result =
      try do
        fun.(sbx)
      catch
        kind, reason ->
          Sandbox.stop(sbx, ctx.io)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    {result, Sandbox.stop_confirmed(sbx, ctx.io, ctx.deadline)}
  end

  defp contained({:error, reason}, _ctx, _fun),
    do: {{:verify_error, "sandbox", sandbox_reason(reason)}, :not_started}

  # Something may still run in what it mounted: it stays, and nothing later
  # starts.
  defp unconfirmed(ctx, which, dirs) do
    ActionsLog.warning(
      "RSOLV",
      "Docker didn't confirm the #{which} sandbox removed; left #{Enum.join(dirs, ", ")}.",
      ctx.io
    )

    {:verify_error, "sandbox", {:sandbox, :teardown}}
  end

  defp remove(ctx, dirs), do: Enum.each(dirs, &Sandbox.remove_dir(&1, ctx.io))

  # A Docker step its side's deadline stopped is the sandbox's failure, as a
  # bootstrap it stopped is: a side's deadline isn't the role's budget.
  defp sandbox_reason(:session_timeout), do: {:sandbox, :deadline}
  defp sandbox_reason(reason), do: reason

  # The project's steps run under the disk watchdog, from what the copy and
  # HOME use once bootstrap has set up the toolchains.
  defp build_steps(ctx, sbx, plan, side, deadline) do
    failed = {:verify_error, "install_failed_" <> side, :verify_error}

    with :ok <- bootstrap(ctx, sbx, deadline) do
      sbx
      |> Sandbox.disk_used()
      |> watched(ctx, sbx, fn -> project(ctx, sbx, plan, failed, deadline) end)
      |> built_within(ctx, side, failed)
    end
  end

  defp built_within({:error, :disk_limit}, ctx, side, failed), do: over_disk(ctx, side, failed)
  defp built_within(result, _ctx, _side, _failed), do: result

  defp project(ctx, sbx, plan, failed, deadline) do
    install = min(now() + plan.install_timeout_s * 1_000, deadline)

    with {:ok, installed} <- run_steps(ctx, sbx, plan.install, install, failed),
         :ok <- offline(sbx),
         {:ok, prepared} <-
           run_steps(ctx, sbx, plan.prepare, min(now() + @prepare_timeout_ms, deadline), failed) do
      {install, prepare} = (installed ++ prepared) |> evidence() |> Enum.split(length(installed))
      {:ok, %{"install" => install, "prepare" => prepare}}
    end
  end

  # Build evidence (spec §3.1): each step's output, base64, or truncated past
  # its own cap or the side's total. Base code wrote it, before any fix byte
  # existed (B1).
  defp evidence(outputs) do
    outputs
    |> Enum.map_reduce(0, fn
      output, total
      when is_binary(output) and total + byte_size(output) <= @evidence_max_bytes ->
        {Base.encode64(output), total + byte_size(output)}

      _over, total ->
        {%{"truncated" => true}, total}
    end)
    |> elem(0)
  end

  defp watched({:ok, used}, ctx, sbx, fun) do
    poll_ms = Keyword.get(ctx.deps, :disk_poll_ms, @disk_poll_ms)
    Sandbox.watched(sbx, used + @disk_allowance_bytes, poll_ms, fun)
  end

  defp watched(:error, _ctx, _sbx, _fun), do: {:error, :disk_limit}

  defp over_disk(ctx, side, failed) do
    ActionsLog.warning(
      "RSOLV",
      "The #{side} sandbox wrote past its disk budget and was stopped (disk_limit).",
      ctx.io
    )

    failed
  end

  # A new disk baseline for TEST, then `test_prepare` (each step its own
  # exec; its output is only logged) and the test, each under the watchdog.
  defp test_steps(ctx, sbx, plan, side, deadline) do
    failed = {:verify_error, "prepare_failed_" <> side, :verify_error}
    used = Sandbox.disk_used(sbx)

    case test_prepare(ctx, sbx, plan, used, failed, deadline) do
      {:ok, _outputs} ->
        used
        |> watched(ctx, sbx, fn -> run_test(ctx, sbx, plan, deadline) end)
        |> disk_limited(ctx, side)

      {:error, :disk_limit} ->
        over_disk(ctx, side, failed)

      failed_or_error ->
        failed_or_error
    end
  end

  defp test_prepare(_ctx, _sbx, %{test_prepare: []}, _used, _failed, _deadline), do: {:ok, []}

  defp test_prepare(ctx, sbx, plan, used, failed, deadline) do
    prepare = min(now() + @prepare_timeout_ms, deadline)

    watched(used, ctx, sbx, fn ->
      run_steps(ctx, sbx, plan.test_prepare, prepare, failed, plan.env)
    end)
  end

  # Judged as an output flood: the side's result, with an empty report.
  defp disk_limited({:error, :disk_limit}, ctx, side) do
    over_disk(ctx, side, {:ok, side_result(@killed_status, false, "")})
  end

  defp disk_limited(result, _ctx, _side), do: result

  # Bootstrap sets up the sandbox's own toolchains, so its failure is the
  # sandbox's (retryable), never the project's install failing.
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

  # One deadline for all of a stage's steps. Each step's output is logged;
  # `{:ok, outputs}` keeps it, or `:over` past the evidence step cap. Any
  # step that fails, times out or floods its output is `failed`.
  defp run_steps(ctx, sbx, argvs, deadline, failed, env \\ %{}) do
    argvs
    |> Enum.reduce_while({:ok, []}, fn argv, {:ok, outputs} ->
      case timed(sbx, argv, deadline, @step_max_bytes, env) do
        {:ok, 0, output} ->
          log(ctx, output)
          {:cont, {:ok, [kept(output) | outputs]}}

        {:ok, _status, output} ->
          log(ctx, output)
          {:halt, failed}

        {:timed_out, _status} ->
          {:halt, failed}

        {:error, :output_too_large} ->
          {:halt, failed}

        {:error, reason} ->
          {:halt, {:verify_error, "sandbox", {:sandbox, reason}}}
      end
    end)
    |> case do
      {:ok, outputs} -> {:ok, Enum.reverse(outputs)}
      halted -> halted
    end
  end

  defp kept(output) when byte_size(output) <= @evidence_step_bytes, do: output
  defp kept(_output), do: :over

  defp offline(sbx) do
    case Sandbox.disconnect(sbx) do
      :ok -> :ok
      {:error, reason} -> {:verify_error, "sandbox", sandbox_reason(reason)}
    end
  end

  defp run_test(ctx, sbx, plan, deadline) do
    case timed(
           sbx,
           plan.test,
           min(now() + plan.test_timeout_s * 1_000, deadline),
           @test_max_bytes,
           plan.env
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
  defp timed(sbx, argv, deadline, max_bytes, env) do
    start = now()
    limit_ms = div(deadline - start, 1_000) * 1_000

    if limit_ms < 1_000 do
      {:timed_out, 124}
    else
      result = Sandbox.exec(sbx, argv, timeout_ms: limit_ms, max_bytes: max_bytes, env: env)
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

  defp report_bytes(sbx, %{report: %{argv: argv}} = plan, _output, deadline) do
    case timed(sbx, argv, min(now() + @report_timeout_ms, deadline), @report_max_bytes, plan.env) do
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
