defmodule RsolvHost.Workspace do
  @moduledoc """
  The copies of the checkout that sandboxes mount. Every copy is made before the
  first sandbox starts, with `cp -a`, so the BEAM never reads file contents and
  symlinks stay symlinks. After a sandbox starts the host never opens a path in a
  mounted tree (RFC-150 acceptance 5a).

  The copy's `.git` keeps only what git needs to read the history (`HEAD`,
  `objects`, `refs`, `packed-refs`, `index`, `shallow`), with a fixed minimal
  `config`: the checkout's config can carry credentials (`actions/checkout`'s
  `persist-credentials` writes an `http.*.extraheader`) or include files that
  do, and the code under test reads everything in its copy.
  """

  @copy_timeout_ms 600_000
  @git_kept ~w(HEAD config index objects packed-refs refs shallow)
  # ponytail: SHA-1 repositories only; a SHA-256 one needs
  # repositoryformatversion 1 and its extensions.objectFormat kept.
  @git_config "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n"

  @doc "Copies the tree at `src` into a new directory `dest`. Option: `:exec`."
  @spec copy(Path.t(), Path.t(), keyword()) ::
          :ok | {:error, :exists | {:sandbox_setup, :copy} | {:sandbox, :enoent}}
  def copy(src, dest, opts \\ []) do
    exec = Keyword.get_lazy(opts, :exec, &RsolvHost.exec/0)

    if File.exists?(dest) do
      {:error, :exists}
    else
      File.mkdir_p!(dest)

      case exec.run("cp", ["-a", "--", src <> "/.", dest], timeout_ms: @copy_timeout_ms) do
        {:ok, %{status: 0}} -> dest |> Path.join(".git") |> sanitize()
        {:error, :enoent} -> {:error, {:sandbox, :enoent}}
        _failed -> {:error, {:sandbox_setup, :copy}}
      end
    end
  end

  # File.rm_rf/1 and File.lstat/1 never follow a symlink. A .git that isn't a
  # directory (a gitfile) names a repository outside every mount.
  defp sanitize(git), do: sanitize(File.lstat(git), git)

  defp sanitize({:ok, %File.Stat{type: :directory}}, git) do
    for name <- File.ls!(git), name not in @git_kept, do: File.rm_rf!(Path.join(git, name))
    File.rm_rf!(Path.join(git, "config"))
    File.write!(Path.join(git, "config"), @git_config, [:exclusive])
    drop_locks(Path.join(git, "refs"))
  end

  defp sanitize(_not_a_directory, _git), do: :ok

  defp drop_locks(dir) do
    for {:ok, names} <- [File.ls(dir)],
        name <- names,
        path = Path.join(dir, name),
        do: drop_lock(File.lstat!(path), path)

    :ok
  end

  defp drop_lock(%File.Stat{type: :directory}, path), do: drop_locks(path)

  defp drop_lock(_file, path),
    do: if(String.ends_with?(path, ".lock"), do: File.rm!(path))

  # ponytail: a tree with more directories than this keeps the rest as the
  # code under test left them, and its removal may then fail (and warn).
  @max_restored_dirs 100_000

  @doc """
  Removes `dir`, a copy or HOME whose sandbox Docker has removed (so nothing
  changes it meanwhile). It first gives the owner rwx back on every directory
  beneath it, up to #{@max_restored_dirs}, found with `File.lstat/1`, so a
  symlink is never followed, chmod'ed or looked through: code under test can
  leave a directory `chmod 000`. `{:error, path}` names what couldn't be
  removed.
  """
  @spec remove(Path.t()) :: :ok | {:error, Path.t()}
  def remove(dir) do
    restore([dir], @max_restored_dirs)

    case File.rm_rf(dir) do
      {:ok, _removed} -> :ok
      {:error, _reason, path} -> {:error, path}
    end
  end

  defp restore([], _left), do: :ok
  defp restore(_dirs, 0), do: :ok

  defp restore([dir | rest], left) do
    with {:ok, %File.Stat{type: :directory, mode: mode}} <- File.lstat(dir),
         :ok <- File.chmod(dir, Bitwise.bor(mode, 0o700)),
         {:ok, names} <- File.ls(dir) do
      restore(Enum.map(names, &Path.join(dir, &1)) ++ rest, left - 1)
    else
      _not_a_directory -> restore(rest, left)
    end
  end
end
