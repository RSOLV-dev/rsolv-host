defmodule RsolvHost.Copies do
  @moduledoc """
  Writes a change set's post-images into a copy of the checkout (RFC-150 §5,
  acceptance 5b), before any sandbox has mounted it, so the checks can't be
  raced. Each path must pass `RsolvCore.ChangeSet.valid_path?/1`; every
  existing ancestor must be a real directory (`File.lstat/1`, never
  followed), and the file itself a regular file or absent, so nothing is
  written or deleted through a symlink, over a directory or beneath a file.
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
           :ok <- write(Path.join(dir, path), entry, images) do
        {:cont, :ok}
      else
        _unsafe -> {:halt, {:error, {:unsafe_path, path}}}
      end
    end)
  end

  defp write(target, %Entry{op: :delete}, _images) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(target), do: File.rm(target)
  end

  defp write(target, %Entry{path: path}, images) do
    with :ok <- writable(File.lstat(target)), do: File.write(target, Map.fetch!(images, path))
  end

  defp writable({:error, :enoent}), do: :ok
  defp writable({:ok, %File.Stat{type: :regular}}), do: :ok
  defp writable(_other), do: :error

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
