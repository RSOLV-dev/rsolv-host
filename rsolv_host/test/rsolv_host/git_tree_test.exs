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

    test "refuses a truncated listing", %{agent: agent, gh: gh, tree: tree} do
      FakeGithub.truncate(agent)

      assert GitTree.lookup(gh, tree, "README", %{}) == {:error, :truncated}
    end
  end

  describe "check_base/3" do
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

      assert GitTree.check_base(gh, base, entries) == :ok
    end

    test "refuses an add of a path that exists", %{gh: gh, base: base} do
      assert GitTree.check_base(gh, base, [add("README", "x")]) ==
               {:error, {:base_mismatch, "README"}}
    end

    test "refuses a modify whose base blob or mode differs", %{gh: gh, base: base} do
      assert GitTree.check_base(gh, base, [modify("lib/app.rb", "100644", "other\n", "x")]) ==
               {:error, {:base_mismatch, "lib/app.rb"}}

      assert GitTree.check_base(gh, base, [modify("gradlew", "100644", "#!/bin/sh\n", "x")]) ==
               {:error, {:base_mismatch, "gradlew"}}
    end

    test "refuses a modify or delete of an absent path", %{gh: gh, base: base} do
      assert GitTree.check_base(gh, base, [delete("gone", "100644", "x")]) ==
               {:error, {:base_mismatch, "gone"}}
    end

    test "refuses a path under a symlinked directory", %{gh: gh, base: base} do
      assert GitTree.check_base(gh, base, [add("link/evil.rb", "x")]) ==
               {:error, {:base_mismatch, "link/evil.rb"}}
    end
  end

  describe "check_attributes/3" do
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
      assert GitTree.check_attributes(gh, base, attributes) == :ok
      assert tree_gets(agent) - gets == 3
    end

    test "accepts none where a symlink or a directory is named .gitattributes",
         %{gh: gh, attributes_base: base} do
      assert GitTree.check_attributes(gh, base, [attribute("bin"), attribute("doc")]) == :ok
    end

    test "refuses none where there is a file", %{gh: gh, attributes_base: base} do
      assert GitTree.check_attributes(gh, base, [attribute("lib")]) ==
               {:error, {:attributes_mismatch, "lib"}}
    end

    test "refuses a blob that differs", %{gh: gh, attributes_base: base} do
      assert GitTree.check_attributes(gh, base, [attribute("", ChangeSet.blob_sha("*\n"))]) ==
               {:error, {:attributes_mismatch, ""}}
    end

    for dir <- ["src", "new", "bin", "doc"] do
      test "refuses a file where #{dir}/.gitattributes isn't one", %{
        gh: gh,
        attributes_base: base
      } do
        sha = ChangeSet.blob_sha("../.gitattributes")

        assert GitTree.check_attributes(gh, base, [attribute(unquote(dir), sha)]) ==
                 {:error, {:attributes_mismatch, unquote(dir)}}
      end
    end

    test "refuses a path under a blob", %{gh: gh, attributes_base: base} do
      assert GitTree.check_attributes(gh, base, [attribute("lib/app.rb")]) ==
               {:error, {:attributes_mismatch, "lib/app.rb"}}
    end
  end

  describe "check_result/3" do
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
      assert GitTree.check_result(gh, write.(), entries) == :ok
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

      assert GitTree.check_result(gh, write.(), entries) ==
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

      assert GitTree.check_result(gh, write.(), entries) == {:error, {:tree_mismatch, "gradlew"}}
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

      assert GitTree.check_result(gh, write.(), entries) == {:error, {:tree_mismatch, "README"}}
    end
  end
end
