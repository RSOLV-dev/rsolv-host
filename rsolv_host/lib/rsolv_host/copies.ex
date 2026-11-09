defmodule RsolvHost.Copies do
  @moduledoc """
  Writes a change set's post-images into a copy of the checkout (RFC-150 §5,
  acceptance 5b), before any sandbox has mounted it, so the checks can't be
  raced. Each path must pass `RsolvCore.ChangeSet.valid_path?/1`; every
  existing ancestor must be a real directory (`File.lstat/1`, never
  followed), and the file itself a regular file or absent, so nothing is
  written or deleted through a symlink, over a directory or beneath a file.
  An add creates its file `O_EXCL`; a modify writes a new file in the copy's
  root and renames it into place, so a hardlink to a file outside the
  copy is replaced, never written through. Either is then checked again
  with `File.lstat/1`.
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

  defp write(_dir, target, %Entry{op: :delete}, _images) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(target), do: File.rm(target)
  end

  defp write(dir, target, %Entry{path: path, mode: mode}, images) do
    bytes = Map.fetch!(images, path)

    with :ok <- replace(File.lstat(target), dir, target, bytes, file_mode(mode)),
         {:ok, %File.Stat{type: :regular, links: 1}} <- File.lstat(target),
         do: :ok
  end

  # O_EXCL: nothing already at the path is followed or reused.
  defp replace({:error, :enoent}, _dir, target, bytes, mode), do: create(target, bytes, mode)

  # A new file renamed over the old one, so a hardlink is never written
  # through. It's made in the copy's root, which is the host's own and on
  # the same filesystem, so making or removing it can't be redirected.
  # ponytail: a parent swapped for a symlink between the checks and the
  # rename still redirects the rename; only dirfd-relative calls (openat,
  # renameat, a NIF) close that, and no hostile process runs on the host
  # before the first sandbox.
  defp replace({:ok, %File.Stat{type: :regular}}, dir, target, bytes, mode) do
    temp = Path.join(dir, ".rsolv-#{System.unique_integer([:positive])}.tmp")

    with {:error, _reason} = error <-
           with(:ok <- create(temp, bytes, mode), do: File.rename(temp, target)) do
      File.rm(temp)
      error
    end
  end

  defp replace(_other, _dir, _target, _bytes, _mode), do: :error

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
