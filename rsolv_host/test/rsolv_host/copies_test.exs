defmodule RsolvHost.CopiesTest do
  use ExUnit.Case, async: true

  alias RsolvCore.ChangeSet
  alias RsolvCore.ChangeSet.Entry
  alias RsolvHost.Copies

  @moduletag :tmp_dir

  defp add(path),
    do: %Entry{
      path: path,
      op: :add,
      base_mode: nil,
      base_blob_sha: nil,
      mode: "100644",
      new_blob_sha: "x"
    }

  # `base`: the bytes the base holds at `path`.
  defp modify(path, base),
    do: %Entry{
      path: path,
      op: :modify,
      base_mode: "100755",
      base_blob_sha: ChangeSet.blob_sha(base),
      mode: "100755",
      new_blob_sha: "y"
    }

  defp delete(path, base),
    do: %Entry{
      path: path,
      op: :delete,
      base_mode: "100644",
      base_blob_sha: ChangeSet.blob_sha(base),
      mode: nil,
      new_blob_sha: nil
    }

  def entry(:modify, path, base), do: modify(path, base)
  def entry(:delete, path, base), do: delete(path, base)

  describe "write_images/3" do
    test "writes adds into new directories, rewrites modifies in place and removes deletes",
         %{tmp_dir: dir} do
      File.write!(Path.join(dir, "old.js"), "x")
      File.write!(Path.join(dir, "run.sh"), "old")
      File.chmod!(Path.join(dir, "run.sh"), 0o755)

      assert Copies.write_images(
               dir,
               [add("test/deep/a_test.js"), delete("old.js", "x"), modify("run.sh", "old")],
               %{
                 "test/deep/a_test.js" => "t\n",
                 "run.sh" => "new"
               }
             ) == :ok

      assert File.read!(Path.join(dir, "test/deep/a_test.js")) == "t\n"
      refute File.exists?(Path.join(dir, "old.js"))
      assert File.read!(Path.join(dir, "run.sh")) == "new"
      assert Bitwise.band(File.stat!(Path.join(dir, "run.sh")).mode, 0o111) != 0
    end

    test "refuses to write through a symlinked parent (acceptance 5b)", %{tmp_dir: dir} do
      outside = Path.join(dir, "outside")
      copy = Path.join(dir, "copy")
      File.mkdir_p!(outside)
      File.mkdir_p!(copy)
      File.ln_s!(outside, Path.join(copy, "link"))

      assert Copies.write_images(copy, [add("link/x.js")], %{"link/x.js" => "pwned"}) ==
               {:error, {:unsafe_path, "link/x.js"}}

      assert File.ls!(outside) == []
    end

    test "refuses to write through a symlink", %{tmp_dir: dir} do
      target = Path.join(dir, "target")
      copy = Path.join(dir, "copy")
      File.write!(target, "keep")
      File.mkdir_p!(copy)
      File.ln_s!(target, Path.join(copy, "a.js"))

      assert Copies.write_images(copy, [modify("a.js", "keep")], %{"a.js" => "x"}) ==
               {:error, {:unsafe_path, "a.js"}}

      assert File.read!(target) == "keep"
    end

    defp sha256(path), do: :crypto.hash(:sha256, File.read!(path))

    test "refuses to modify a file with another link, before writing anything (B4)",
         %{tmp_dir: dir} do
      a = Path.join(dir, "a.rb")
      b = Path.join(dir, "b.rb")
      File.write!(a, "base\n")
      File.ln!(a, b)
      before = {sha256(a), sha256(b)}

      assert Copies.write_images(dir, [modify("a.rb", "base\n")], %{"a.rb" => "fixed\n"}) ==
               {:error, {:unsafe_path, "a.rb"}}

      assert {sha256(a), sha256(b)} == before
      assert File.ls!(dir) |> Enum.sort() == ["a.rb", "b.rb"]
    end

    test "refuses to delete a file with another link", %{tmp_dir: dir} do
      a = Path.join(dir, "a.rb")
      File.write!(a, "base\n")
      File.ln!(a, Path.join(dir, "b.rb"))

      assert Copies.write_images(dir, [delete("a.rb", "base\n")], %{}) ==
               {:error, {:unsafe_path, "a.rb"}}

      assert File.read!(a) == "base\n"
    end

    test "with a byte copy, not a link, changes only the overlaid file", %{tmp_dir: dir} do
      a = Path.join(dir, "a.rb")
      b = Path.join(dir, "b.rb")
      File.write!(a, "base\n")
      File.cp!(a, b)
      b_before = sha256(b)

      assert Copies.write_images(dir, [modify("a.rb", "base\n")], %{"a.rb" => "fixed\n"}) == :ok

      assert File.read!(a) == "fixed\n"
      assert sha256(b) == b_before
    end

    for op <- [:modify, :delete] do
      test "refuses to #{op} a file that no longer holds its base blob", %{tmp_dir: dir} do
        a = Path.join(dir, "a.rb")
        File.write!(a, "changed during BUILD\n")
        entry = apply(__MODULE__, :entry, [unquote(op), "a.rb", "base\n"])

        assert Copies.write_images(dir, [entry], %{"a.rb" => "fixed\n"}) ==
                 {:error, {:unsafe_path, "a.rb"}}

        assert File.read!(a) == "changed during BUILD\n"
      end
    end

    test "refuses an add over anything already there", %{tmp_dir: dir} do
      outside = Path.join(dir, "outside")
      File.write!(outside, "keep")
      copy = Path.join(dir, "copy")
      File.mkdir_p!(Path.join(copy, "dir.rb"))
      File.write!(Path.join(copy, "file.rb"), "keep")
      File.ln_s!(outside, Path.join(copy, "link.rb"))
      {_out, 0} = System.cmd("mkfifo", [Path.join(copy, "fifo.rb")])

      for path <- ~w(file.rb dir.rb link.rb fifo.rb) do
        assert Copies.write_images(copy, [add(path)], %{path => "x"}) ==
                 {:error, {:unsafe_path, path}},
               path
      end

      assert File.read!(Path.join(copy, "file.rb")) == "keep"
      assert File.read!(outside) == "keep"
      assert File.dir?(Path.join(copy, "dir.rb"))
      assert File.lstat!(Path.join(copy, "fifo.rb")).type == :other
    end

    test "gives an add its mode", %{tmp_dir: dir} do
      assert Copies.write_images(dir, [add("a.js")], %{"a.js" => "x"}) == :ok
      assert Bitwise.band(File.stat!(Path.join(dir, "a.js")).mode, 0o777) == 0o644
    end

    test "refuses to delete through a symlinked parent", %{tmp_dir: dir} do
      outside = Path.join(dir, "outside")
      copy = Path.join(dir, "copy")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "old.js"), "keep")
      File.mkdir_p!(copy)
      File.ln_s!(outside, Path.join(copy, "link"))

      assert Copies.write_images(copy, [delete("link/old.js", "keep")], %{}) ==
               {:error, {:unsafe_path, "link/old.js"}}

      assert File.read!(Path.join(outside, "old.js")) == "keep"
    end

    test "refuses to write over a directory, or beneath a file", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "d"))
      File.write!(Path.join(dir, "f"), "x")

      assert Copies.write_images(dir, [add("d")], %{"d" => "x"}) == {:error, {:unsafe_path, "d"}}

      assert Copies.write_images(dir, [add("f/x.js")], %{"f/x.js" => "x"}) ==
               {:error, {:unsafe_path, "f/x.js"}}
    end

    test "refuses a path that isn't a safe repository path", %{tmp_dir: dir} do
      copy = Path.join(dir, "copy")
      File.mkdir_p!(copy)

      for path <- ["../escape.js", ".git/config", "/abs.js"] do
        assert Copies.write_images(copy, [add(path)], %{path => "x"}) ==
                 {:error, {:unsafe_path, path}}
      end

      assert File.ls!(dir) == ["copy"]
    end
  end
end
