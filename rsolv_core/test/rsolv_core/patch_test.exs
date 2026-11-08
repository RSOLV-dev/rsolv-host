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

    test "refuses a blank line inside a hunk" do
      assert Patch.parse(modify("x.js", "@@ -1,2 +1,2 @@\n a\n\n")) == {:error, :malformed}
    end

    test "refuses bytes without a final newline" do
      assert Patch.parse("diff --git a/x b/x") == {:error, :malformed}
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
