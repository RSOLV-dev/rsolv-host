defmodule RsolvHost.CLI do
  @moduledoc """
  The command line: `rsolv-host scan [--max-issues N]`, `work --issue N
  [--resume]`, `verify --issue N`, `publish --issue N`, `version` and
  `selftest`. The preflight runs
  first, for every command, because the first invocation extracts the release.
  """

  alias RsolvHost.{Outcome, Platform, Preflight, TokenKeeper}

  @usage "usage: rsolv-host scan [--max-issues N] | work --issue N [--resume] | verify --issue N | publish --issue N | version | selftest [--online]"

  # name => {run function, OptionParser strict spec, required options}
  @commands %{
    "publish" => {{RsolvHost.Roles.Publish, :run}, [issue: :integer], [:issue]},
    "scan" => {{RsolvHost.Roles.Scan, :run}, [max_issues: :integer], []},
    "selftest" => {{__MODULE__, :selftest}, [online: :boolean], []},
    "verify" => {{RsolvHost.Roles.Verify, :run}, [issue: :integer], [:issue]},
    "version" => {{__MODULE__, :version}, [], []},
    "work" => {{RsolvHost.Roles.Work, :run}, [issue: :integer, resume: :boolean], [:issue]}
  }

  @roles %{"publish" => :publish, "scan" => :scan, "verify" => :verify, "work" => :work}

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
  catch
    kind, _reason -> {:error, {:unexpected, kind}}
  end

  @doc false
  @spec version(map(), map()) :: :ok
  def version(_opts, _env), do: IO.puts("rsolv-host #{Application.spec(:rsolv_host, :vsn)}")

  # RFC 8032 section 7.1, TEST 1: the empty message.
  @rfc8032_secret Base.decode16!(
                    "9D61B19DEFFD5A60BA844AF492EC2CC44449C5697B326919703BAC031CAE7F60"
                  )
  @rfc8032_public Base.decode16!(
                    "D75A980182B10AB7D54BFED3C964073A0EE172F3DAA62325AF021A68F707511A"
                  )
  @rfc8032_signature Base.decode16!(
                       "E5564300C360AC729086E2CC806E828A84877F1EB8E5D974D873E065224901555FB8821590A33BACC61E39701CF9B46BD25BF5F0595BBE24655141438E7A100B"
                     )

  @doc """
  Checks the packaged binary: Ed25519 signs and verifies the RFC 8032 vector
  (the crypto NIF and its statically linked OpenSSL load and agree), and with
  `--online` the configured platform's `/health` answers 200.
  """
  @spec selftest(map(), map()) :: :ok | {:error, term()}
  def selftest(opts, env) do
    with :ok <- ed25519() do
      IO.puts("selftest: ed25519 ok")
      if opts[:online], do: online(env), else: :ok
    end
  end

  defp ed25519 do
    signature = :crypto.sign(:eddsa, :none, "", [@rfc8032_secret, :ed25519])

    if signature == @rfc8032_signature and
         :crypto.verify(:eddsa, :none, "", signature, [@rfc8032_public, :ed25519]),
       do: :ok,
       else: {:error, :selftest_ed25519}
  end

  defp online(env) do
    with {:ok, req} <- Platform.req(env),
         :ok <- Platform.health(req) do
      IO.puts("selftest: platform ok")
    end
  end

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
