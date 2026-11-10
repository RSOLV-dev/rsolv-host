defmodule RsolvHost.GitTreeTest do
  use ExUnit.Case, async: true

  alias RsolvCore.ChangeSet
  alias RsolvCore.ChangeSet.Entry
  alias RsolvHost.{FakeGithub, GitHub, GitTree}

  setup do
    agent = FakeGithub.start()

    base =
      FakeGithub.seed(agent, %{
        "gradlew" => {"100755", "#!/bin/sh\n"},
        "lib/app.rb" => {"100644", "puts 1\n"},
        "lib/util.rb" => {"100644", "u\n"},
        "README" => {"100644", "r\n"},
        "link" => {"120000", "lib"}
      })

    {:ok, gh} = GitHub.new(%{"GITHUB_TOKEN" => "ghs_test", "GITHUB_REPOSITORY" => "acme/app"})
    {:ok, %{"tree" => %{"sha" => tree}}} = GitHub.get_commit(gh, base)
    %{agent: agent, gh: gh, base: base, tree: tree}
  end

  defp tree_gets(agent),
    do: Enum.count(FakeGithub.requests(agent), &match?({"GET", "/git/trees/" <> _}, &1))

  defp add(path, bytes),
    do: %Entry{
      path: path,
      op: :add,
      base_mode: nil,
      base_blob_sha: nil,
      mode: "100644",
      new_blob_sha: ChangeSet.blob_sha(bytes)
    }

  defp modify(path, mode, old, new),
    do: %Entry{
      path: path,
      op: :modify,
      base_mode: mode,
      base_blob_sha: ChangeSet.blob_sha(old),
      mode: mode,
      new_blob_sha: ChangeSet.blob_sha(new)
    }

  defp delete(path, mode, old),
    do: %Entry{
      path: path,
      op: :delete,
      base_mode: mode,
      base_blob_sha: ChangeSet.blob_sha(old),
      mode: nil,
      new_blob_sha: nil
    }

  # A check over `commit`'s tree, from an empty cache.
  defp check(fun, gh, commit, items) do
    {:ok, tree} = GitTree.tree(gh, commit)
    with {:ok, _cache} <- apply(GitTree, fun, [gh, tree, items, %{}]), do: :ok
  end

  describe "lookup/4" do
    test "finds a nested file, reading one tree per directory", %{
      agent: agent,
      gh: gh,
      tree: tree
    } do
      assert {:ok, %{mode: "100644", type: "blob", sha: sha}, cache} =
               GitTree.lookup(gh, tree, "lib/app.rb", %{})

      assert sha == ChangeSet.blob_sha("puts 1\n")
      assert {:ok, %{sha: _}, _cache} = GitTree.lookup(gh, tree, "lib/util.rb", cache)

      assert tree_gets(agent) == 2
    end

    test "reports an absent path", %{gh: gh, tree: tree} do
      assert {:absent, _cache} = GitTree.lookup(gh, tree, "lib/new.rb", %{})
      assert {:absent, _cache} = GitTree.lookup(gh, tree, "src/new.rb", %{})
    end

    test "refuses to look through a blob or a symlink", %{gh: gh, tree: tree} do
      assert GitTree.lookup(gh, tree, "README/x", %{}) == {:error, :ancestor_not_tree}
      assert GitTree.lookup(gh, tree, "link/app.rb", %{}) == {:error, :ancestor_not_tree}
    end

    test "reads at most max_tree_reads/0 trees through one cache", %{gh: gh, tree: tree} do
      full = Map.new(1..GitTree.max_tree_reads(), &{"#{&1}", []})
      one_short = Map.delete(full, "1")

      assert GitTree.lookup(gh, tree, "README", full) == {:error, :base_check_too_large}
      assert {:ok, %{type: "blob"}, _cache} = GitTree.lookup(gh, tree, "README", one_short)
    end

    test "reads no tree it has cached, even with the cache full", %{gh: gh, tree: tree} do
      {:ok, _found, cache} = GitTree.lookup(gh, tree, "README", %{})
      full = Map.merge(Map.new(2..GitTree.max_tree_reads(), &{"#{&1}", []}), cache)

      assert {:ok, %{type: "blob"}, ^full} = GitTree.lookup(gh, tree, "README", full)
    end

    test "refuses a truncated listing", %{agent: agent, gh: gh, tree: tree} do
      FakeGithub.truncate(agent)

      assert GitTree.lookup(gh, tree, "README", %{}) == {:error, :truncated}
    end
  end

  describe "check_base/4" do
    test "accepts adds of absent paths and modifies and deletes of what's there", %{
      gh: gh,
      base: base
    } do
      entries = [
        delete("README", "100644", "r\n"),
        modify("gradlew", "100755", "#!/bin/sh\n", "#!/bin/sh\nset -e\n"),
        add("lib/app_test.rb", "t\n"),
        modify("lib/app.rb", "100644", "puts 1\n", "puts 2\n")
      ]

      assert check(:check_base, gh, base, entries) == :ok
    end

    test "refuses an add of a path that exists", %{gh: gh, base: base} do
      assert check(:check_base, gh, base, [add("README", "x")]) ==
               {:error, {:base_mismatch, "README"}}
    end

    test "refuses a modify whose base blob or mode differs", %{gh: gh, base: base} do
      assert check(:check_base, gh, base, [modify("lib/app.rb", "100644", "other\n", "x")]) ==
               {:error, {:base_mismatch, "lib/app.rb"}}

      assert check(:check_base, gh, base, [modify("gradlew", "100644", "#!/bin/sh\n", "x")]) ==
               {:error, {:base_mismatch, "gradlew"}}
    end

    test "refuses a modify or delete of an absent path", %{gh: gh, base: base} do
      assert check(:check_base, gh, base, [delete("gone", "100644", "x")]) ==
               {:error, {:base_mismatch, "gone"}}
    end

    test "refuses a path under a symlinked directory", %{gh: gh, base: base} do
      assert check(:check_base, gh, base, [add("link/evil.rb", "x")]) ==
               {:error, {:base_mismatch, "link/evil.rb"}}
    end
  end

  describe "one cache across the checks" do
    test "check_base and check_attributes read each tree once", %{
      agent: agent,
      gh: gh,
      tree: tree
    } do
      attributes = [%{"dir" => "", "blob_sha" => nil}, %{"dir" => "lib", "blob_sha" => nil}]
      gets = tree_gets(agent)

      assert {:ok, cache} =
               GitTree.check_base(
                 gh,
                 tree,
                 [modify("lib/app.rb", "100644", "puts 1\n", "x")],
                 %{}
               )

      assert {:ok, ^cache} = GitTree.check_attributes(gh, tree, attributes, cache)
      assert tree_gets(agent) - gets == 2
    end
  end

  describe "within_budget/2" do
    defp adds(paths), do: for(path <- paths, do: add(path, "x"))

    # Base and fix trees: 2 x (the root and 98 directories); RED: the root and d1.
    test "admits a change set whose checks read at most max_tree_reads/0 trees" do
      paths = for n <- 1..98, do: "d#{n}/f"
      assert GitTree.max_tree_reads() == 200
      assert GitTree.within_budget(adds(paths), ["d1/f"]) == :ok
    end

    test "refuses one whose checks could read more" do
      paths = for n <- 1..99, do: "d#{n}/f"
      assert GitTree.within_budget(adds(paths), ["d1/f"]) == {:error, :base_check_too_large}
    end
  end

  describe "check_attributes/4" do
    setup %{agent: agent} do
      base =
        FakeGithub.seed(agent, %{
          ".gitattributes" => {"100644", "* text=auto\n"},
          "lib/.gitattributes" => {"100755", "*.rb text\n"},
          "lib/app.rb" => {"100644", "puts 1\n"},
          "bin/.gitattributes" => {"120000", "../.gitattributes"},
          "bin/run" => {"100755", "#!/bin/sh\n"},
          "doc/.gitattributes/x" => {"100644", "x\n"},
          "doc/a.md" => {"100644", "a\n"},
          "src/main.rb" => {"100644", "m\n"}
        })

      %{attributes_base: base}
    end

    defp attribute(dir, sha \\ nil), do: %{"dir" => dir, "blob_sha" => sha}

    test "accepts each file with its blob, and none where there is none or no directory",
         %{agent: agent, gh: gh, attributes_base: base} do
      attributes = [
        attribute("", ChangeSet.blob_sha("* text=auto\n")),
        attribute("lib", ChangeSet.blob_sha("*.rb text\n")),
        attribute("new"),
        attribute("src")
      ]

      gets = tree_gets(agent)
      assert check(:check_attributes, gh, base, attributes) == :ok
      assert tree_gets(agent) - gets == 3
    end

    test "accepts none where a symlink or a directory is named .gitattributes",
         %{gh: gh, attributes_base: base} do
      assert check(:check_attributes, gh, base, [attribute("bin"), attribute("doc")]) == :ok
    end

    test "refuses none where there is a file", %{gh: gh, attributes_base: base} do
      assert check(:check_attributes, gh, base, [attribute("lib")]) ==
               {:error, {:attributes_mismatch, "lib"}}
    end

    test "refuses a blob that differs", %{gh: gh, attributes_base: base} do
      assert check(:check_attributes, gh, base, [attribute("", ChangeSet.blob_sha("*\n"))]) ==
               {:error, {:attributes_mismatch, ""}}
    end

    for dir <- ["src", "new", "bin", "doc"] do
      test "refuses a file where #{dir}/.gitattributes isn't one", %{
        gh: gh,
        attributes_base: base
      } do
        sha = ChangeSet.blob_sha("../.gitattributes")

        assert check(:check_attributes, gh, base, [attribute(unquote(dir), sha)]) ==
                 {:error, {:attributes_mismatch, unquote(dir)}}
      end
    end

    # GitHub answering the root tree with `entry` named .gitattributes.
    defp root_entry(entry) do
      tree = String.duplicate("e", 40)

      Req.Test.stub(GitHub, fn conn ->
        case conn.request_path do
          "/repos/acme/app/git/commits/" <> _sha ->
            Req.Test.json(conn, %{"tree" => %{"sha" => tree}})

          "/repos/acme/app/git/trees/" <> _sha ->
            entry = Map.put(entry, "path", ".gitattributes")
            Req.Test.json(conn, %{"sha" => tree, "tree" => [entry], "truncated" => false})
        end
      end)

      String.duplicate("c", 40)
    end

    @attributes_sha String.duplicate("a", 40)

    for {kind, entry} <- [
          tree: %{"mode" => "040000", "type" => "tree", "sha" => String.duplicate("1", 40)},
          symlink: %{"mode" => "120000", "type" => "blob", "sha" => String.duplicate("2", 40)},
          gitlink: %{"mode" => "160000", "type" => "commit", "sha" => String.duplicate("3", 40)}
        ] do
      test "accepts none where .gitattributes is a #{kind}", %{gh: gh} do
        base = root_entry(unquote(Macro.escape(entry)))
        assert check(:check_attributes, gh, base, [attribute("")]) == :ok
      end
    end

    for {label, entry} <- [
          "a regular blob without a SHA": %{"mode" => "100644", "type" => "blob", "sha" => nil},
          "a regular blob missing its SHA": %{"mode" => "100644", "type" => "blob"},
          "a tree mode typed blob": %{"mode" => "040000", "type" => "blob", "sha" => nil},
          "an unknown mode": %{"mode" => "100664", "type" => "blob", "sha" => nil}
        ] do
      test "refuses none where .gitattributes is #{label}", %{gh: gh} do
        base = root_entry(unquote(Macro.escape(entry)))

        assert check(:check_attributes, gh, base, [attribute("")]) ==
                 {:error, {:attributes_mismatch, ""}}
      end
    end

    test "refuses a SHA where the regular blob's SHA isn't 40 lowercase hex", %{gh: gh} do
      upper = String.upcase(@attributes_sha)
      base = root_entry(%{"mode" => "100644", "type" => "blob", "sha" => upper})

      assert check(:check_attributes, gh, base, [attribute("", upper)]) ==
               {:error, {:attributes_mismatch, ""}}
    end

    test "refuses a path under a blob", %{gh: gh, attributes_base: base} do
      assert check(:check_attributes, gh, base, [attribute("lib/app.rb")]) ==
               {:error, {:attributes_mismatch, "lib/app.rb"}}
    end
  end

  describe "check_result/4" do
    setup %{agent: agent, gh: gh, base: base, tree: tree} do
      entries = [
        add("lib/app_test.rb", "t\n"),
        modify("gradlew", "100755", "#!/bin/sh\n", "set -e\n"),
        delete("README", "100644", "r\n")
      ]

      write = fn ->
        for %{op: op} = e <- entries, op != :delete do
          {:ok, _sha} =
            GitHub.create_blob(gh, if(e.path == "gradlew", do: "set -e\n", else: "t\n"))
        end

        tree_entries =
          for e <- entries,
              do: %{
                "path" => e.path,
                "mode" => e.mode || "100644",
                "type" => "blob",
                "sha" => e.new_blob_sha
              }

        {:ok, new_tree} = GitHub.create_tree(gh, tree, tree_entries)
        {:ok, commit} = GitHub.create_commit(gh, "fix", new_tree, [base])
        commit
      end

      %{entries: entries, write: write, agent: agent}
    end

    test "accepts a commit whose tree holds exactly the change set", %{
      gh: gh,
      entries: entries,
      write: write
    } do
      assert check(:check_result, gh, write.(), entries) == :ok
    end

    test "refuses a commit whose stored blob differs", %{
      agent: agent,
      gh: gh,
      entries: entries,
      write: write
    } do
      FakeGithub.tamper(agent, fn
        %{"path" => "lib/app_test.rb"} = entry -> %{entry | "sha" => ChangeSet.blob_sha("evil\n")}
        entry -> entry
      end)

      assert check(:check_result, gh, write.(), entries) ==
               {:error, {:tree_mismatch, "lib/app_test.rb"}}
    end

    test "refuses a commit whose stored mode differs", %{
      agent: agent,
      gh: gh,
      entries: entries,
      write: write
    } do
      FakeGithub.tamper(agent, fn
        %{"path" => "gradlew"} = entry -> %{entry | "mode" => "100644"}
        entry -> entry
      end)

      assert check(:check_result, gh, write.(), entries) == {:error, {:tree_mismatch, "gradlew"}}
    end

    test "refuses a commit that still holds a deleted path", %{
      agent: agent,
      gh: gh,
      entries: entries,
      write: write
    } do
      FakeGithub.tamper(agent, fn
        %{"path" => "README"} = entry -> %{entry | "sha" => ChangeSet.blob_sha("r\n")}
        entry -> entry
      end)

      assert check(:check_result, gh, write.(), entries) == {:error, {:tree_mismatch, "README"}}
    end
  end
end
