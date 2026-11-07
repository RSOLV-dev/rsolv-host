defmodule RsolvHost.Runtimes do
  @moduledoc """
  Annotations for the sandbox's runtime installs (the `runtimes` list in
  `rsolv-sandbox bootstrap`'s result), per the owner's 2026-11-07 decisions
  (RFC-150 3d). A same-minor Python fallback is a warning naming the requested
  and actual versions and the build used; a failed install is an error.

  The reports come from the sandbox, so each value must match a strict format
  (a known runtime, status and reason; a version; a build file name and
  digest) before it goes into fixed text. A fallback across a minor version is
  refused here too. Anything else gets one generic warning.
  """

  alias RsolvHost.ActionsLog

  @title "RSOLV runtime"
  @names %{"python" => "Python", "php" => "PHP", "maven" => "Maven"}
  @reasons %{
    "no_attestations" => "it has no published build attestations",
    "no_attested_patch" =>
      "neither it nor any other patch of its minor version has build attestations",
    "verification_failed" => "its build attestations failed verification",
    "transient" => "the download kept failing",
    "install_failed" => "mise couldn't install it",
    "build_failed" => "the build failed",
    "timeout" => "the build ran out of time",
    "unsupported" => "mise doesn't offer that version",
    "unresolved" => "its latest version couldn't be looked up"
  }
  @version ~r/\A[0-9A-Za-z][0-9A-Za-z.+_-]{0,39}\z/
  @artifact ~r/\A[0-9A-Za-z][0-9A-Za-z.+_-]{0,159}( sha256:[0-9a-f]{64})?\z/

  @doc "Writes the annotations for `reports` (nil writes nothing)."
  @spec annotate(term(), IO.device()) :: :ok
  def annotate(reports, io \\ :stdio)
  def annotate(nil, _io), do: :ok
  def annotate(reports, io) when is_list(reports), do: Enum.each(reports, &report(&1, io))
  def annotate(_malformed, io), do: unreadable(io)

  defp report(%{"status" => "installed", "runtime" => runtime}, _io)
       when is_map_key(@names, runtime),
       do: :ok

  defp report(
         %{
           "status" => "failed",
           "runtime" => runtime,
           "requested" => requested,
           "reason" => reason
         },
         io
       )
       when is_map_key(@names, runtime) and is_map_key(@reasons, reason) and is_binary(requested) do
    if requested =~ @version do
      ActionsLog.error(
        @title,
        "#{@names[runtime]} #{requested} was not installed: #{@reasons[reason]}. " <>
          "No other version was substituted, so tests that need it can't run.",
        io
      )
    else
      unreadable(io)
    end
  end

  defp report(
         %{
           "status" => "fallback",
           "runtime" => "python",
           "requested" => requested,
           "actual" => actual
         } = report,
         io
       )
       when is_binary(requested) and is_binary(actual) do
    with {:ok, minor} <- same_minor(requested, actual),
         {:ok, artifact} <- artifact(Map.get(report, "artifact")) do
      ActionsLog.warning(
        @title,
        "Python #{requested} has no published build attestations, so #{actual}, the newest " <>
          "attested #{minor} patch, was installed in its place#{artifact}. To fail instead, " <>
          "set RSOLV_EXACT_RUNTIME_VERSIONS=true.",
        io
      )
    else
      :error -> unreadable(io)
    end
  end

  defp report(_malformed, io), do: unreadable(io)

  defp same_minor(requested, actual) do
    with [_, minor] <- Regex.run(~r/\A(\d+\.\d+)\.\d+\z/, requested),
         true <- actual =~ ~r/\A#{Regex.escape(minor)}\.\d+\z/ do
      {:ok, minor}
    else
      _other -> :error
    end
  end

  defp artifact(nil), do: {:ok, ""}

  defp artifact(artifact) when is_binary(artifact) do
    if artifact =~ @artifact, do: {:ok, " (build: #{artifact})"}, else: :error
  end

  defp artifact(_other), do: :error

  defp unreadable(io),
    do:
      ActionsLog.warning(
        @title,
        "The sandbox returned a runtime report the host couldn't read.",
        io
      )
end
