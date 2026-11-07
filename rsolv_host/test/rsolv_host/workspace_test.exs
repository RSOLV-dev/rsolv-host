defmodule RsolvHost.WorkspaceTest do
  use ExUnit.Case, async: true

  alias RsolvHost.{FakeExec, Workspace}

  @moduletag :tmp_dir

  describe "copy/3" do
    test "creates the destination and copies with cp -a, argv only", %{tmp_dir: dir} do
      FakeExec.script([])
      dest = Path.join(dir, "rsolv/work")

      assert Workspace.copy("/home/runner/work/repo", dest) == :ok
      assert File.dir?(dest)
      assert [{"cp", ["-a", "--", "/home/runner/work/repo/.", ^dest], _opts}] = FakeExec.calls()
    end

    test "when the destination already exists, refuses to reuse it", %{tmp_dir: dir} do
      FakeExec.script([])

      assert Workspace.copy("/src", dir) == {:error, :exists}
      assert FakeExec.calls() == []
    end

    test "when cp fails, the copy is a sandbox setup failure", %{tmp_dir: dir} do
      FakeExec.script([{fn {"cp", _, _} -> true end, {:ok, %{status: 1, output: "x"}}}])

      assert Workspace.copy("/src", Path.join(dir, "w")) == {:error, {:sandbox_setup, :copy}}
    end

    test "keeps a symlink a symlink instead of following it", %{tmp_dir: dir} do
      src = Path.join(dir, "src")
      File.mkdir_p!(src)
      File.write!(Path.join(dir, "outside"), "secret")
      File.ln_s!(Path.join(dir, "outside"), Path.join(src, "link"))

      assert Workspace.copy(src, Path.join(dir, "dest"), exec: RsolvHost.Exec) == :ok
      assert {:ok, %{type: :symlink}} = File.lstat(Path.join(dir, "dest/link"))
    end
  end
end
