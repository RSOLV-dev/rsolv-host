defmodule RsolvCore.CanonicalJsonTest do
  use ExUnit.Case, async: true

  doctest RsolvCore.CanonicalJson

  alias RsolvCore.CanonicalJson

  @vectors __DIR__
           |> Path.join("../vectors/canonical_json.json")
           |> File.read!()
           |> JSON.decode!()

  describe "encode/1" do
    for %{"name" => name, "input" => input, "canonical" => canonical} <- @vectors do
      test "matches the #{name} vector" do
        value = JSON.decode!(unquote(input))
        assert CanonicalJson.encode(value) == {:ok, unquote(canonical)}
      end
    end
  end

  describe "encode/1 when the value is outside the canonical subset" do
    test "refuses a float" do
      assert CanonicalJson.encode(1.5) == {:error, :unsupported_value}
    end

    test "refuses an integer beyond 2^53 - 1" do
      assert CanonicalJson.encode(9_007_199_254_740_992) == {:error, :unsupported_value}
    end

    test "refuses an atom key" do
      assert CanonicalJson.encode(%{a: 1}) == {:error, :unsupported_value}
    end

    test "refuses invalid UTF-8" do
      assert CanonicalJson.encode(<<0xFF>>) == {:error, :unsupported_value}
    end

    test "refuses a struct" do
      assert CanonicalJson.encode(%URI{}) == {:error, :unsupported_value}
    end

    test "refuses an improper list" do
      assert CanonicalJson.encode([1 | 2]) == {:error, :unsupported_value}
    end

    test "refuses an improper list nested in an object" do
      assert CanonicalJson.encode(%{"a" => [1, 2 | "x"]}) == {:error, :unsupported_value}
    end
  end

  describe "encode!/1" do
    test "returns the canonical bytes" do
      assert CanonicalJson.encode!(%{"b" => 1, "a" => [true, nil]}) == ~s({"a":[true,null],"b":1})
    end

    for {label, value} <- [
          float: 1.5,
          too_large: 9_007_199_254_740_992,
          atom_key: Macro.escape(%{a: 1}),
          invalid_utf8: <<0xFF>>,
          struct: Macro.escape(%URI{})
        ] do
      test "raises ArgumentError on #{label}" do
        assert_raise ArgumentError, fn -> CanonicalJson.encode!(unquote(value)) end
      end
    end
  end
end
