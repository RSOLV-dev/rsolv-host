# Generates test/vectors/patch.json from real git repositories (synthetic content only).
# Expected change sets and post-images come from the work tree and `git hash-object`,
# never from RsolvCore, so the vectors are an independent oracle.
#   cd rsolv_core && elixir test/vectors/gen_patch_vectors.exs [output path]
# Commits use fixed dates and identities, so every run writes the same vectors;
# RsolvCore.CanonicalizeVectorsTest regenerates them and compares.
defmodule GenPatchVectors do
  @diff ~w(-c core.autocrlf=false -c core.quotepath=true diff --binary --full-index --no-renames --no-textconv --no-ext-diff)
  @git_env [
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_NOSYSTEM", "1"},
    {"GIT_AUTHOR_DATE", "2026-01-01T00:00:00Z"},
    {"GIT_COMMITTER_DATE", "2026-01-01T00:00:00Z"}
  ]

  def run(out) do
    {accept, reject} =
      isolated(fn ->
        {Enum.map(accept_cases(), &accept/1), Enum.map(reject_cases(), &reject/1)}
      end)

    json = JSON.encode!(%{"accept" => accept, "reject" => reject})
    File.write!(out, json <> "\n")
    IO.puts("wrote #{length(accept)} accept and #{length(reject)} reject vectors")
  end

  # {name, base files %{path => content | {:exec, content} | {:symlink, target}}, change fun}
  def accept_cases do
    lines = Enum.map_join(1..30, &"line #{&1}\n")

    lookalikes =
      "--- a/x\n+++ b/x\n@@ -1 +1 @@\ndiff --git a/y b/y\n\\ No newline at end of file\n"

    [
      {"modify", %{"a.js" => "keep\neval(x)\n"},
       fn -> File.write!("a.js", "keep\nsafe(x)\n") end},
      {"crlf", %{"w.txt" => "a\r\nb\r\n"}, fn -> File.write!("w.txt", "a\r\nc\r\n") end},
      {"crlf_missing_trailing_newline", %{"w.txt" => "a\r\nb"},
       fn -> File.write!("w.txt", "a\r\nc") end},
      {"missing_trailing_newline", %{"n.txt" => "x"}, fn -> File.write!("n.txt", "y") end},
      {"adds_trailing_newline", %{"n.txt" => "x"}, fn -> File.write!("n.txt", "x\n") end},
      {"removes_trailing_newline", %{"n.txt" => "x\n"}, fn -> File.write!("n.txt", "x") end},
      {"modify_to_empty", %{"e.txt" => "x\n"}, fn -> File.write!("e.txt", "") end},
      {"modify_from_empty", %{"e.txt" => ""}, fn -> File.write!("e.txt", "x\n") end},
      {"non_ascii_path", %{"keep.txt" => "k\n"},
       fn ->
         File.mkdir_p!("café")
         File.write!("café/naïve_test.txt", "é\n")
       end},
      {"quote_in_path", %{"keep.txt" => "k\n"}, fn -> File.write!(~s(say "hi".txt), "q\n") end},
      {"empty_file_add", %{"keep.txt" => "k\n"},
       fn ->
         File.mkdir_p!("test")
         File.write!("test/empty.txt", "")
       end},
      {"add_without_trailing_newline", %{"keep.txt" => "k\n"},
       fn -> File.write!("t.txt", "no newline") end},
      {"empty_file_delete", %{"old/empty.txt" => "", "keep.txt" => "k\n"},
       fn -> File.rm!("old/empty.txt") end},
      {"delete", %{"old/x.js" => "a\nb\n", "keep.txt" => "k\n"}, fn -> File.rm!("old/x.js") end},
      {"delete_without_trailing_newline", %{"d.txt" => "a\nb", "keep.txt" => "k\n"},
       fn -> File.rm!("d.txt") end},
      {"rename_is_delete_plus_add", %{"old/x.js" => "same\n"},
       fn ->
         File.mkdir_p!("new")
         File.rename!("old/x.js", "new/x.js")
       end},
      {"executable_modify_keeps_mode", %{"gradlew" => {:exec, "a\n"}},
       fn -> File.write!("gradlew", "b\n") end},
      {"multi_hunk", %{"m.txt" => lines},
       fn ->
         File.write!(
           "m.txt",
           lines
           |> String.replace("line 2\n", "two\n")
           |> String.replace("line 28\n", "twenty-eight\n")
         )
       end},
      {"content_looks_like_headers", %{"h.txt" => "start\n" <> lookalikes},
       fn -> File.write!("h.txt", lookalikes <> "end\n") end},
      {"path_with_space", %{"my file.txt" => "a\n"}, fn -> File.write!("my file.txt", "b\n") end},
      {"new_directories", %{"keep.txt" => "k\n"},
       fn ->
         File.mkdir_p!("test/deep/new")
         File.write!("test/deep/new/a_test.js", "t\n")
       end}
    ]
  end

  def reject_cases do
    [
      {:git, "binary", %{"b.bin" => "a\n"}, fn -> File.write!("b.bin", <<0, 1, 2>>) end, "parse",
       "binary", nil},
      {:git, "symlink_add", %{"keep.txt" => "k\n"}, fn -> File.ln_s!("/etc/passwd", "l") end,
       "parse", "not_regular_file", nil},
      {:git, "mode_change", %{"r.sh" => "a\n"}, fn -> File.chmod!("r.sh", 0o755) end, "parse",
       "mode_change", nil},
      {:git, "executable_add", %{"keep.txt" => "k\n"},
       fn ->
         File.write!("x.sh", "a\n")
         File.chmod!("x.sh", 0o755)
       end, "parse", "executable", nil},
      {:git, "lfs_filtered", %{".gitattributes" => "*.bin filter=lfs\n", "d.bin" => "v1\n"},
       fn -> File.write!("d.bin", "v2\n") end, "canonicalize", "filter_attribute", "d.bin"},
      {:git, "hunk_on_another_base", %{"a.js" => "keep\neval(x)\n"},
       fn -> File.write!("a.js", "keep\nsafe(x)\n") end, "canonicalize", "hunk_mismatch", "a.js"},
      {:git, "add_of_existing_path", %{"keep.txt" => "k\n"},
       fn -> File.write!("a_test.js", "new\n") end, "canonicalize", "add_exists", "a_test.js"},
      # git can't write these patches, so they're text; their base facts come from a real repo.
      {:git_text, "add_under_symlink_ancestor",
       %{"real/keep.txt" => "k\n", "link" => {:symlink, "real"}},
       "diff --git a/link/new_test.js b/link/new_test.js\nnew file mode 100644\nindex #{zero()}..#{zero()}\n--- /dev/null\n+++ b/link/new_test.js\n@@ -0,0 +1 @@\n+t\n",
       ["link/new_test.js"], "canonicalize", "ancestor_not_tree", "link/new_test.js"},
      {:git_text, "modify_of_symlink", %{"real.txt" => "k\n", "l" => {:symlink, "real.txt"}},
       "diff --git a/l b/l\nindex #{zero()}..#{zero()} 100644\n--- a/l\n+++ b/l\n@@ -1 +1 @@\n-real.txt\n\\ No newline at end of file\n+x\n",
       ["l"], "canonicalize", "not_regular_file", "l"},
      {:git_text, "modify_missing", %{"keep.txt" => "k\n"},
       "diff --git a/gone.txt b/gone.txt\nindex #{zero()}..#{zero()} 100644\n--- a/gone.txt\n+++ b/gone.txt\n@@ -1 +1 @@\n-a\n+b\n",
       ["gone.txt"], "canonicalize", "modify_missing", "gone.txt"},
      {:git_text, "delete_leaves_lines", %{"d.txt" => "a\nb\n"},
       "diff --git a/d.txt b/d.txt\ndeleted file mode 100644\nindex #{zero()}..#{zero()}\n--- a/d.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-a\n",
       ["d.txt"], "canonicalize", "hunk_mismatch", "d.txt"},
      {:git_text, "file_and_directory", %{"keep.txt" => "k\n"},
       "diff --git a/x b/x\nnew file mode 100644\nindex #{zero()}..#{zero()}\n--- /dev/null\n+++ b/x\n@@ -0,0 +1 @@\n+a\ndiff --git a/x/y b/x/y\nnew file mode 100644\nindex #{zero()}..#{zero()}\n--- /dev/null\n+++ b/x/y\n@@ -0,0 +1 @@\n+b\n",
       ["x", "x/y"], "canonicalize", "path_conflict", nil},
      {:text, "traversal",
       "diff --git a/../x b/../x\nnew file mode 100644\nindex #{zero()}..#{zero()}\n", "parse",
       "invalid_path"},
      {:text, "dot_git",
       "diff --git a/.Git/config b/.Git/config\nnew file mode 100644\nindex #{zero()}..#{zero()}\n",
       "parse", "invalid_path"},
      {:text, "gitlink",
       "diff --git a/sub b/sub\nindex #{zero()}..#{zero()} 160000\n--- a/sub\n+++ b/sub\n@@ -1 +1 @@\n-a\n+b\n",
       "parse", "not_regular_file"}
    ]
  end

  defp zero, do: String.duplicate("0", 40)

  defp accept({name, base, change}) do
    in_repo(base, change, fn base_sha, patch ->
      diffs = name_status(base_sha)
      requested = Enum.map(diffs, &elem(&1, 1))

      digest(%{
        "name" => name,
        "base_sha" => base_sha,
        "patch" => Base.encode64(patch),
        "base_facts" => facts(base_sha, requested),
        "change_set" => Enum.map(diffs, &entry(base_sha, &1)),
        "digest" => nil,
        "post_images" =>
          for(
            {op, path} <- diffs,
            op != "D",
            into: %{},
            do: {path, Base.encode64(File.read!(path))}
          )
      })
    end)
  end

  defp reject({:git, name, base, change, stage, reason, path}) do
    in_repo(base, change, fn base_sha, patch ->
      requested = Enum.map(name_status(base_sha), &elem(&1, 1))
      facts = base_sha |> facts(requested) |> tamper(name)

      %{
        "name" => name,
        "base_sha" => base_sha,
        "patch" => Base.encode64(patch),
        "base_facts" => facts,
        "stage" => stage,
        "reason" => reason,
        "path" => path
      }
    end)
  end

  defp reject({:git_text, name, base, patch, requested, stage, reason, path}) do
    in_repo(base, fn -> :ok end, fn base_sha, _no_patch ->
      %{
        "name" => name,
        "base_sha" => base_sha,
        "patch" => Base.encode64(patch),
        "base_facts" => facts(base_sha, requested),
        "stage" => stage,
        "reason" => reason,
        "path" => path
      }
    end)
  end

  defp reject({:text, name, patch, stage, reason}),
    do: %{
      "name" => name,
      "base_sha" => String.duplicate("b", 40),
      "patch" => Base.encode64(patch),
      "base_facts" => nil,
      "stage" => stage,
      "reason" => reason,
      "path" => nil
    }

  # The "another base" vector: base facts from a base whose content differs (acceptance 7).
  defp tamper(facts, "hunk_on_another_base") do
    other = "keep\nother(x)\n"

    put_in(facts, ["paths", "a.js"], %{
      "type" => "blob",
      "mode" => "100644",
      "sha" => sha_of(other),
      "content" => Base.encode64(other)
    })
  end

  # The "add of an existing path" vector: the patch adds a_test.js, and the trusted base
  # says it exists (VALIDATE disguising a modify as an add, acceptance 8).
  defp tamper(facts, "add_of_existing_path") do
    old = "old\n"

    put_in(facts, ["paths", "a_test.js"], %{
      "type" => "blob",
      "mode" => "100644",
      "sha" => sha_of(old),
      "content" => Base.encode64(old)
    })
  end

  defp tamper(facts, _name), do: facts

  # git reads only what the vectors set: no system or user config or attributes,
  # and nothing a caller's GIT_* environment would change.
  defp isolated(fun) do
    home = Path.join(System.tmp_dir!(), "rsolv-vec-home-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)

    for {name, _value} <- System.get_env(),
        String.starts_with?(name, "GIT_"),
        do: System.delete_env(name)

    System.put_env(%{
      "HOME" => home,
      "XDG_CONFIG_HOME" => home,
      "GIT_ATTR_NOSYSTEM" => "1",
      "GIT_CONFIG_NOSYSTEM" => "1"
    })

    try do
      fun.()
    after
      File.rm_rf!(home)
    end
  end

  defp in_repo(base, change, fun) do
    dir = Path.join(System.tmp_dir!(), "rsolv-vec-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      File.cd!(dir, fn ->
        git(~w(init -q -b main))
        git(~w(config user.email v@example.invalid))
        git(~w(config user.name vectors))
        Enum.each(base, &write_base/1)
        git(~w(add -A))
        git(~w(commit -q -m base))
        base_sha = String.trim(git(~w(rev-parse HEAD)))
        change.()
        git(~w(add -A --intent-to-add))
        fun.(base_sha, git(@diff ++ [base_sha]))
      end)
    after
      File.rm_rf!(dir)
    end
  end

  defp write_base({path, {:exec, content}}) do
    write_base({path, content})
    File.chmod!(path, 0o755)
  end

  defp write_base({path, {:symlink, target}}), do: File.ln_s!(target, path)

  defp write_base({path, content}) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, content)
  end

  defp name_status(base_sha) do
    (~w(-c core.quotepath=false diff --name-status --no-renames -z) ++ [base_sha])
    |> git()
    |> String.split(<<0>>, trim: true)
    |> Enum.chunk_every(2)
    |> Enum.map(fn [op, path] -> {op, path} end)
    |> Enum.sort_by(&elem(&1, 1))
  end

  defp entry(_base_sha, {"A", path}),
    do: %{
      "path" => path,
      "op" => "add",
      "base_mode" => nil,
      "base_blob_sha" => nil,
      "mode" => "100644",
      "new_blob_sha" => String.trim(git(["hash-object", "--no-filters", "--", path]))
    }

  defp entry(base_sha, {"M", path}) do
    {mode, sha} = ls_tree(base_sha, path)

    %{
      "path" => path,
      "op" => "modify",
      "base_mode" => mode,
      "base_blob_sha" => sha,
      "mode" => mode,
      "new_blob_sha" => String.trim(git(["hash-object", "--no-filters", "--", path]))
    }
  end

  defp entry(base_sha, {"D", path}) do
    {mode, sha} = ls_tree(base_sha, path)

    %{
      "path" => path,
      "op" => "delete",
      "base_mode" => mode,
      "base_blob_sha" => sha,
      "mode" => nil,
      "new_blob_sha" => nil
    }
  end

  defp ls_tree(base_sha, path) do
    [meta, _path] =
      ["ls-tree", "-z", base_sha, "--", path]
      |> git()
      |> String.trim_trailing(<<0>>)
      |> String.split("\t", parts: 2)

    [mode, "blob", sha] = String.split(meta, " ")
    {mode, sha}
  end

  defp facts(base_sha, requested) do
    required = requested |> Enum.flat_map(&[&1 | ancestors(&1)]) |> Enum.uniq() |> Enum.sort()
    paths = Map.new(required, &{&1, fact(base_sha, &1)})

    attributes =
      for dir <- ["" | required],
          dir == "" or paths[dir] == %{"type" => "tree"},
          file = if(dir == "", do: ".gitattributes", else: dir <> "/.gitattributes"),
          %{"type" => "blob", "mode" => mode} = blob <- [fact(base_sha, file)],
          mode in ~w(100644 100755),
          into: %{},
          do: {dir, blob["content"]}

    %{"base_sha" => base_sha, "paths" => paths, "attributes" => attributes}
  end

  defp fact(base_sha, path) do
    case git(["ls-tree", "-z", base_sha, "--", path]) do
      "" ->
        %{"type" => "missing"}

      out ->
        out |> String.trim_trailing(<<0>>) |> String.split("\t", parts: 2) |> hd() |> entry_fact()
    end
  end

  defp entry_fact(meta) do
    case String.split(meta, " ") do
      ["120000", "blob", sha] ->
        %{"type" => "blob", "mode" => "120000", "sha" => sha}

      [mode, "blob", sha] ->
        content = Base.encode64(git(["cat-file", "blob", sha]))
        %{"type" => "blob", "mode" => mode, "sha" => sha, "content" => content}

      [_mode, type, _sha] ->
        %{"type" => type}
    end
  end

  defp ancestors(path) do
    segments = path |> String.split("/") |> Enum.drop(-1)
    for n <- 1..length(segments)//1, do: segments |> Enum.take(n) |> Enum.join("/")
  end

  defp digest(%{"change_set" => change_set} = vector) do
    canonical = change_set |> canonical() |> IO.iodata_to_binary()
    hex = :sha256 |> :crypto.hash(canonical) |> Base.encode16(case: :lower)
    %{vector | "digest" => "sha256:" <> hex}
  end

  # RFC 8785 for this vector's shapes only (lists of flat objects with string or null values).
  defp canonical(list) when is_list(list),
    do: ["[", list |> Enum.map(&canonical/1) |> Enum.intersperse(","), "]"]

  defp canonical(map) when is_map(map) do
    members =
      Enum.sort_by(map, fn {k, _v} -> :unicode.characters_to_binary(k, :utf8, {:utf16, :big}) end)

    [
      "{",
      members
      |> Enum.map(fn {k, v} -> [JSON.encode!(k), ":", canonical(v)] end)
      |> Enum.intersperse(","),
      "}"
    ]
  end

  defp canonical(value), do: JSON.encode!(value)

  defp sha_of(content),
    do:
      :sha
      |> :crypto.hash(["blob ", Integer.to_string(byte_size(content)), 0, content])
      |> Base.encode16(case: :lower)

  defp git(args) do
    {out, 0} = System.cmd("git", args, env: @git_env)
    out
  end
end

case System.argv() do
  [] -> GenPatchVectors.run(Path.join(__DIR__, "patch.json"))
  [out] -> GenPatchVectors.run(out)
end
