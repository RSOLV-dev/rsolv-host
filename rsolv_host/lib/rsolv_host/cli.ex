defmodule RsolvHost.CLI do
  @moduledoc """
  The command line: `rsolv-host scan [--max-issues N]`, `work --issue N
  [--resume]`, `publish --issue N`, `version` and `selftest`. The preflight runs
  first, for every command, because the first invocation extracts the release.
  """

  alias RsolvHost.{ActionsLog, Preflight}

  @usage "usage: rsolv-host scan [--max-issues N] | work --issue N [--resume] | publish --issue N | version | selftest"

  # name => {run function, OptionParser strict spec, required options}
  @commands %{
    "publish" => {{RsolvHost.Roles.Publish, :run}, [issue: :integer], [:issue]},
    "scan" => {{RsolvHost.Roles.Scan, :run}, [max_issues: :integer], []},
    "selftest" => {{__MODULE__, :selftest}, [], []},
    "version" => {{__MODULE__, :version}, [], []},
    "work" => {{RsolvHost.Roles.Work, :run}, [issue: :integer, resume: :boolean], [:issue]}
  }

  @doc "The command names, sorted. Burrito's wrapper owns `maintenance`, so it isn't one."
  @spec commands() :: [String.t()]
  def commands, do: @commands |> Map.keys() |> Enum.sort()

  @doc "Runs one command and returns the process exit code."
  @spec main([String.t()], map(), String.t()) :: non_neg_integer()
  def main(argv, env, root_dir) do
    case Preflight.check(env, root_dir) do
      :ok -> argv |> parse() |> run(env)
      {:error, reason} -> finish({:error, reason}, env)
    end
  end

  defp parse([name | args]) do
    with {:ok, {fun, spec, required}} <- Map.fetch(@commands, name),
         {opts, [], []} <- OptionParser.parse(args, strict: spec),
         opts = Map.new(opts),
         true <- Enum.all?(required, &Map.has_key?(opts, &1)) do
      {:ok, fun, opts}
    else
      _unknown_or_invalid -> {:error, :usage}
    end
  end

  defp parse([]), do: {:error, :usage}

  defp run({:ok, {module, function}, opts}, env),
    do: finish(apply(module, function, [opts, env]), env)

  defp run({:error, :usage}, env) do
    IO.puts(@usage)
    finish({:error, :usage}, env)
  end

  @doc false
  @spec version(map(), map()) :: :ok
  def version(_opts, _env), do: IO.puts("rsolv-host #{Application.spec(:rsolv_host, :vsn)}")

  @doc false
  @spec selftest(map(), map()) :: {:error, :selftest_unavailable}
  def selftest(_opts, _env), do: {:error, :selftest_unavailable}

  defp finish(:ok, _env), do: 0

  defp finish({:error, {:preflight, variable}}, _env) do
    ActionsLog.error(
      "RSOLV configuration",
      "Set #{variable} so rsolv-host installs under $RUNNER_TEMP (use RSOLV's reusable workflows)."
    )

    2
  end

  defp finish({:error, _reason}, _env), do: 2
end
