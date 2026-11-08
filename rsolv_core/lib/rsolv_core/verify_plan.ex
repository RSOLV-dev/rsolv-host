defmodule RsolvCore.VerifyPlan do
  @moduledoc """
  The platform-built verify plan (RFC-150 §5) as the host receives it. The host
  runs `rsolv-sandbox bootstrap`, then `install` (online, behind the proxy),
  disconnects the sandbox, runs `prepare` and `test` offline, and reads the
  report with `report.argv` (`null` means the test's own output is the
  report). It never runs a command from the work job.

  Every argv is 1–256 arguments of 1–4096 bytes of `RsolvCore.Text.plain?/1`
  text. Its executable must be one of #{inspect(~w(npx python bundle mix mvn vendor/bin/phpunit cat rm find))}.
  No argument is `sh`, `bash` or `-c`, or a path to `sh` or `bash` (RFC-150
  acceptance 16). The change set, its digest, the RED paths and the RED digest
  must agree.
  """

  alias RsolvCore.{ChangeSet, Text}

  @enforce_keys [
    :framework,
    :install,
    :prepare,
    :test,
    :report,
    :install_timeout_s,
    :test_timeout_s,
    :change_set,
    :change_set_digest,
    :red_paths,
    :red_digest,
    :policy_version
  ]
  defstruct @enforce_keys

  @type argv :: [String.t(), ...]
  @type t :: %__MODULE__{
          framework: String.t(),
          install: [argv()],
          prepare: [argv()],
          test: argv(),
          report: %{format: String.t(), argv: argv() | nil},
          install_timeout_s: pos_integer(),
          test_timeout_s: pos_integer(),
          change_set: [ChangeSet.Entry.t()],
          change_set_digest: String.t(),
          red_paths: [String.t()],
          red_digest: String.t(),
          policy_version: String.t()
        }

  @frameworks ~w(jest pytest rspec ex_unit junit phpunit)
  @formats ~w(jest_json rspec_json junit_xml exunit_trace)
  @executables ~w(npx python bundle mix mvn vendor/bin/phpunit cat rm find)
  @refused ~w(sh bash -c)
  @max_args 256
  @max_arg_bytes 4096
  @max_steps 8
  @max_timeout_s 3_600
  @fields ~w(v framework install prepare test report install_timeout_s test_timeout_s change_set
             change_set_digest red_paths red_digest policy_version)
          |> Enum.sort()

  @doc "Decodes and checks a plan's JSON form."
  @spec decode(term()) :: {:ok, t()} | {:error, :invalid_plan}
  def decode(%{"v" => 1} = json) do
    with true <- json |> Map.keys() |> Enum.sort() == @fields,
         true <- json["framework"] in @frameworks,
         true <- steps?(json["install"]) and steps?(json["prepare"]) and argv?(json["test"]),
         {:ok, report} <- report(json["report"]),
         true <- timeout?(json["install_timeout_s"]) and timeout?(json["test_timeout_s"]),
         true <- Text.plain?(json["policy_version"]),
         {:ok, entries} <- ChangeSet.from_json(json["change_set"]),
         true <- ChangeSet.digest(entries) == json["change_set_digest"],
         {:ok, red} <- red(entries, json["red_paths"]),
         true <- ChangeSet.digest(red) == json["red_digest"] do
      {:ok,
       %__MODULE__{
         framework: json["framework"],
         install: json["install"],
         prepare: json["prepare"],
         test: json["test"],
         report: report,
         install_timeout_s: json["install_timeout_s"],
         test_timeout_s: json["test_timeout_s"],
         change_set: entries,
         change_set_digest: json["change_set_digest"],
         red_paths: json["red_paths"],
         red_digest: json["red_digest"],
         policy_version: json["policy_version"]
       }}
    else
      _invalid -> {:error, :invalid_plan}
    end
  end

  def decode(_json), do: {:error, :invalid_plan}

  @doc "The RED snapshot's entries: the adds `red_paths` names, each exactly once."
  @spec red([ChangeSet.Entry.t()], term()) :: {:ok, [ChangeSet.Entry.t()]} | :error
  def red(entries, [_ | _] = red_paths) do
    red = Enum.filter(entries, &(&1.path in red_paths))

    if length(red) == length(red_paths) and Enum.uniq(red_paths) == red_paths and
         Enum.all?(red, &(&1.op == :add)),
       do: {:ok, red},
       else: :error
  end

  def red(_entries, _red_paths), do: :error

  defp steps?(steps) when is_list(steps) and length(steps) <= @max_steps,
    do: Enum.all?(steps, &argv?/1)

  defp steps?(_steps), do: false

  defp argv?([executable | _] = argv) when length(argv) <= @max_args do
    executable in @executables and
      Enum.all?(argv, &(is_binary(&1) and byte_size(&1) in 1..@max_arg_bytes and argument?(&1)))
  end

  defp argv?(_argv), do: false

  defp argument?(arg),
    do: Text.plain?(arg) and arg not in @refused and Path.basename(arg) not in @refused

  defp report(%{"format" => "exunit_trace", "argv" => nil} = report) when map_size(report) == 2,
    do: {:ok, %{format: "exunit_trace", argv: nil}}

  defp report(%{"format" => format, "argv" => argv} = report)
       when map_size(report) == 2 and format in @formats,
       do: if(argv?(argv), do: {:ok, %{format: format, argv: argv}}, else: :error)

  defp report(_report), do: :error

  defp timeout?(seconds), do: is_integer(seconds) and seconds in 1..@max_timeout_s
end
