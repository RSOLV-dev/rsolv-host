defmodule RsolvCore.GitAttributesTest do
  use ExUnit.Case, async: true

  doctest RsolvCore.GitAttributes

  alias RsolvCore.GitAttributes

  describe "filtered?/2" do
    test "matches a basename pattern from the root" do
      assert GitAttributes.filtered?("a/b/logo.png", %{"" => "*.png filter=lfs -text\n"})
    end

    test "matches an anchored pattern relative to its own directory" do
      attrs = %{"assets" => "/big/** filter=lfs\n"}
      assert GitAttributes.filtered?("assets/big/x.bin", attrs)
      refute GitAttributes.filtered?("big/x.bin", attrs)
    end

    test "follows an [attr] macro that sets filter" do
      assert GitAttributes.filtered?("x.psd", %{
               "" => "[attr]lfs filter=lfs diff=lfs\n*.psd lfs\n"
             })
    end

    test "ignores an unset filter" do
      refute GitAttributes.filtered?("x.txt", %{"" => "*.txt -filter !filter text\n"})
    end

    test "treats a quoted pattern that sets filter as matching" do
      assert GitAttributes.filtered?("src/a.js", %{"" => ~s("odd name" filter=x\n)})
    end

    test "treats a bracket expression as any one character" do
      assert GitAttributes.filtered?("x.c", %{"" => "*.[ch] filter=x\n"})
    end

    test "treats a pathological pattern as matching" do
      assert GitAttributes.filtered?("src/a.js", %{
               "" => String.duplicate("**/", 10) <> "q filter=x\n"
             })
    end

    test "follows a macro the root defines into a subdirectory's file" do
      attrs = %{"" => "[attr]lfs filter=lfs\n", "src" => "*.bin lfs\n"}
      assert GitAttributes.filtered?("src/x.bin", attrs)
    end

    test "follows a macro defined through another macro" do
      assert GitAttributes.filtered?("x.psd", %{"" => "[attr]a filter=x\n[attr]b a\n*.psd b\n"})
    end

    test "treats a pattern that exhausts the regex engine as matching" do
      pattern = String.duplicate("*a", 12) <> "b"
      path = "b" <> String.duplicate("a", 2_000)
      assert GitAttributes.filtered?(path, %{"" => pattern <> " filter=x\n"})
    end

    test "is false with no attribute files" do
      refute GitAttributes.filtered?("src/a.js", %{})
    end
  end

  describe "filtered?/2 on arbitrary attribute bytes" do
    use ExUnitProperties

    property "never raises" do
      check all(
              text <- binary(max_length: 512),
              path <- member_of(["a.js", "src/a b/c.txt", "x"])
            ) do
        assert is_boolean(GitAttributes.filtered?(path, %{"" => text, "src" => text}))
      end
    end
  end
end
