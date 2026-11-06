defmodule RsolvCore.StrictJsonTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest RsolvCore.StrictJson

  alias RsolvCore.StrictJson

  describe "decode/2" do
    test "decodes a document with string keys" do
      assert StrictJson.decode(~s({"a":[1,{"b":null}],"c":"d"})) ==
               {:ok, %{"a" => [1, %{"b" => nil}], "c" => "d"}}
    end

    test "decodes a scalar document" do
      assert StrictJson.decode(" 42 ") == {:ok, 42}
    end
  end

  describe "decode/2 when an object repeats a member name" do
    test "refuses a duplicate kid" do
      assert StrictJson.decode(~s({"kid":"evil","kid":"test-2026-11"})) ==
               {:error, :duplicate_key}
    end

    test "refuses a duplicate member nested inside effects" do
      json = ~s({"decision":{"effects":{"pr_title":"a","labels":[],"pr_title":"b"}}})
      assert StrictJson.decode(json) == {:error, :duplicate_key}
    end

    test "refuses a duplicate spelled with an escape" do
      assert StrictJson.decode(~S({"kid":"a","kid":"b"})) == {:error, :duplicate_key}
    end

    test "refuses a duplicate inside an object in an array" do
      assert StrictJson.decode(~s([{"a":1},{"b":1,"b":2}])) == {:error, :duplicate_key}
    end

    test "accepts the same name in sibling objects" do
      assert {:ok, [%{"a" => 1}, %{"a" => 2}]} = StrictJson.decode(~s([{"a":1},{"a":2}]))
    end
  end

  describe "decode/2 when the document exceeds a limit" do
    test "refuses more bytes than :max_bytes" do
      assert StrictJson.decode(~s("abcdef"), max_bytes: 7) == {:error, :too_large}
    end

    test "accepts exactly :max_bytes" do
      assert StrictJson.decode(~s("abcde"), max_bytes: 7) == {:ok, "abcde"}
    end

    test "refuses a document over the default 1 MiB" do
      json = ~s(") <> String.duplicate("a", 1024 * 1024) <> ~s(")
      assert StrictJson.decode(json) == {:error, :too_large}
    end

    test "refuses nesting deeper than :max_depth" do
      assert StrictJson.decode("[[[1]]]", max_depth: 2) == {:error, :too_deep}
    end

    test "accepts nesting of exactly :max_depth" do
      assert StrictJson.decode(~s([{"a":1}]), max_depth: 2) == {:ok, [%{"a" => 1}]}
    end

    test "refuses nesting deeper than the default 32" do
      json = String.duplicate("[", 33) <> String.duplicate("]", 33)
      assert StrictJson.decode(json) == {:error, :too_deep}
    end

    test "refuses a number literal longer than 32 bytes" do
      assert StrictJson.decode(String.duplicate("9", 33)) == {:error, :too_large}
    end
  end

  describe "decode/2 when the input is not one JSON document" do
    test "refuses trailing bytes" do
      assert StrictJson.decode(~s({"a":1} x)) == {:error, :invalid_json}
    end

    test "refuses invalid UTF-8" do
      assert StrictJson.decode(<<?", 0xFF, ?">>) == {:error, :invalid_json}
    end

    test "refuses a float outside the double range" do
      assert StrictJson.decode("[1e400]") == {:error, :invalid_json}
    end

    test "refuses an empty document" do
      assert StrictJson.decode("") == {:error, :invalid_json}
    end

    test "refuses a non-binary" do
      assert StrictJson.decode(%{"a" => 1}) == {:error, :invalid_json}
    end
  end

  describe "decode/2 on arbitrary input" do
    property "returns a result for any binary, and never raises" do
      check all(bytes <- binary()) do
        assert match?({:ok, _}, StrictJson.decode(bytes)) or
                 match?({:error, _}, StrictJson.decode(bytes))
      end
    end

    property "agrees with JSON.decode/1 on documents without duplicates" do
      check all(
              value <-
                tree(
                  one_of([constant(nil), boolean(), integer(), string(:utf8)]),
                  &one_of([list_of(&1, max_length: 3), map_of(string(:utf8), &1, max_length: 3)])
                ),
              max_runs: 200
            ) do
        json = JSON.encode!(value)
        assert StrictJson.decode(json) == JSON.decode(json)
      end
    end
  end
end
