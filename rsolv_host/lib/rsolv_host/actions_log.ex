defmodule RsolvHost.ActionsLog do
  @moduledoc """
  Everything the host writes to the GitHub Actions log, step outputs and job
  summary. Untrusted bytes go only through `untrusted/2`, which suspends
  workflow commands around them, so sandbox output can't mask, annotate or set
  outputs.
  """

  @doc "Writes untrusted text between `::stop-commands::` markers with an unguessable token."
  @spec untrusted(binary(), IO.device()) :: :ok
  def untrusted(text, io \\ :stdio) do
    token = token(text)
    IO.binwrite(io, ["::stop-commands::", token, "\n", text, "\n::", token, "::\n"])
  end

  defp token(text) do
    token = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    if String.contains?(text, token), do: token(text), else: token
  end

  @doc "Masks `secret` in the rest of the job's log."
  @spec mask(String.t(), IO.device()) :: :ok
  def mask(secret, io \\ :stdio), do: IO.binwrite(io, ["::add-mask::", secret, "\n"])

  @doc "Writes one `::error::` annotation with workflow-command escaping."
  @spec error(String.t(), String.t(), IO.device()) :: :ok
  def error(title, text, io \\ :stdio), do: command("error", title, text, io)

  @doc "Writes one `::warning::` annotation with workflow-command escaping."
  @spec warning(String.t(), String.t(), IO.device()) :: :ok
  def warning(title, text, io \\ :stdio), do: command("warning", title, text, io)

  @doc "Writes one `::notice::` annotation with workflow-command escaping."
  @spec notice(String.t(), String.t(), IO.device()) :: :ok
  def notice(title, text, io \\ :stdio), do: command("notice", title, text, io)

  defp command(kind, title, text, io) do
    IO.binwrite(io, ["::", kind, " title=", property(title), "::", data(text), "\n"])
  end

  defp data(text),
    do:
      text
      |> String.replace("%", "%25")
      |> String.replace("\r", "%0D")
      |> String.replace("\n", "%0A")

  defp property(text),
    do: text |> data() |> String.replace(":", "%3A") |> String.replace(",", "%2C")

  @doc """
  Appends `name=value` to the step-output file at `path`. Names are lowercase
  letters and underscores; a value can't hold a line break, so it can't forge
  another output.
  """
  @spec set_output(String.t(), String.t(), Path.t()) :: :ok | {:error, :invalid_output}
  def set_output(name, value, path), do: append_line(name, value, path)

  @doc "Appends one line to the job-summary file at `path`, writing `header` first if it's empty."
  @spec summary_row(String.t(), String.t(), Path.t()) :: :ok
  def summary_row(header, row, path) do
    prefix = if File.exists?(path) and File.stat!(path).size > 0, do: "", else: header
    File.write!(path, [prefix, row, "\n"], [:append])
  end

  defp append_line(name, value, path) do
    if name =~ ~r/\A[a-z_]+\z/ and not String.contains?(value, ["\n", "\r"]),
      do: File.write!(path, [name, "=", value, "\n"], [:append]),
      else: {:error, :invalid_output}
  end
end
