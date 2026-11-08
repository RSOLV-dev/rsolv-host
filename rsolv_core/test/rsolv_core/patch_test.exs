defmodule RsolvCore.PatchTest do
  use ExUnit.Case, async: true

  doctest RsolvCore.Patch

  alias RsolvCore.Patch
  alias RsolvCore.Patch.FileDiff

  @z String.duplicate("0", 40)
  @a String.duplicate("a", 40)
  @b String.duplicate("b", 40)

  defp modify(path, hunk_lines) do
    "diff --git a/#{path} b/#{path}\nindex #{@a}..#{@b} 100644\n--- a/#{path}\n+++ b/#{path}\n" <>
      hunk_lines
  end

  describe "parse/1" do
    test "reads a modify with one hunk, keeping each line's newline flag" do
      patch = modify("lib/app.js", "@@ -1,2 +1,2 @@\n keep\n-eval(x)\n+safe(x)\n")

      assert {:ok, [%FileDiff{path: "lib/app.js", op: :modify, hunks: [hunk]}]} =
               Patch.parse(patch)

      assert hunk.old_start == 1 and hunk.old_count == 2

      assert hunk.lines == [
               {:context, "keep", true},
               {:del, "eval(x)", true},
               {:add, "safe(x)", true}
             ]
    end

    test "marks the line before a no-newline marker" do
      patch = modify("a.txt", "@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n")

      assert {:ok, [%{hunks: [%{lines: [{:del, "old", false}, {:add, "new", true}]}]}]} =
               Patch.parse(patch)
    end

    test "reads an empty added file, which has no ---/+++ lines" do
      patch =
        "diff --git a/t/empty.txt b/t/empty.txt\nnew file mode 100644\nindex #{@z}..e69de29bb2d1d6434b8b29ae775ad8c2e48c5391\n"

      assert {:ok, [%FileDiff{path: "t/empty.txt", op: :add, hunks: []}]} = Patch.parse(patch)
    end

    test "unquotes a C-quoted non-ASCII path" do
      patch =
        ~s(diff --git "a/caf\\303\\251.txt" "b/caf\\303\\251.txt"\nnew file mode 100644\nindex #{@z}..#{@b}\n--- /dev/null\n+++ "b/caf\\303\\251.txt"\n@@ -0,0 +1 @@\n+x\n)

      assert {:ok, [%FileDiff{path: "café.txt", op: :add}]} = Patch.parse(patch)
    end

    test "drops the tab git appends to a ---/+++ name with a space" do
      patch =
        "diff --git a/my file.txt b/my file.txt\nindex #{@a}..#{@b} 100644\n--- a/my file.txt\t\n+++ b/my file.txt\t\n@@ -1 +1 @@\n-a\n+b\n"

      assert {:ok, [%FileDiff{path: "my file.txt"}]} = Patch.parse(patch)
    end

    test "ignores what an index line claims" do
      lying =
        String.replace(modify("x.js", "@@ -1 +1 @@\n-a\n+b\n"), "#{@a}..#{@b}", "#{@b}..#{@a}")

      assert {:ok, [%FileDiff{path: "x.js", op: :modify}]} = Patch.parse(lying)
    end

    test "keeps both sides of each hunk header" do
      hunks = "@@ -1,2 +1,3 @@\n a\n+b\n c\n@@ -8,2 +9,2 @@\n d\n-e\n+f\n"

      assert {:ok, [%FileDiff{hunks: [first, second]}]} = Patch.parse(modify("x.js", hunks))
      assert %{old_start: 1, old_count: 2, new_start: 1, new_count: 3} = first
      assert %{old_start: 8, old_count: 2, new_start: 9, new_count: 2} = second
    end

    test "accepts exactly 200,000 lines" do
      header =
        "diff --git a/x b/x\nnew file mode 100644\nindex #{@z}..#{@b}\n--- /dev/null\n+++ b/x\n"

      added = 200_000 - 6
      patch = header <> "@@ -0,0 +1,#{added} @@\n" <> :binary.copy("+\n", added)

      assert {:ok, [%FileDiff{path: "x", op: :add}]} = Patch.parse(patch)
    end

    test "accepts git's zero-context hunks, whose empty sides start a line early" do
      # git diff -U0, inserting two lines after line 5 and deleting lines 8-9 of ten.
      hunks = "@@ -5,0 +6,2 @@\n+new1\n+new2\n@@ -8,2 +9,0 @@\n-8\n-9\n"
      assert {:ok, [%FileDiff{hunks: [_insert, _delete]}]} = Patch.parse(modify("f", hunks))
    end

    test "is empty for an empty patch" do
      assert Patch.parse("") == {:ok, []}
    end
  end

  describe "parse/1 when the patch is refused" do
    test "refuses a binary diff" do
      patch =
        "diff --git a/i.png b/i.png\nindex #{@a}..#{@b} 100644\nBinary files a/i.png and b/i.png differ\n"

      assert Patch.parse(patch) == {:error, :binary}
    end

    test "refuses a GIT binary patch" do
      patch =
        "diff --git a/i.png b/i.png\nindex #{@a}..#{@b} 100644\nGIT binary patch\nliteral 1\nIcmZpd0000\n\n"

      assert Patch.parse(patch) == {:error, :binary}
    end

    test "refuses a NUL byte in a hunk, which git would have called binary" do
      assert Patch.parse(modify("x.js", "@@ -1 +1 @@\n-a\n+b\0c\n")) == {:error, :binary}
    end

    test "refuses a mode change" do
      patch = "diff --git a/run.sh b/run.sh\nold mode 100644\nnew mode 100755\n"
      assert Patch.parse(patch) == {:error, :mode_change}
    end

    test "refuses a new executable" do
      patch =
        "diff --git a/run.sh b/run.sh\nnew file mode 100755\nindex #{@z}..#{@b}\n--- /dev/null\n+++ b/run.sh\n@@ -0,0 +1 @@\n+x\n"

      assert Patch.parse(patch) == {:error, :executable}
    end

    test "refuses a new symlink" do
      patch =
        "diff --git a/l b/l\nnew file mode 120000\nindex #{@z}..#{@b}\n--- /dev/null\n+++ b/l\n@@ -0,0 +1 @@\n+/etc/passwd\n\\ No newline at end of file\n"

      assert Patch.parse(patch) == {:error, :not_regular_file}
    end

    test "refuses a gitlink modification" do
      patch =
        "diff --git a/sub b/sub\nindex #{@a}..#{@b} 160000\n--- a/sub\n+++ b/sub\n@@ -1 +1 @@\n-Subproject commit #{@a}\n+Subproject commit #{@b}\n"

      assert Patch.parse(patch) == {:error, :not_regular_file}
    end

    test "refuses rename and copy headers" do
      assert Patch.parse("diff --git a/x b/x\nsimilarity index 100%\nrename from x\n") ==
               {:error, :rename}

      assert Patch.parse("diff --git a/x b/x\ncopy from x\n") == {:error, :rename}
    end

    test "refuses header names that differ (a rename without --no-renames)" do
      assert Patch.parse("diff --git a/x b/y\nsimilarity index 100%\n") == {:error, :invalid_path}
    end

    test "refuses traversal" do
      assert Patch.parse(modify("../etc/passwd", "@@ -1 +1 @@\n-a\n+b\n")) ==
               {:error, :invalid_path}
    end

    test "refuses a path into .git in any case" do
      assert Patch.parse(modify(".GIT/config", "@@ -1 +1 @@\n-a\n+b\n")) ==
               {:error, :invalid_path}
    end

    test "refuses ---/+++ names that disagree with the header" do
      patch =
        "diff --git a/x.js b/x.js\nindex #{@a}..#{@b} 100644\n--- a/x.js\n+++ b/y.js\n@@ -1 +1 @@\n-a\n+b\n"

      assert Patch.parse(patch) == {:error, :invalid_path}
    end

    test "refuses the same path twice" do
      one = modify("x.js", "@@ -1 +1 @@\n-a\n+b\n")
      assert Patch.parse(one <> one) == {:error, :duplicate_path}
    end

    test "refuses a hunk whose line counts don't match its header" do
      assert Patch.parse(modify("x.js", "@@ -1,2 +1 @@\n-a\n+b\n")) == {:error, :malformed}
    end

    test "refuses a hunk with no lines" do
      assert Patch.parse(modify("x.js", "@@ -1,0 +1,0 @@\n@@ -1 +1 @@\n-a\n+b\n")) ==
               {:error, :malformed}
    end

    test "refuses a blank line inside a hunk" do
      assert Patch.parse(modify("x.js", "@@ -1,2 +1,2 @@\n a\n\n")) == {:error, :malformed}
    end

    test "refuses bytes without a final newline" do
      assert Patch.parse("diff --git a/x b/x") == {:error, :malformed}
    end

    test "refuses more than 200,000 lines, however few bytes they hold" do
      assert Patch.parse(:binary.copy("+\n", 200_001)) == {:error, :too_large}
    end

    test "refuses a new side that starts at line 0 but isn't empty" do
      patch =
        "diff --git a/x b/x\nnew file mode 100644\nindex #{@z}..#{@b}\n--- /dev/null\n+++ b/x\n" <>
          "@@ -0,0 +0,1 @@\n+a\n"

      assert Patch.parse(patch) == {:error, :malformed}
    end

    test "refuses an old side that starts at line 0 but isn't empty" do
      assert Patch.parse(modify("x.js", "@@ -0,1 +1 @@\n-a\n+b\n")) == {:error, :malformed}
    end

    test "refuses a first hunk whose new start isn't its old start" do
      assert Patch.parse(modify("x.js", "@@ -1 +2 @@\n-a\n+b\n")) == {:error, :malformed}
    end

    test "refuses a hunk whose new start ignores the lines earlier hunks added" do
      hunks = "@@ -1,2 +1,3 @@\n a\n+b\n c\n@@ -8,2 +8,2 @@\n d\n-e\n+f\n"
      assert Patch.parse(modify("x.js", hunks)) == {:error, :malformed}
    end

    test "refuses a backslash line other than git's no-newline marker" do
      assert Patch.parse(modify("x.js", "@@ -1 +1 @@\n-a\n\\ garbage\n+b\n")) ==
               {:error, :malformed}
    end

    test "refuses text glued to a hunk header's closing @@" do
      assert Patch.parse(modify("x.js", "@@ -1 +1 @@x\n-a\n+b\n")) == {:error, :malformed}
    end

    test "keeps the function context git writes after a hunk header" do
      assert {:ok, [%FileDiff{hunks: [_hunk]}]} =
               Patch.parse(modify("x.js", "@@ -1 +1 @@ function f() {\n-a\n+b\n"))
    end

    test "refuses more than 8 MiB" do
      assert Patch.parse(:binary.copy("x", 8 * 1024 * 1024 + 1)) == {:error, :too_large}
    end
  end

  describe "touched_paths/1" do
    test "lists each diff's path, sorted by bytes" do
      diffs = [
        %FileDiff{path: "b", op: :add, hunks: []},
        %FileDiff{path: "a", op: :add, hunks: []}
      ]

      assert Patch.touched_paths(diffs) == ["a", "b"]
    end
  end
end
