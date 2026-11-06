defmodule RsolvCore.TextTest do
  use ExUnit.Case, async: true

  doctest RsolvCore.Text

  alias RsolvCore.Text

  describe "plain?/1" do
    for text <- ["", "a b", "café", " ", "​", "emoji \u{1F600}"] do
      test "accepts #{inspect(text)}" do
        assert Text.plain?(unquote(text))
      end
    end
  end

  describe "plain?/1 when the text holds a control character" do
    for code <- [0x00, 0x09, 0x0A, 0x0D, 0x1B, 0x1F, 0x7F, 0x80, 0x85, 0x9F] do
      test "refuses U+#{Integer.to_string(code, 16)}" do
        refute Text.plain?("a" <> <<unquote(code)::utf8>> <> "b")
      end
    end
  end

  describe "plain?/1 when the text holds a bidirectional control" do
    for code <- Enum.concat(0x202A..0x202E, 0x2066..0x2069) do
      test "refuses U+#{Integer.to_string(code, 16)}" do
        refute Text.plain?("a" <> <<unquote(code)::utf8>> <> "b")
      end
    end
  end

  describe "plain?/1 when the input is not valid text" do
    test "refuses invalid UTF-8" do
      refute Text.plain?(<<0xFF>>)
    end

    test "refuses a non-binary" do
      refute Text.plain?(:atom)
    end
  end
end
