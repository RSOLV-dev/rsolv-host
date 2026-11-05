defmodule RsolvCore.ChangeSet do
  @moduledoc """
  The canonical change set (RFC-150 §4.2): sorted entries of
  `{path, op, base_mode, base_blob_sha, mode, new_blob_sha}`.

  Paths are strictly increasing by byte order. Only regular files are allowed:
  an add is `100644`, a modify keeps its mode (`100644` or `100755`), and
  symlinks, gitlinks and paths into `.git` are refused.

      iex> RsolvCore.ChangeSet.blob_sha("hello world\\n")
      "3b18e512dba79e4c8300dd08aeb37f8e728b8dad"
  """

  alias RsolvCore.CanonicalJson

  defmodule Entry do
    @moduledoc "One file in a change set. See `RsolvCore.ChangeSet`."
    @enforce_keys [:path, :op, :base_mode, :base_blob_sha, :mode, :new_blob_sha]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            path: String.t(),
            op: :add | :modify | :delete,
            base_mode: String.t() | nil,
            base_blob_sha: String.t() | nil,
            mode: String.t() | nil,
            new_blob_sha: String.t() | nil
          }
  end

  @file_modes ["100644", "100755"]
  @max_path_bytes 4096

  @doc "The git blob SHA-1 of `bytes`, as `git hash-object` computes it."
  @spec blob_sha(binary()) :: String.t()
  def blob_sha(bytes) do
    :crypto.hash(:sha, ["blob ", Integer.to_string(byte_size(bytes)), 0, bytes])
    |> Base.encode16(case: :lower)
  end

  @doc "Decodes and validates a change set from its JSON form (a list of entry objects)."
  @spec from_json(term()) ::
          {:ok, [Entry.t()]}
          | {:error,
             :malformed_change_set | :invalid_path | :invalid_entry | :unsorted | :duplicate_path}
  def from_json(list) when is_list(list) do
    with {:ok, entries} <- entries(list, []),
         :ok <- sorted(entries) do
      {:ok, entries}
    end
  end

  def from_json(_other), do: {:error, :malformed_change_set}

  @doc "The JSON form of a change set, the inverse of `from_json/1`."
  @spec to_json([Entry.t()]) :: [map()]
  def to_json(entries) do
    Enum.map(entries, fn %Entry{} = entry ->
      %{
        "path" => entry.path,
        "op" => Atom.to_string(entry.op),
        "base_mode" => entry.base_mode,
        "base_blob_sha" => entry.base_blob_sha,
        "mode" => entry.mode,
        "new_blob_sha" => entry.new_blob_sha
      }
    end)
  end

  @doc ~s(The change-set digest: `"sha256:"` and the hex SHA-256 of its canonical JSON.)
  @spec digest([Entry.t()]) :: String.t()
  def digest(entries) do
    "sha256:" <>
      (entries
       |> to_json()
       |> CanonicalJson.encode!()
       |> then(&:crypto.hash(:sha256, &1))
       |> Base.encode16(case: :lower))
  end

  @doc """
  Whether `path` is a safe repository-relative file path: valid UTF-8, 1–4096
  bytes, no NUL or backslash, not absolute, and no empty, `.`, `..` or `.git`
  (in any case) segment.
  """
  @spec valid_path?(term()) :: boolean()
  def valid_path?(path) when is_binary(path) and byte_size(path) in 1..@max_path_bytes do
    String.valid?(path) and not String.contains?(path, [<<0>>, "\\"]) and
      path |> String.split("/") |> Enum.all?(&valid_segment?/1)
  end

  def valid_path?(_path), do: false

  defp valid_segment?(segment),
    do: segment not in ["", ".", ".."] and String.downcase(segment) != ".git"

  defp entries([], acc), do: {:ok, Enum.reverse(acc)}

  defp entries([json | rest], acc) do
    with {:ok, entry} <- entry(json), do: entries(rest, [entry | acc])
  end

  defp entry(
         %{
           "path" => path,
           "op" => op,
           "base_mode" => _,
           "base_blob_sha" => _,
           "mode" => _,
           "new_blob_sha" => _
         } = json
       )
       when map_size(json) == 6 and op in ~w(add modify delete) do
    if valid_path?(path), do: typed_entry(op, json), else: {:error, :invalid_path}
  end

  defp entry(_json), do: {:error, :malformed_change_set}

  defp typed_entry(
         "add",
         %{"base_mode" => nil, "base_blob_sha" => nil, "mode" => "100644", "new_blob_sha" => new} =
           json
       ),
       do: build(:add, json, sha?(new))

  defp typed_entry(
         "modify",
         %{"base_mode" => mode, "base_blob_sha" => base, "mode" => mode, "new_blob_sha" => new} =
           json
       )
       when mode in @file_modes,
       do: build(:modify, json, sha?(base) and sha?(new))

  defp typed_entry(
         "delete",
         %{"base_mode" => mode, "base_blob_sha" => base, "mode" => nil, "new_blob_sha" => nil} =
           json
       )
       when mode in @file_modes,
       do: build(:delete, json, sha?(base))

  defp typed_entry(_op, _json), do: {:error, :invalid_entry}

  defp build(op, json, true) do
    {:ok,
     %Entry{
       path: json["path"],
       op: op,
       base_mode: json["base_mode"],
       base_blob_sha: json["base_blob_sha"],
       mode: json["mode"],
       new_blob_sha: json["new_blob_sha"]
     }}
  end

  defp build(_op, _json, false), do: {:error, :invalid_entry}

  defp sha?(sha), do: is_binary(sha) and sha =~ ~r/\A[0-9a-f]{40}\z/

  defp sorted([%Entry{path: a}, %Entry{path: a} | _rest]), do: {:error, :duplicate_path}
  defp sorted([%Entry{path: a}, %Entry{path: b} | _rest]) when a > b, do: {:error, :unsorted}
  defp sorted([_first, second | rest]), do: sorted([second | rest])
  defp sorted(_zero_or_one), do: :ok
end
