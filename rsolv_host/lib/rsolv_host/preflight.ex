defmodule RsolvHost.Preflight do
  @moduledoc """
  Refuses to run anywhere but a per-job install directory under `$RUNNER_TEMP`
  (Burrito spike: the default `~/.local/share` survives jobs on self-hosted
  runners, so a later job could run an earlier job's tampered extraction).

  It also refuses when a variable that changes how the VM starts is set: any
  `ERL_*FLAGS` (`ERL_AFLAGS`, `ERL_FLAGS`, `ERL_ZFLAGS` and the versioned
  `ERL_OTP<n>_FLAGS`), `ERL_LIBS`, `ERL_COMPILER_OPTIONS` or `EMU`. Those can
  re-enable crash dumps, add code paths or pick another emulator.

  This is the second layer. The patched Burrito wrapper
  (`patches/burrito-launcher-env.patch`) already refuses the same variables,
  and clears `LD_*` and `EMU`, before it starts `erlexec`: `-s`/`-eval` in a
  flag variable would run after boot, and the loader variables act before any
  Elixir code. `run_cli` is fixed at compile time, so `-rsolv_host run_cli
  false` can't skip this check either. These refusals stop misconfiguration;
  whoever controls the job's environment still controls the job, so the
  reusable workflows start the host with a minimal environment.
  """

  @vm_env ~w(ERL_LIBS ERL_COMPILER_OPTIONS EMU)

  @doc """
  `:ok` when no `ERL_*FLAGS`, `ERL_LIBS`, `ERL_COMPILER_OPTIONS` or `EMU` is set,
  `RSOLV_HOST_INSTALL_DIR` is under `RUNNER_TEMP` and the release root
  `root_dir` is under the install dir; otherwise names the variable to fix.
  """
  @spec check(map(), String.t()) ::
          :ok | {:error, {:preflight, String.t()} | {:vm_env, String.t()}}
  def check(env, root_dir) do
    with :ok <- no_vm_env(env),
         {:ok, temp} <- fetch(env, "RUNNER_TEMP"),
         {:ok, install} <- fetch(env, "RSOLV_HOST_INSTALL_DIR"),
         true <- under?(install, temp) and under?(root_dir, install) do
      :ok
    else
      false -> {:error, {:preflight, "RSOLV_HOST_INSTALL_DIR"}}
      {:error, _reason} = error -> error
    end
  end

  defp no_vm_env(env) do
    case env |> Enum.sort() |> Enum.find(fn {name, value} -> value != "" and vm_env?(name) end) do
      nil -> :ok
      {name, _value} -> {:error, {:vm_env, name}}
    end
  end

  defp vm_env?(name), do: name in @vm_env or String.match?(name, ~r/^ERL_.*FLAGS$/)

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
