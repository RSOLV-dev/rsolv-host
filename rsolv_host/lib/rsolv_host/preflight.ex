defmodule RsolvHost.Preflight do
  @moduledoc """
  Refuses to run anywhere but a per-job install directory under `$RUNNER_TEMP`
  (Burrito spike: the default `~/.local/share` survives jobs on self-hosted
  runners, so a later job could run an earlier job's tampered extraction).
  """

  @doc """
  `:ok` when `RSOLV_HOST_INSTALL_DIR` is under `RUNNER_TEMP` and the release
  root `root_dir` is under the install dir; otherwise names the variable to fix.
  """
  @spec check(map(), String.t()) :: :ok | {:error, {:preflight, String.t()}}
  def check(env, root_dir) do
    with {:ok, temp} <- fetch(env, "RUNNER_TEMP"),
         {:ok, install} <- fetch(env, "RSOLV_HOST_INSTALL_DIR"),
         true <- under?(install, temp) and under?(root_dir, install) do
      :ok
    else
      false -> {:error, {:preflight, "RSOLV_HOST_INSTALL_DIR"}}
      {:error, _reason} = error -> error
    end
  end

  defp fetch(env, name) do
    case env[name] do
      "/" <> _absolute = value -> {:ok, value}
      _unset_or_relative -> {:error, {:preflight, name}}
    end
  end

  # ponytail: no symlink resolution; RUNNER_TEMP is runner-created, upgrade to
  # :file.read_link_all if self-hosted runners ever symlink it
  @doc "Whether `path` lies strictly inside `root`, after expanding both."
  @spec under?(String.t(), String.t()) :: boolean()
  def under?(path, root),
    do: String.starts_with?(Path.expand(path), Path.expand(root) <> "/")
end
