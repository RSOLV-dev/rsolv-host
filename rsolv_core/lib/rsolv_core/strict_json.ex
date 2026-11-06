defmodule RsolvCore.StrictJson do
  @moduledoc """
  The JSON decoding boundary for everything that crosses the trust boundary:
  decision envelopes, key sets and relay event data.

  It is the built-in `JSON` decoder with three refusals added while the document
  is parsed, before any map is built:
  - a member name repeated within one object, at any depth, after unescaping
    (`"kid"` and `"k\\u0069d"` are the same name), as RFC 8785 §3.1 requires;
  - nesting deeper than `:max_depth` (default 32 objects or arrays);
  - more than `:max_bytes` bytes (default 1 MiB), or a number literal longer
    than 32 bytes, so no single number costs more than linear work.

  Keys stay strings; nothing becomes an atom.

      iex> RsolvCore.StrictJson.decode(~s({"a":1,"a":2}))
      {:error, :duplicate_key}
  """

  @default_max_bytes 1024 * 1024
  @default_max_depth 32
  @max_number_bytes 32

  @type error :: :invalid_json | :duplicate_key | :too_deep | :too_large

  @doc """
  Decodes exactly one JSON document. Options: `:max_bytes` and `:max_depth`.
  Never raises.
  """
  @spec decode(term(), max_bytes: pos_integer(), max_depth: pos_integer()) ::
          {:ok, term()} | {:error, error()}
  def decode(json, opts \\ [])

  def decode(json, opts) when is_binary(json) do
    max_depth = Keyword.get(opts, :max_depth, @default_max_depth)

    if byte_size(json) > Keyword.get(opts, :max_bytes, @default_max_bytes),
      do: {:error, :too_large},
      else: strict(json, max_depth)
  end

  def decode(_json, _opts), do: {:error, :invalid_json}

  defp strict(json, max_depth) do
    case JSON.decode(json, {0, nil}, decoders(max_depth)) do
      {value, _acc, ""} -> {:ok, value}
      _error_or_trailing_bytes -> {:error, :invalid_json}
    end
  catch
    reason when reason in [:duplicate_key, :too_deep, :too_large] -> {:error, reason}
  end

  # Each container's accumulator carries its own depth, so a nested start can
  # refuse before descending.
  defp decoders(max_depth) do
    [
      object_start: fn parent -> {deeper(parent, max_depth), %{}} end,
      object_push: fn key, value, {depth, members} ->
        if is_map_key(members, key), do: throw(:duplicate_key)
        {depth, Map.put(members, key, value)}
      end,
      object_finish: fn {_depth, members}, parent -> {members, parent} end,
      array_start: fn parent -> {deeper(parent, max_depth), []} end,
      array_push: fn value, {depth, items} -> {depth, [value | items]} end,
      array_finish: fn {_depth, items}, parent -> {Enum.reverse(items), parent} end,
      integer: &number(&1, :integer),
      float: &number(&1, :float)
    ]
  end

  defp deeper({depth, _items}, max_depth) when depth < max_depth, do: depth + 1
  defp deeper(_parent, _max_depth), do: throw(:too_deep)

  defp number(text, _kind) when byte_size(text) > @max_number_bytes, do: throw(:too_large)
  defp number(text, :integer), do: String.to_integer(text)
  defp number(text, :float), do: String.to_float(text)
end
