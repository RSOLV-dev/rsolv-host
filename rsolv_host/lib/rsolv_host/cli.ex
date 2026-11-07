defmodule RsolvHost.CLI do
  @moduledoc """
  The command line: `rsolv-host scan [--max-issues N]`, `work --issue N
  [--resume]`, `publish --issue N`, `version` and `selftest`. The preflight runs
  first, for every command, because the first invocation extracts the release.
  """

  alias RsolvHost.{Outcome, Preflight, TokenKeeper}

  @usage "usage: rsolv-host scan [--max-issues N] | work --issue N [--resume] | publish --issue N | version | selftest"

  # name => {run function, OptionParser strict spec, required options}
  @commands %{
    "publish" => {{RsolvHost.Roles.Publish, :run}, [issue: :integer], [:issue]},
    "scan" => {{RsolvHost.Roles.Scan, :run}, [max_issues: :integer], []},
    "selftest" => {{__MODULE__, :selftest}, [], []},
    "version" => {{__MODULE__, :version}, [], []},
    "work" => {{RsolvHost.Roles.Work, :run}, [issue: :integer, resume: :boolean], [:issue]}
  }

  @roles %{"publish" => :publish, "scan" => :scan, "work" => :work}

  @doc "The command names, sorted. Burrito's wrapper owns `maintenance`, so it isn't one."
  @spec commands() :: [String.t()]
  def commands, do: @commands |> Map.keys() |> Enum.sort()

  @doc """
  Runs one command and returns the process exit code (`RsolvHost.Outcome`).
  `opts[:commands]` replaces the command table (tests).
  """
  @spec main([String.t()], map(), String.t(), keyword()) :: non_neg_integer()
  def main(argv, env, root_dir, opts \\ []) do
    commands = Keyword.get(opts, :commands, @commands)

    case Preflight.check(env, root_dir) do
      :ok -> argv |> parse(commands) |> run(env)
      {:error, _reason} = error -> finish(error, %{}, env)
    end
  end

  defp parse([name | args], commands) do
    with {:ok, {fun, spec, required}} <- Map.fetch(commands, name),
         {opts, [], []} <- OptionParser.parse(args, strict: spec),
         opts = Map.new(opts),
         true <- Enum.all?(required, &Map.has_key?(opts, &1)) do
      {:ok, name, fun, opts}
    else
      _unknown_or_invalid -> {:error, :usage}
    end
  end

  defp parse([], _commands), do: {:error, :usage}

  defp run({:ok, name, fun, opts}, env) do
    code = fun |> call(opts, env) |> finish(opts, env)
    discard(code, Map.get(@roles, name), env, opts)
    code
  end

  defp run({:error, :usage} = error, env) do
    IO.puts(@usage)
    finish(error, %{}, env)
  end

  # A transient failure (3) is retried with --resume, which needs the hand-off token.
  defp discard(3, _role, _env, _opts), do: :ok
  defp discard(_code, nil, _env, _opts), do: :ok
  defp discard(_code, role, env, opts), do: TokenKeeper.discard(env, role, opts[:issue])

  defp call(fun, opts, env) do
    case fun do
      {module, function} -> apply(module, function, [opts, env])
      fun when is_function(fun, 2) -> fun.(opts, env)
    end
  rescue
    exception -> {:error, {:unexpected, exception}}
  end

  @doc false
  @spec version(map(), map()) :: :ok
  def version(_opts, _env), do: IO.puts("rsolv-host #{Application.spec(:rsolv_host, :vsn)}")

  @doc false
  @spec selftest(map(), map()) :: {:error, :selftest_unavailable}
  def selftest(_opts, _env), do: {:error, :selftest_unavailable}

  defp finish(result, opts, env) do
    report(result, opts, env)
    Outcome.exit_code(result)
  end

  defp report(:ok, _opts, _env), do: :ok

  defp report({:outcome, _outcome, _has_patch} = result, opts, env), do: record(result, opts, env)

  defp report({:error, reason, :validated} = result, opts, env) do
    record(result, opts, env)
    Outcome.annotate(reason)
  end

  defp report({:error, reason}, _opts, _env), do: Outcome.annotate(reason)

  defp record(result, opts, env) do
    Outcome.report(result,
      issue: opts[:issue],
      output: env["GITHUB_OUTPUT"],
      summary: env["GITHUB_STEP_SUMMARY"]
    )
  end
end
