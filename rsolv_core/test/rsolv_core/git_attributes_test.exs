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

    test "unquotes a C-quoted pattern as git does" do
      attrs = %{"" => ~s("odd name" filter=x\n)}
      assert GitAttributes.filtered?("src/odd name", attrs)
      refute GitAttributes.filtered?("src/a.js", attrs)
    end

    test "reads attributes glued to a quoted pattern's closing quote" do
      assert GitAttributes.filtered?("a", %{"" => ~s("a"filter=lfs\n)})
    end

    test "reads a lone [attr] as a pattern, not a macro" do
      assert GitAttributes.filtered?("t", %{"" => "[attr] filter=lfs\n"})
    end

    test "skips a byte order mark and splits on a carriage return, as git does" do
      assert GitAttributes.filtered?("a.bin", %{"" => "\uFEFF*.bin filter=lfs\n"})
      assert GitAttributes.filtered?("a.bin", %{"" => "*.bin\rfilter=lfs\n"})
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

    test "matches a POSIX class inside a bracket expression" do
      assert GitAttributes.filtered?("5", %{"" => "[[:digit:]] filter=lfs\n"})
    end

    test "reads a ] right after a negation as a member, not the end" do
      assert GitAttributes.filtered?("a", %{"" => "[!]] filter=lfs\n"})
    end

    test "reads a leading ] as a member, not the end" do
      assert GitAttributes.filtered?("]", %{"" => "[]] filter=lfs\n"})
    end

    test "ends a range at the character after the dash, even a [" do
      assert GitAttributes.filtered?("a]", %{"" => "[a-[:digit:]] filter=lfs\n"})
    end

    test "keeps an escaped ] inside a bracket expression" do
      assert GitAttributes.filtered?("x", %{"" => "[\\]x] filter=lfs\n"})
    end

    test "never matches through an unterminated bracket, as git doesn't" do
      refute GitAttributes.filtered?("[abc", %{"" => "[abc filter=lfs\n"})
    end

    test "is false with no attribute files" do
      refute GitAttributes.filtered?("src/a.js", %{})
    end
  end

  describe "compile/1 and filtered?/2 on macro graphs" do
    defp chain(n),
      do:
        Enum.map_join(1..n//1, &"[attr]m#{&1} m#{&1 - 1}\n") <>
          "[attr]m0 filter=lfs\n* m#{n}\n"

    test "follows a chain defined before the macro that sets filter" do
      assert GitAttributes.filtered?("a.txt", %{"" => chain(40)})
    end

    test "resolves macros once per attribute set, not once per path" do
      attributes = GitAttributes.compile(%{"" => chain(40) <> "*.js text\n"})

      {micros, results} =
        :timer.tc(fn ->
          for n <- 1..1_000, do: GitAttributes.filtered?("d/f#{n}.txt", attributes)
        end)

      assert Enum.all?(results)
      assert micros < 1_000_000
    end

    test "terminates on a cycle that never reaches filter" do
      refute GitAttributes.filtered?("a", %{"" => "[attr]a b\n[attr]b a\n* a\n"})
    end

    test "treats a chain deeper than the cap as filtering everything, quickly" do
      {micros, filtered?} =
        :timer.tc(fn -> GitAttributes.filtered?("a.txt", %{"" => chain(3_000)}) end)

      assert filtered?
      assert micros < 1_000_000
    end

    test "treats more macros than the cap as filtering everything" do
      text = Enum.map_join(1..5_000, &"[attr]m#{&1} text\n")
      assert GitAttributes.filtered?("a.js", %{"" => text})
    end

    test "treats more lines than the cap as filtering everything" do
      assert GitAttributes.filtered?("a.js", %{"" => :binary.copy("*.c text\n", 60_000)})
    end

    test "treats more filter lines than the cap as filtering everything" do
      text = Enum.map_join(1..2_000, &"*.x#{&1} filter=lfs\n")
      assert GitAttributes.filtered?("a.js", %{"" => text})
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
