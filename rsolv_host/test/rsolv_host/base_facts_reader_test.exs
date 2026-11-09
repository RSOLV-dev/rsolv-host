defmodule RsolvHost.BaseFactsReaderTest do
  # Two tests set GIT_* variables in the host's own environment, so this
  # module runs after the async ones.
  use ExUnit.Case, async: false

  alias RsolvCore.{BaseFacts, ChangeSet}
  alias RsolvHost.{BaseFactsReader, Exec, FakeExec}

  @moduletag :tmp_dir
  @source "const a = 1;\n"
  @script "#!/bin/sh\necho hi\n"
  @root_attributes "*.js text eol=lf\n"
  @src_attributes "a.js -diff\n"

  # The git the tests build repositories with, kept away from the caller's own
  # configuration.
  defp git(dir, args) do
    env = [
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_AUTHOR_NAME", "t"},
      {"GIT_AUTHOR_EMAIL", "t@example.com"},
      {"GIT_COMMITTER_NAME", "t"},
      {"GIT_COMMITTER_EMAIL", "t@example.com"}
    ]

    {out, 0} = System.cmd("git", args, cd: dir, env: env, stderr_to_stdout: true)
    String.trim(out)
  end

  defp write(dir, path, bytes) do
    full = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, bytes)
  end

  defp commit(dir) do
    git(dir, ["add", "-A"])
    git(dir, ["commit", "-q", "-m", "c"])
    git(dir, ["rev-parse", "HEAD"])
  end

  # A checkout with a regular file, an executable, a symlink, a submodule and
  # two .gitattributes.
  defp checkout(dir) do
    co = Path.join(dir, "checkout")
    File.mkdir_p!(co)
    git(co, ["init", "-q"])
    write(co, "src/a.js", @source)
    write(co, "bin/run.sh", @script)
    File.chmod!(Path.join(co, "bin/run.sh"), 0o755)
    write(co, ".gitattributes", @root_attributes)
    write(co, "src/.gitattributes", @src_attributes)
    File.ln_s!("src", Path.join(co, "link"))
    git(co, ["add", "-A"])

    git(co, [
      "update-index",
      "--add",
      "--cacheinfo",
      "160000,#{String.duplicate("e", 40)},lib/sub"
    ])

    git(co, ["commit", "-q", "-m", "c"])
    {co, git(co, ["rev-parse", "HEAD"])}
  end

  defp read(co, base, paths), do: BaseFactsReader.read(co, base, paths, exec: Exec)

  describe "read/4" do
    test "reads each path and its ancestors from the base commit's objects", %{tmp_dir: dir} do
      {co, base} = checkout(dir)

      paths = [
        "bin/run.sh",
        "lib/sub/f.js",
        "link/x.js",
        "new/deep/f.js",
        "src/a.js",
        "src/new.js"
      ]

      assert {:ok, %BaseFacts{base_sha: ^base, paths: facts, attributes: attributes}} =
               read(co, base, paths)

      assert facts == %{
               "bin" => %{type: :tree},
               "bin/run.sh" => %{
                 type: :blob,
                 mode: "100755",
                 sha: ChangeSet.blob_sha(@script),
                 content: @script
               },
               "lib" => %{type: :tree},
               "lib/sub" => %{type: :commit},
               "lib/sub/f.js" => %{type: :missing},
               "link" => %{
                 type: :blob,
                 mode: "120000",
                 sha: ChangeSet.blob_sha("src"),
                 content: nil
               },
               "link/x.js" => %{type: :missing},
               "new" => %{type: :missing},
               "new/deep" => %{type: :missing},
               "new/deep/f.js" => %{type: :missing},
               "src" => %{type: :tree},
               "src/a.js" => %{
                 type: :blob,
                 mode: "100644",
                 sha: ChangeSet.blob_sha(@source),
                 content: @source
               },
               "src/new.js" => %{type: :missing}
             }

      assert attributes == %{"" => @root_attributes, "src" => @src_attributes}
    end

    test "produces base facts the platform's decoder accepts", %{tmp_dir: dir} do
      {co, base} = checkout(dir)
      paths = ["link/x.js", "src/a.js", "src/new.js"]

      {:ok, facts} = read(co, base, paths)
      json = facts |> BaseFacts.to_json() |> JSON.encode!() |> JSON.decode!()

      assert BaseFacts.decode(json, base, paths) == {:ok, facts}
    end

    test "reads the base commit, never the working tree", %{tmp_dir: dir} do
      {co, base} = checkout(dir)
      File.write!(Path.join(co, "src/a.js"), "tampered\n")
      File.rm!(Path.join(co, "src/.gitattributes"))
      File.rm!(Path.join(co, "link"))
      File.ln_s!("/etc", Path.join(co, "link"))

      assert {:ok, %BaseFacts{paths: facts, attributes: attributes}} =
               read(co, base, ["link/x.js", "src/a.js"])

      assert %{content: @source} = facts["src/a.js"]
      assert facts["link"].sha == ChangeSet.blob_sha("src")
      assert attributes["src"] == @src_attributes
    end

    test "runs nothing the repository's own config names", %{tmp_dir: dir} do
      {co, base} = checkout(dir)
      marker = Path.join(dir, "ran")
      hook = Path.join(dir, "hook.sh")
      File.write!(hook, "#!/bin/sh\ntouch #{marker}\n")
      File.chmod!(hook, 0o755)

      File.write!(Path.join(co, ".git/config"), """
      [core]
      \trepositoryformatversion = 0
      \tfsmonitor = #{hook}
      \thooksPath = #{dir}
      \tpager = #{hook}
      [alias]
      \tls-tree = !#{hook}
      """)

      File.cp!(hook, Path.join(dir, "post-checkout"))

      assert {:ok, %BaseFacts{}} = read(co, base, ["src/a.js"])
      refute File.exists?(marker)
    end

    test "ignores GIT_* variables in the host's environment", %{tmp_dir: dir} do
      {co, base} = checkout(dir)
      empty = Path.join(dir, "no-objects")
      File.mkdir_p!(empty)

      System.put_env(%{
        "GIT_DIR" => empty,
        "GIT_OBJECT_DIRECTORY" => empty,
        "GIT_CONFIG_PARAMETERS" => "'core.fsmonitor=false'"
      })

      on_exit(fn ->
        Enum.each(~w(GIT_DIR GIT_OBJECT_DIRECTORY GIT_CONFIG_PARAMETERS), &System.delete_env/1)
      end)

      assert {:ok, %BaseFacts{paths: %{"src/a.js" => %{content: @source}}}} =
               read(co, base, ["src/a.js"])
    end

    test "refuses a checkout that isn't at the base", %{tmp_dir: dir} do
      {co, base} = checkout(dir)
      write(co, "src/a.js", "next\n")
      commit(co)

      assert read(co, base, ["src/a.js"]) == {:error, :checkout_not_base}
    end

    test "refuses a checkout whose .git isn't a directory", %{tmp_dir: dir} do
      {co, base} = checkout(dir)
      File.rename!(Path.join(co, ".git"), Path.join(dir, "elsewhere.git"))
      File.ln_s!(Path.join(dir, "elsewhere.git"), Path.join(co, ".git"))

      assert read(co, base, ["src/a.js"]) == {:error, :checkout_not_base}
    end

    test "refuses a base file over 5 MiB, before reading it", %{tmp_dir: dir} do
      {co, _base} = checkout(dir)
      write(co, "big.txt", :binary.copy("x", 5 * 1024 * 1024 + 1))
      base = commit(co)

      assert read(co, base, ["big.txt"]) == {:error, :base_facts_too_large}
    end

    test "refuses base files that together can't fit the platform's 7 MiB of base facts",
         %{tmp_dir: dir} do
      {co, _base} = checkout(dir)
      write(co, "one.txt", :binary.copy("x", 3 * 1024 * 1024))
      write(co, "two.txt", :binary.copy("y", 3 * 1024 * 1024))
      base = commit(co)

      assert read(co, base, ["one.txt", "two.txt"]) == {:error, :base_facts_too_large}
    end

    for paths <- [["../x"], [".git/config"], ["a//b"], ["-rf"], ["src/a.js", 7], "src/a.js"] do
      test "refuses #{inspect(paths)} before any git or filesystem call" do
        FakeExec.script([])

        assert BaseFactsReader.read("/nonexistent", String.duplicate("b", 40), unquote(paths)) ==
                 {:error, :invalid_touched_paths}

        assert FakeExec.calls() == []
      end
    end
  end

  describe "read/4 with more touched paths than RsolvCore.BaseFacts allows" do
    for {label, paths, reason} <- [
          {"more than 4,096 paths with their directories", for(i <- 1..4_097, do: "f#{i}.js"),
           :too_many_touched_paths},
          {"a path deeper than 128 segments", [String.duplicate("d/", 128) <> "f.js"],
           :touched_path_too_deep}
        ] do
      test "refuses #{label}, before any git call, as a deterministic error (exit 2)" do
        FakeExec.script([])

        result =
          BaseFactsReader.read("/nonexistent", String.duplicate("b", 40), unquote(paths))

        assert result == {:error, unquote(reason)}
        assert RsolvHost.Outcome.exit_code(result) == 2
        assert FakeExec.calls() == []
      end
    end
  end

  describe "read/4's git" do
    setup %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, ".git"))
      %{base: String.duplicate("b", 40)}
    end

    defp scripted(base, listing, content) do
      FakeExec.script([
        {fn {"env", args, _} -> "rev-parse" in args end,
         {:ok, %{status: 0, output: base <> "\n"}}},
        {fn {"env", args, _} -> "ls-tree" in args end, {:ok, %{status: 0, output: listing}}},
        {fn {"env", args, _} -> "cat-file" in args end, {:ok, %{status: 0, output: content}}}
      ])
    end

    test "runs only through env -i, with hardened git and bounded output", %{
      tmp_dir: dir,
      base: base
    } do
      scripted(base, "100644 blob #{ChangeSet.blob_sha(@source)}      13\ta.js\0", @source)

      assert {:ok, %BaseFacts{}} = BaseFactsReader.read(dir, base, ["a.js"])

      calls = FakeExec.calls()
      assert length(calls) == 3

      for {"env", argv, opts} <- calls do
        assert ["-i" | args] = argv
        {env, [git | git_args]} = Enum.split_while(args, &(&1 =~ ~r/\A[A-Z_]+=/))

        assert Path.type(git) == :absolute and Path.basename(git) == "git"

        for var <-
              ~w(GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1
                 GIT_LITERAL_PATHSPECS=1 GIT_NO_LAZY_FETCH=1 GIT_ALLOW_PROTOCOL=none),
            do: assert(var in env)

        assert ["--git-dir=" <> git_dir | _] = git_args
        assert git_dir == Path.join(dir, ".git")

        for override <- ~w(core.fsmonitor=false core.hooksPath=/dev/null protocol.allow=never),
            do: assert(override in git_args)

        assert opts[:timeout_ms] > 0 and opts[:max_bytes] > 0
      end
    end

    test "reads a blob at most its listed size", %{tmp_dir: dir, base: base} do
      scripted(base, "100644 blob #{ChangeSet.blob_sha(@source)}      13\ta.js\0", @source)

      BaseFactsReader.read(dir, base, ["a.js"])

      assert [{_, _, opts}] =
               for({"env", args, _} = c <- FakeExec.calls(), "cat-file" in args, do: c)

      assert opts[:max_bytes] == 13
    end

    test "refuses content that doesn't hash to its tree entry", %{tmp_dir: dir, base: base} do
      scripted(base, "100644 blob #{String.duplicate("d", 40)}      13\ta.js\0", @source)

      assert BaseFactsReader.read(dir, base, ["a.js"]) == {:error, :base_read_failed}
    end

    test "refuses a listing it can't parse", %{tmp_dir: dir, base: base} do
      scripted(base, "warning: something\n100644 blob x 1\ta.js\0", @source)

      assert BaseFactsReader.read(dir, base, ["a.js"]) == {:error, :base_read_failed}
    end

    test "a directory listing over its cap is base facts too large (exit 2), not a failed read",
         %{tmp_dir: dir, base: base} do
      FakeExec.script([
        {fn {"env", args, _} -> "rev-parse" in args end,
         {:ok, %{status: 0, output: base <> "\n"}}},
        {fn {"env", args, _} -> "ls-tree" in args end, {:error, :output_too_large}}
      ])

      result = BaseFactsReader.read(dir, base, ["a.js"])

      assert result == {:error, :base_facts_too_large}
      assert RsolvHost.Outcome.exit_code(result) == 2
    end

    test "refuses a failed git", %{tmp_dir: dir, base: base} do
      FakeExec.script([
        {fn {"env", args, _} -> "rev-parse" in args end,
         {:ok, %{status: 0, output: base <> "\n"}}},
        {fn {"env", args, _} -> "ls-tree" in args end, {:ok, %{status: 128, output: "fatal"}}}
      ])

      assert BaseFactsReader.read(dir, base, ["a.js"]) == {:error, :base_read_failed}
    end
  end
end
