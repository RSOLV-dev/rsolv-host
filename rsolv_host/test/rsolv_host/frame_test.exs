defmodule RsolvHost.FrameTest do
  use ExUnit.Case, async: true

  alias RsolvHost.Frame

  describe "encode/1" do
    test "is the decimal byte length, a newline, then the JSON" do
      assert Frame.encode(%{"a" => 1}) == ~s(7\n{"a":1})
    end

    test "counts bytes, not characters" do
      assert Frame.encode(%{"a" => "é"}) == ~s(10\n{"a":"é"})
    end
  end

  describe "decode/2" do
    test "returns the term and the bytes after it" do
      assert Frame.decode(~s(7\n{"a":1}8\n), 100) == {:ok, %{"a" => 1}, "8\n"}
    end

    test "when the frame is partial, asks for more" do
      assert Frame.decode(~s(7\n{"a"), 100) == :more
      assert Frame.decode("7", 100) == :more
      assert Frame.decode("", 100) == :more
    end

    test "when the length exceeds the limit, refuses before reading the payload" do
      assert Frame.decode("101\n", 100) == {:error, :frame_too_large}
    end

    test "when the length line is not a decimal number, refuses it" do
      assert Frame.decode("x7\n{}", 100) == {:error, :bad_frame}
      assert Frame.decode("-1\n", 100) == {:error, :bad_frame}
      assert Frame.decode(String.duplicate("1", 21), 100) == {:error, :bad_frame}
    end

    test "when the payload is not JSON, refuses it" do
      assert Frame.decode("2\n{x", 100) == {:error, :bad_frame}
    end

    test "when the payload repeats a key, refuses it" do
      assert Frame.decode(~s(13\n{"a":1,"a":2}), 100) == {:error, :bad_frame}
    end
  end
end
