defmodule RsolvCore.CanonicalJsonPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias RsolvCore.CanonicalJson

  @max_safe 9_007_199_254_740_991

  defp json do
    leaf =
      one_of([
        constant(nil),
        boolean(),
        integer(-@max_safe..@max_safe),
        string(:utf8)
      ])

    tree(leaf, fn child -> one_of([list_of(child), map_of(string(:utf8), child)]) end)
  end

  defp reshuffle(map) when is_map(map),
    do: map |> Enum.shuffle() |> Map.new(fn {key, value} -> {key, reshuffle(value)} end)

  defp reshuffle(list) when is_list(list), do: Enum.map(list, &reshuffle/1)
  defp reshuffle(scalar), do: scalar

  defp decode_ordered(json) do
    {value, [], ""} =
      JSON.decode(json, [],
        object_finish: fn acc, old_acc -> {{:object, Enum.reverse(acc)}, old_acc} end
      )

    value
  end

  defp objects({:object, members}),
    do: [Enum.map(members, &elem(&1, 0)) | Enum.flat_map(members, &objects(elem(&1, 1)))]

  defp objects(list) when is_list(list), do: Enum.flat_map(list, &objects/1)
  defp objects(_scalar), do: []

  defp utf16(key), do: :unicode.characters_to_binary(key, :utf8, {:utf16, :big})

  describe "encode!/1 on any value in the subset" do
    property "round-trips through a JSON parser" do
      check all(value <- json()) do
        assert value |> CanonicalJson.encode!() |> JSON.decode!() == value
      end
    end

    property "is idempotent" do
      check all(value <- json()) do
        canonical = CanonicalJson.encode!(value)
        assert canonical |> JSON.decode!() |> CanonicalJson.encode!() == canonical
      end
    end

    property "does not depend on the order maps were built in" do
      check all(value <- json()) do
        assert CanonicalJson.encode!(reshuffle(value)) == CanonicalJson.encode!(value)
      end
    end

    property "writes every object's keys in UTF-16 code-unit order" do
      check all(value <- json()) do
        for keys <- value |> CanonicalJson.encode!() |> decode_ordered() |> objects() do
          assert keys == Enum.sort_by(keys, &utf16/1)
        end
      end
    end
  end

  describe "encode/1 on arbitrary input" do
    property "returns valid UTF-8 or refuses a binary, and never raises" do
      check all(bytes <- binary()) do
        case CanonicalJson.encode(bytes) do
          {:ok, json} -> assert String.valid?(json)
          {:error, :unsupported_value} -> refute String.valid?(bytes)
        end
      end
    end

    property "returns a result for any term, and never raises" do
      check all(value <- term()) do
        assert match?({:ok, _json}, CanonicalJson.encode(value)) or
                 CanonicalJson.encode(value) == {:error, :unsupported_value}
      end
    end
  end
end
