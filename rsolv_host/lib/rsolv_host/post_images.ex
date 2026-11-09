defmodule RsolvHost.PostImages do
  @moduledoc """
  Post-images as the platform serves them (`{"files": {path: base64}}`),
  checked against a change set: exactly one per add and modify, each hashing
  to its `new_blob_sha`. The verify and publish roles share it.

      iex> entry = %RsolvCore.ChangeSet.Entry{path: "a.js", op: :add, base_mode: nil, base_blob_sha: nil, mode: "100644", new_blob_sha: RsolvCore.ChangeSet.blob_sha("x")}
      iex> RsolvHost.PostImages.checked(%{"a.js" => "eA=="}, [entry])
      {:ok, %{"a.js" => "x"}}
  """

  alias RsolvCore.ChangeSet

  @doc "The decoded images, path => bytes, or `{:error, :digest_mismatch}`."
  @spec checked(term(), [ChangeSet.Entry.t()]) ::
          {:ok, %{String.t() => binary()}} | {:error, :digest_mismatch}
  def checked(files, change_set) when is_map(files) do
    wanted =
      for %{op: op} = entry <- change_set,
          op != :delete,
          into: %{},
          do: {entry.path, entry.new_blob_sha}

    if Enum.sort(Map.keys(files)) == Enum.sort(Map.keys(wanted)),
      do: decode(files, wanted),
      else: {:error, :digest_mismatch}
  end

  def checked(_files, _change_set), do: {:error, :digest_mismatch}

  defp decode(files, wanted) do
    Enum.reduce_while(files, {:ok, %{}}, fn {path, encoded}, {:ok, acc} ->
      with true <- is_binary(encoded),
           {:ok, bytes} <- Base.decode64(encoded),
           true <- ChangeSet.blob_sha(bytes) == wanted[path] do
        {:cont, {:ok, Map.put(acc, path, bytes)}}
      else
        _mismatch -> {:halt, {:error, :digest_mismatch}}
      end
    end)
  end
end
