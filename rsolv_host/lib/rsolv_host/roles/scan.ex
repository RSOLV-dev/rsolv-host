defmodule RsolvHost.Roles.Scan do
  @moduledoc """
  The `scan` role (RFC-150 §2.1, ADR-077 §4): runs the scanner in a sandbox with
  no network and no token, serves its calls through `RsolvHost.ScanRelay`, and
  registers the issues it filed. Writes the step outputs `pipeline_run_id` (when
  anything was registered) and `issues`, a JSON array of issue numbers.
  """

  alias RsolvHost.{
    ActionsLog,
    Frame,
    GitHub,
    Platform,
    Sandbox,
    ScanRelay,
    TokenKeeper,
    Workspace
  }

  @default_max_issues 3
  @max_issues 50
  @scan_timeout_ms 30 * 60 * 1_000

  @doc "Runs the role. `deps`: `:io`, `:probe` and `:stat` (see `RsolvHost.Roles.Work.run/3`)."
  @spec run(map(), map(), keyword()) :: :ok | {:error, term()}
  def run(opts, env, deps \\ []) do
    max_issues = Map.get(opts, :max_issues, @default_max_issues)
    io = Keyword.get(deps, :io, :stdio)

    with :ok <- max_issues(max_issues),
         {:ok, run_id} <- env_value(env, "GITHUB_RUN_ID", ~r/\A[0-9]{1,20}\z/),
         {:ok, workspace} <- env_value(env, "GITHUB_WORKSPACE", ~r/\A\//),
         {:ok, gh} <- GitHub.new(env),
         {:ok, keeper} <- TokenKeeper.start(role: :scan, env: env, io: io) do
      ctx = %{
        env: env,
        deps: deps,
        keeper: keeper,
        github: gh,
        max_issues: max_issues,
        name: "rsolv-#{run_id}-scan"
      }

      try do
        scan(ctx, workspace)
      after
        TokenKeeper.stop(keeper)
      end
    end
  end

  defp max_issues(n) when is_integer(n) and n in 1..@max_issues, do: :ok
  defp max_issues(_n), do: {:error, :usage}

  defp env_value(env, name, format) do
    case env[name] do
      value when is_binary(value) ->
        if value =~ format, do: {:ok, value}, else: {:error, {:missing_env, name}}

      nil ->
        {:error, {:missing_env, name}}
    end
  end

  defp scan(ctx, workspace) do
    copy = Path.join([ctx.env["RUNNER_TEMP"], "rsolv", "scan"])

    sandbox =
      [name: ctx.name, copy_dir: copy, runner_temp: ctx.env["RUNNER_TEMP"], egress: :none]
      |> Keyword.merge(Keyword.take(ctx.deps, [:probe, :stat]))

    with :ok <- Workspace.copy(workspace, copy),
         {:ok, sbx} <- Sandbox.start(sandbox) do
      try do
        with {:ok, done} <- relay(ctx, sbx), do: register(ctx, done)
      after
        Sandbox.stop(sbx)
      end
    end
  end

  defp relay(ctx, sbx) do
    case Sandbox.open(sbx, ["rsolv-sandbox", "scan"], @scan_timeout_ms) do
      {:ok, channel} -> serve(ctx, sbx, channel)
      {:error, :enoent} -> {:error, {:sandbox, :enoent}}
    end
  end

  defp serve(ctx, sbx, channel) do
    config = %{
      "repository" => ctx.github.repository,
      "max_issues" => ctx.max_issues,
      "issue_label" => "rsolv:detected"
    }

    :ok = sbx.exec.command(channel, Frame.encode(config))

    [
      channel: channel,
      exec: sbx.exec,
      keeper: ctx.keeper,
      github: ctx.github,
      repository: ctx.github.repository,
      max_issues: ctx.max_issues
    ]
    |> ScanRelay.new()
    |> ScanRelay.serve()
  end

  defp register(ctx, %{"issues" => []}), do: output(ctx, "issues", "[]")

  defp register(ctx, %{"issues" => issues} = done) do
    body = done |> Map.take(["manifest_files", "files_scanned"]) |> Map.put("issues", issues)

    with {:ok, %{req: req, raw: raw}} <- TokenKeeper.token(ctx.keeper),
         {:ok, %{"pipeline_run_id" => run}} when is_binary(run) <-
           Platform.register(req, raw, body),
         true <- run =~ ~r/\A[0-9a-f-]{36}\z/ do
      output(ctx, "pipeline_run_id", run)
      output(ctx, "issues", JSON.encode!(Enum.map(issues, & &1["number"])))
    else
      {:error, _reason} = error -> error
      _malformed -> {:error, :malformed_response}
    end
  end

  defp output(ctx, name, value) do
    case ctx.env["GITHUB_OUTPUT"] do
      nil -> :ok
      path -> ActionsLog.set_output(name, value, path)
    end
  end
end
