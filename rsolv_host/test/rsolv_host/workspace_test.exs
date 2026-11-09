defmodule RsolvHost.WorkspaceTest do
  use ExUnit.Case, async: true

  alias RsolvHost.{FakeExec, Workspace}

  @moduletag :tmp_dir

  defp git(dir, args) do
    env =
      [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}] ++
        for(var <- ~w(GIT_AUTHOR_NAME GIT_COMMITTER_NAME), do: {var, "t"}) ++
        for(var <- ~w(GIT_AUTHOR_EMAIL GIT_COMMITTER_EMAIL), do: {var, "t@example.com"})

    {out, 0} = System.cmd("git", ["-C", dir | args], env: env, stderr_to_stdout: true)
    String.trim(out)
  end

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

    test "gives the copy's .git a fixed config, and none of the checkout's credentials, hooks or info",
         %{tmp_dir: dir} do
      src = Path.join(dir, "src")
      File.mkdir_p!(src)
      File.write!(Path.join(src, "a.txt"), "a\n")
      git(src, ["init", "-q"])
      git(src, ["add", "-A"])
      git(src, ["commit", "-q", "-m", "base"])

      File.write!(
        Path.join(src, ".git/config"),
        """
        [http "https://github.com/"]
        \textraheader = AUTHORIZATION: basic eC1hY2Nlc3MtdG9rZW46c2VjcmV0
        [includeIf "gitdir:/"]
        \tpath = /tmp/creds.config
        """,
        [:append]
      )

      File.write!(Path.join(src, ".git/credentials"), "https://x:secret@github.com\n")
      File.write!(Path.join(src, ".git/index.lock"), "")
      File.write!(Path.join(src, ".git/refs/heads/main.lock"), "")
      File.mkdir_p!(Path.join(src, ".git/info"))
      File.write!(Path.join(src, ".git/info/attributes"), "* filter=x\n")
      File.write!(Path.join(src, ".git/hooks/post-checkout"), "#!/bin/sh\n")

      dest = Path.join(dir, "dest")
      assert Workspace.copy(src, dest, exec: RsolvHost.Exec) == :ok

      assert File.read!(Path.join(dest, ".git/config")) ==
               "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n"

      assert dest |> Path.join(".git") |> File.ls!() |> Enum.sort() ==
               ~w(HEAD config index objects refs)

      refute File.exists?(Path.join(dest, ".git/refs/heads/main.lock"))
      assert git(dest, ["log", "-1", "--format=%s"]) == "base"
      assert git(dest, ["status", "--porcelain"]) == ""
    end
  end
end
