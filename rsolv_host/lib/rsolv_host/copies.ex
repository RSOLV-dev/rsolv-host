defmodule RsolvHost.Copies do
  @moduledoc """
  Writes a change set's post-images into a copy (RFC-150 §5, acceptance 5b;
  B4) that no sandbox has mounted yet, so the checks can't be raced. Each
  path must pass `RsolvCore.ChangeSet.valid_path?/1`, and every existing
  ancestor must be a real directory (`File.lstat/1`, never followed), so
  nothing is written or deleted through a symlink or beneath a file.

  - An add's path must be absent: its file is created `O_EXCL`.
  - A modify's or delete's path must be a regular file with one link that
    still holds its base blob (`base_blob_sha`), checked before anything is
    written: a BUILD that linked or rewrote it is refused, and no other
    pathname can change. A modify writes a new file in the copy's root and
    renames it into place.

  What it wrote is then checked again with `File.lstat/1`. Any refusal is
  `{:error, {:unsafe_path, path}}`.
  """

  alias RsolvCore.{BaseFacts, ChangeSet}
  alias RsolvCore.ChangeSet.Entry

  @doc "Applies `entries` to the copy at `dir`, with `images` (path => bytes) for adds and modifies."
  @spec write_images(Path.t(), [Entry.t()], %{String.t() => binary()}) ::
          :ok | {:error, {:unsafe_path, String.t()}}
  def write_images(dir, entries, images) do
    Enum.reduce_while(entries, :ok, fn %Entry{path: path} = entry, :ok ->
      with true <- ChangeSet.valid_path?(path),
           :ok <- parents(dir, entry),
           :ok <- write(dir, Path.join(dir, path), entry, images) do
        {:cont, :ok}
      else
        _unsafe -> {:halt, {:error, {:unsafe_path, path}}}
      end
    end)
  end

  defp write(_dir, target, %Entry{op: :delete} = entry, _images) do
    with :ok <- based(target, entry), do: File.rm(target)
  end

  # O_EXCL: nothing already at the path is followed or reused.
  defp write(_dir, target, %Entry{op: :add, path: path, mode: mode}, images) do
    with :ok <- create(target, Map.fetch!(images, path), file_mode(mode)), do: written(target)
  end

  defp write(dir, target, %Entry{op: :modify, path: path, mode: mode} = entry, images) do
    with :ok <- based(target, entry),
         :ok <- replace(dir, target, Map.fetch!(images, path), file_mode(mode)),
         do: written(target)
  end

  # The base's own file, and its only name: read only once lstat says it's
  # a regular file, so a FIFO or a symlink is never opened.
  defp based(target, %Entry{base_blob_sha: sha}) do
    with {:ok, %File.Stat{type: :regular, links: 1}} <- File.lstat(target),
         {:ok, bytes} <- File.read(target),
         true <- ChangeSet.blob_sha(bytes) == sha,
         do: :ok,
         else: (_moved_linked_or_changed -> :error)
  end

  defp written(target) do
    case File.lstat(target) do
      {:ok, %File.Stat{type: :regular, links: 1}} -> :ok
      _other -> :error
    end
  end

  # A new file renamed over the old one. It's made in the copy's root, which
  # is the host's own and on the same filesystem, so making or removing it
  # can't be redirected.
  # ponytail: a parent swapped for a symlink between the checks and the
  # rename still redirects the rename; only dirfd-relative calls (openat,
  # renameat, a NIF) close that. Nothing hostile can run meanwhile: the copy
  # is a fresh `cp -a` no sandbox has mounted, made once BUILD's container
  # is confirmed gone (`RsolvHost.Sandbox.stop_confirmed/2`).
  defp replace(dir, target, bytes, mode) do
    temp = Path.join(dir, ".rsolv-#{System.unique_integer([:positive])}.tmp")

    with {:error, _reason} = error <-
           with(:ok <- create(temp, bytes, mode), do: File.rename(temp, target)) do
      File.rm(temp)
      error
    end
  end

  defp create(path, bytes, mode) do
    with :ok <- File.write(path, bytes, [:exclusive]), do: File.chmod(path, mode)
  end

  defp file_mode("100755"), do: 0o755
  defp file_mode("100644"), do: 0o644

  # A delete's directories must exist; an add's are made as needed.
  defp parents(dir, %Entry{path: path, op: op}) do
    path
    |> BaseFacts.ancestors()
    |> Enum.reduce_while(:ok, fn relative, :ok ->
      full = Path.join(dir, relative)

      case {File.lstat(full), op} do
        {{:ok, %File.Stat{type: :directory}}, _op} -> {:cont, :ok}
        {{:error, :enoent}, op} when op != :delete -> {:cont, File.mkdir(full)}
        _unsafe -> {:halt, :error}
      end
    end)
  end
end
