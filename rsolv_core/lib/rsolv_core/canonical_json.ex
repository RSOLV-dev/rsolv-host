defmodule RsolvCore.CanonicalJson do
  @moduledoc """
  RFC 8785 (JCS) for the JSON subset RSOLV signs: maps with string keys, lists,
  UTF-8 strings, integers within ±(2^53 - 1), booleans and null. Floats are refused,
  so no ECMAScript number formatting is needed.

      iex> RsolvCore.CanonicalJson.encode(%{"b" => [1, nil], "a" => "é"})
      {:ok, ~s({"a":"é","b":[1,null]})}
  """

  @max_safe 9_007_199_254_740_991

  @doc "Encodes `value` canonically, or refuses it when it is outside the subset."
  @spec encode(term()) :: {:ok, binary()} | {:error, :unsupported_value}
  def encode(value) do
    {:ok, value |> enc() |> IO.iodata_to_binary()}
  catch
    :unsupported -> {:error, :unsupported_value}
  end

  @doc "Like `encode/1`, but raises `ArgumentError` on a value outside the subset."
  @spec encode!(term()) :: binary()
  def encode!(value) do
    case encode(value) do
      {:ok, json} ->
        json

      {:error, :unsupported_value} ->
        raise ArgumentError, "value is outside the canonical JSON subset"
    end
  end

  defp enc(nil), do: "null"
  defp enc(true), do: "true"
  defp enc(false), do: "false"
  defp enc(int) when is_integer(int) and abs(int) <= @max_safe, do: Integer.to_string(int)
  defp enc(string) when is_binary(string), do: string(string)

  defp enc(list) when is_list(list) do
    if List.improper?(list), do: throw(:unsupported)
    ["[", list |> Enum.map(&enc/1) |> Enum.intersperse(","), "]"]
  end

  defp enc(map) when is_map(map) and not is_struct(map) do
    members =
      map
      |> Enum.map(&member/1)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {_utf16, encoded} -> encoded end)

    ["{", Enum.intersperse(members, ","), "}"]
  end

  defp enc(_other), do: throw(:unsupported)

  # RFC 8785 §3.2.3: members sort by the UTF-16 code units of their names.
  defp member({key, value}) when is_binary(key) do
    encoded_key = string(key)
    {:unicode.characters_to_binary(key, :utf8, {:utf16, :big}), [encoded_key, ":", enc(value)]}
  end

  defp member(_atom_or_other_key), do: throw(:unsupported)

  defp string(s) do
    if String.valid?(s),
      do: [?", for(<<c::utf8 <- s>>, into: "", do: esc(c)), ?"],
      else: throw(:unsupported)
  end

  defp esc(?"), do: "\\\""
  defp esc(?\\), do: "\\\\"
  defp esc(?\b), do: "\\b"
  defp esc(?\f), do: "\\f"
  defp esc(?\n), do: "\\n"
  defp esc(?\r), do: "\\r"
  defp esc(?\t), do: "\\t"

  defp esc(c) when c < 0x20,
    do: "\\u" <> (c |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0"))

  defp esc(c), do: <<c::utf8>>
end
