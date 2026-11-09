defmodule RsolvHost.CopiesTest do
  use ExUnit.Case, async: true

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

  defp modify(path),
    do: %Entry{
      path: path,
      op: :modify,
      base_mode: "100755",
      base_blob_sha: "x",
      mode: "100755",
      new_blob_sha: "y"
    }

  defp delete(path),
    do: %Entry{
      path: path,
      op: :delete,
      base_mode: "100644",
      base_blob_sha: "x",
      mode: nil,
      new_blob_sha: nil
    }

  describe "write_images/3" do
    test "writes adds into new directories, rewrites modifies in place and removes deletes",
         %{tmp_dir: dir} do
      File.write!(Path.join(dir, "old.js"), "x")
      File.write!(Path.join(dir, "run.sh"), "old")
      File.chmod!(Path.join(dir, "run.sh"), 0o755)

      assert Copies.write_images(
               dir,
               [add("test/deep/a_test.js"), delete("old.js"), modify("run.sh")],
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

      assert Copies.write_images(copy, [modify("a.js")], %{"a.js" => "x"}) ==
               {:error, {:unsafe_path, "a.js"}}

      assert File.read!(target) == "keep"
    end

    test "replaces a hardlinked file with a new one, never writing through to the other link",
         %{tmp_dir: dir} do
      outside = Path.join(dir, "outside.js")
      copy = Path.join(dir, "copy")
      File.write!(outside, "keep")
      File.chmod!(outside, 0o755)
      File.mkdir_p!(copy)
      File.ln!(outside, Path.join(copy, "a.js"))

      assert Copies.write_images(copy, [modify("a.js")], %{"a.js" => "new"}) == :ok

      assert File.read!(outside) == "keep"
      assert File.read!(Path.join(copy, "a.js")) == "new"
      assert %File.Stat{links: 1, type: :regular} = File.lstat!(Path.join(copy, "a.js"))
      assert Bitwise.band(File.stat!(Path.join(copy, "a.js")).mode, 0o777) == 0o755
      assert File.ls!(copy) == ["a.js"]
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

      assert Copies.write_images(copy, [delete("link/old.js")], %{}) ==
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
