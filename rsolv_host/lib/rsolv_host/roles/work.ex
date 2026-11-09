defmodule RsolvHost.Roles.Work do
  @moduledoc """
  The `work` role (RFC-150 §2.1, §4.1): from the job's OIDC token to an uploaded
  patch, for one issue.

  It copies the checkout, starts the sandbox behind the egress proxy, bootstraps
  it, runs VALIDATE and then MITIGATE through the tool relay, has the sandbox
  produce the patch, and uploads it with the red patch it took when VALIDATE
  ended. Every model outcome is `{:outcome, …}`
  (exit 0); a failure after VALIDATE confirmed the vulnerability is
  `{:error, reason, :validated}`. The host never runs git or opens a path in the
  mounted copy once the sandbox starts.

  `--resume` (the workflow's one retry, on exit 3) refreshes the first attempt's
  run token and uses a fresh copy and fresh container names.
  """

  alias RsolvHost.{
    ActionsLog,
    Frame,
    Http,
    Outcome,
    Platform,
    Relay,
    Runtimes,
    Sandbox,
    TokenKeeper,
    Workspace
  }

  @max_patch_bytes 5 * 1024 * 1024
  @max_red_patch_bytes 512 * 1024
  @bootstrap_timeout_ms 900_000
  @bootstrap_max_bytes 1024 * 1024
  @patch_timeout_ms 300_000
  @patch_max_bytes 8 * 1024 * 1024
  # Both attempts (the workflow retries once) fit GitHub's 6-hour job limit.
  @budget_ms 150 * 60 * 1_000

  @doc """
  Runs the role. `deps` replaces collaborators in tests: `:io`, `:probe`,
  `:stat` (passed to `RsolvHost.Sandbox.start/1`), `:backoff_ms` (passed to
  `RsolvHost.Relay.run_session/5`) and `:budget_ms`.

  The role has one time budget (2.5 hours by default), from its start to the
  upload: both sessions share its deadline, and a patch ready after it isn't
  uploaded (`{:error, :session_timeout, :validated}`).
  """
  @spec run(map(), map(), keyword()) :: Outcome.result()
  def run(%{issue: issue} = opts, env, deps \\ []) do
    resume? = Map.get(opts, :resume, false)
    io = Keyword.get(deps, :io, :stdio)

    with {:ok, run_id} <- env_value(env, "GITHUB_RUN_ID", ~r/\A[0-9]{1,20}\z/),
         {:ok, workspace} <- env_value(env, "GITHUB_WORKSPACE", ~r/\A\//),
         {:ok, keeper} <-
           TokenKeeper.start(role: :work, issue: issue, env: env, resume: resume?, io: io) do
      ctx = %{
        issue: issue,
        env: env,
        io: io,
        deps: deps,
        keeper: keeper,
        workspace: workspace,
        suffix: if(resume?, do: "-2", else: ""),
        deadline: System.monotonic_time(:millisecond) + Keyword.get(deps, :budget_ms, @budget_ms),
        names: "rsolv-#{run_id}-#{issue}"
      }

      try do
        prepare(ctx)
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

  defp prepare(ctx) do
    copy = Path.join([ctx.env["RUNNER_TEMP"], "rsolv", "work" <> ctx.suffix])

    with {:ok, %{binding: %{"pipeline_run_id" => run, "base_sha" => base}}} <- token(ctx),
         :ok <- Workspace.copy(ctx.workspace, copy),
         {:ok, sbx} <- start_sandbox(ctx, copy) do
      try do
        ctx |> Map.merge(%{sbx: sbx, run: run, base: base}) |> work()
      after
        Sandbox.stop(sbx)
      end
    end
  end

  defp token(ctx) do
    case TokenKeeper.token(ctx.keeper) do
      {:ok, %{binding: %{"pipeline_run_id" => _, "base_sha" => _}}} = ok -> ok
      {:ok, _unbound} -> {:error, :run_unbound}
      error -> error
    end
  end

  defp start_sandbox(ctx, copy) do
    [
      name: ctx.names <> "-work" <> ctx.suffix,
      network: ctx.names <> "-net" <> ctx.suffix,
      copy_dir: copy,
      runner_temp: ctx.env["RUNNER_TEMP"]
    ]
    |> Keyword.merge(Keyword.take(ctx.deps, [:probe, :stat]))
    |> Sandbox.start()
  end

  defp work(ctx) do
    bootstrap(ctx)

    case session(ctx, :validation) do
      {:ok, result} -> validated(ctx, validation_outcome(result))
      {:error, reason} -> {:error, reason}
    end
  end

  defp bootstrap(ctx) do
    with {:ok, %{output: output}} <-
           Sandbox.exec(ctx.sbx, ["rsolv-sandbox", "bootstrap"],
             input: Sandbox.bootstrap_input(ctx.env["RSOLV_EXACT_RUNTIME_VERSIONS"]),
             timeout_ms: @bootstrap_timeout_ms,
             max_bytes: @bootstrap_max_bytes
           ),
         %{"log_tail" => tail} = result when is_binary(tail) <- Relay.last_object(output) do
      ActionsLog.untrusted(tail, ctx.io)
      Runtimes.annotate(result["runtimes"], ctx.io)
    end
  end

  defp session(ctx, phase) do
    relay_opts = [io: ctx.io, deadline: ctx.deadline] ++ Keyword.take(ctx.deps, [:backoff_ms])
    body = %{"pipeline_run_id" => ctx.run, "issue_number" => ctx.issue}
    Relay.run_session(ctx.keeper, ctx.sbx, phase, body, relay_opts)
  end

  defp validation_outcome(%{"validated" => true}), do: :validated
  defp validation_outcome(%{"is_false_positive" => true}), do: :false_positive
  defp validation_outcome(%{"classification" => "false_positive" <> _}), do: :false_positive
  defp validation_outcome(_result), do: :not_validated

  # RFC-150 §4.1, ADR-075: the RED snapshot is taken when VALIDATE ends,
  # before MITIGATE can touch the test, and uploaded with the final patch.
  defp validated(ctx, :validated) do
    case ctx |> patch() |> red_patch() do
      {:ok, red} ->
        mitigate(Map.put(ctx, :red, red))

      :too_large ->
        too_large(ctx, "The failing test was larger than 512 KiB and was not uploaded.")

      {:error, reason} ->
        {:error, reason, :validated}
    end
  end

  defp validated(_ctx, outcome), do: {:outcome, outcome, false}

  defp red_patch({:ok, bytes}) when byte_size(bytes) > @max_red_patch_bytes, do: :too_large
  defp red_patch(result), do: result

  defp mitigate(ctx) do
    case session(ctx, :mitigation) do
      {:ok, %{"success" => true}} -> ctx |> patch() |> upload(ctx)
      {:ok, _failed} -> {:outcome, :mitigation_failed, false}
      {:error, reason} -> {:error, reason, :validated}
    end
  end

  defp patch(ctx) do
    ctx.sbx
    |> Sandbox.exec(["rsolv-sandbox", "patch"],
      input: Frame.encode(%{"base_sha" => ctx.base}),
      timeout_ms: @patch_timeout_ms,
      max_bytes: @patch_max_bytes
    )
    |> patch_bytes()
  end

  defp too_large(ctx, message) do
    ActionsLog.warning("RSOLV", message, ctx.io)
    {:outcome, :mitigation_failed, false}
  end

  defp patch_bytes({:ok, %{status: 0, output: output}}) do
    with %{"patch" => encoded} when is_binary(encoded) <- Relay.last_object(output),
         {:ok, bytes} <- Base.decode64(encoded) do
      {:ok, bytes}
    else
      _malformed -> {:error, :malformed_patch}
    end
  end

  defp patch_bytes({:error, :output_too_large}), do: :too_large
  defp patch_bytes(_failed), do: {:error, :malformed_patch}

  defp upload({:ok, ""}, _ctx), do: {:outcome, :mitigation_failed, false}

  defp upload({:ok, bytes}, ctx) when byte_size(bytes) > @max_patch_bytes,
    do: upload(:too_large, ctx)

  defp upload(:too_large, ctx),
    do: too_large(ctx, "The fix was larger than 5 MiB and was not uploaded.")

  defp upload({:ok, bytes}, ctx) do
    with :ok <- in_budget(ctx),
         {:ok, %{req: req, raw: raw}} <- TokenKeeper.token(ctx.keeper),
         req = Http.deadline(req, ctx.deadline, :session_timeout),
         :ok <- Platform.upload_result(req, raw, ctx.run, ctx.issue, bytes, ctx.red) do
      {:outcome, :mitigated, true}
    else
      {:error, {:platform, 409, "already_uploaded"}} -> {:outcome, :mitigated, true}
      {:error, reason} -> {:error, reason, :validated}
    end
  end

  defp upload({:error, reason}, _ctx), do: {:error, reason, :validated}

  defp in_budget(ctx) do
    if System.monotonic_time(:millisecond) < ctx.deadline,
      do: :ok,
      else: {:error, :session_timeout}
  end
end
