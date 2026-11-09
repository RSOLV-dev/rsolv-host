defmodule RsolvHost.BaseFactsReader do
  @moduledoc """
  Reads base facts (RFC-150 §4.2a) for the touched paths from the job's fresh
  checkout of `base_sha`, before any sandbox starts.

  Every touched path must pass `RsolvCore.ChangeSet.valid_path?/1` before
  anything runs. The facts come only from git objects named by `base_sha`,
  never from the working tree: the walk lists one tree per directory
  (`ls-tree`, by tree SHA), and reads each regular blob (`cat-file blob`, at
  most its listed size), whose content must hash to its entry. A path beneath
  a symlink, a submodule or a missing directory is `missing`, and is never
  looked through. Base facts carry the `.gitattributes` of the root and of
  every directory the walk lists.

  git runs as `env -i … /abs/git --git-dir=<checkout>/.git`, so no `GIT_*`
  variable of the host's reaches it, with no system or global config, no
  replace objects, literal pathspecs, no lazy fetch and no transport, and
  `core.fsmonitor` and `core.hooksPath` overridden. It runs only `rev-parse`,
  `ls-tree` and `cat-file blob`: no diff, filter or textconv. stderr is merged
  into the output (`RsolvHost.Exec`), so a stray warning breaks the strict
  parse and the read fails closed.

  The whole read is bounded: each listing by its own cap, all listings
  together by a byte and an entry budget, and every git call by what's left
  of one deadline. Past any of them the base is too large to verify
  (`base_facts_too_large`); only one git call past its own time limit, with
  the deadline still ahead, is `base_read_timeout` (transient). From each
  listing the walk keeps only the entries it looks up and `.gitattributes`.
  """

  alias RsolvCore.{BaseFacts, ChangeSet}

  @git_env ~w(PATH=/usr/bin:/bin LC_ALL=C GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
              GIT_NO_REPLACE_OBJECTS=1 GIT_LITERAL_PATHSPECS=1 GIT_NO_LAZY_FETCH=1
              GIT_ALLOW_PROTOCOL=none GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0)
  @overrides ~w(-c core.fsmonitor=false -c core.hooksPath=/dev/null -c protocol.allow=never)
  @regular ["100644", "100755"]
  # RsolvCore.BaseFacts' caps per file.
  @max_blob_bytes 5 * 1024 * 1024
  @max_attributes_bytes 1024 * 1024
  # The platform takes at most 7 MiB of canonical JSON (Rsolv.Runners.Verify),
  # and content travels as base64, so no more than this can fit.
  @max_content_bytes div(7 * 1024 * 1024 * 3, 4)
  # ponytail: one directory's listing (about 80 bytes an entry, so 200,000
  # entries); a bigger directory fails closed. Raise with evidence.
  @max_listing_bytes 16 * 1024 * 1024
  # ponytail: all listings together. 40 touched paths (the platform's cap)
  # 128 deep through 101 directories of 4,800 entries (485,000 entries, 33 MB
  # of listings) peak at 7 MiB of BEAM memory over the baseline (measured,
  # rsolv-host PR #9); raise both with evidence.
  @max_listings_bytes 64 * 1024 * 1024
  @max_entries 500_000
  @timeout_ms 120_000
  @budget_ms 300_000

  @type error ::
          :invalid_touched_paths
          | :too_many_touched_paths
          | :touched_path_too_deep
          | :checkout_not_base
          | :base_read_failed
          | :base_read_timeout
          | :base_facts_too_large

  @doc """
  Base facts for `paths` at `base_sha`, from the checkout at `dir` (absolute),
  whose `HEAD` must be `base_sha`. Options: `:exec`, and `:budget_ms`, the
  whole read's deadline (5 minutes by default).
  """
  @spec read(Path.t(), String.t(), term(), keyword()) :: {:ok, BaseFacts.t()} | {:error, error()}
  def read(dir, base_sha, paths, opts \\ []) do
    with {:ok, required} <- required(paths),
         {:ok, git_dir} <- git_dir(dir),
         {:ok, git} <- git(),
         deadline = now() + Keyword.get(opts, :budget_ms, @budget_ms),
         run = runner(Keyword.get_lazy(opts, :exec, &RsolvHost.exec/0), git, git_dir, deadline),
         {:ok, ^base_sha} <- head(run),
         {:ok, walked} <- walk(run, base_sha, required),
         reads = reads(walked),
         :ok <- budget(reads),
         {:ok, contents} <- contents(run, reads) do
      {:ok, facts(base_sha, walked, contents)}
    else
      {:ok, _other_head} -> {:error, :checkout_not_base}
      error -> error
    end
  end

  # Too many or too deep is the fix's size, so asking again won't change it.
  defp required(paths) when is_list(paths) do
    with true <- Enum.all?(paths, &ChangeSet.valid_path?/1),
         {:ok, required} <- BaseFacts.required_paths(paths) do
      {:ok, required}
    else
      false -> {:error, :invalid_touched_paths}
      {:error, :too_many_paths} -> {:error, :too_many_touched_paths}
      {:error, {:path_too_deep, _path}} -> {:error, :touched_path_too_deep}
    end
  end

  defp required(_paths), do: {:error, :invalid_touched_paths}

  # A gitfile or a symlink would point git at a repository outside the checkout.
  defp git_dir(dir) do
    git_dir = Path.join(dir, ".git")

    case File.lstat(git_dir) do
      {:ok, %File.Stat{type: :directory}} -> {:ok, git_dir}
      _not_a_directory -> {:error, :checkout_not_base}
    end
  end

  defp git do
    case System.find_executable("git") do
      nil -> {:error, :base_read_failed}
      git -> {:ok, git}
    end
  end

  defp runner(exec, git, git_dir, deadline) do
    fn args, max_bytes ->
      argv = ["-i" | @git_env] ++ [git, "--git-dir=" <> git_dir | @overrides] ++ args
      timeout_ms = min(@timeout_ms, deadline - now())

      if timeout_ms > 0,
        do:
          "env"
          |> exec.run(argv, timeout_ms: timeout_ms, max_bytes: max_bytes)
          |> git_result(timeout_ms),
        else: {:error, :base_facts_too_large}
    end
  end

  defp git_result({:ok, %{status: 0, output: output}}, _timeout_ms), do: {:ok, output}
  defp git_result({:error, :output_too_large}, _timeout_ms), do: {:error, :base_facts_too_large}
  defp git_result({:error, :timeout}, @timeout_ms), do: {:error, :base_read_timeout}
  defp git_result({:error, :timeout}, _deadline_left), do: {:error, :base_facts_too_large}
  defp git_result(_failed, _timeout_ms), do: {:error, :base_read_failed}

  defp head(run) do
    with {:ok, output} <- run.(~w(rev-parse --verify --end-of-options HEAD^{commit}), 4096),
         do: {:ok, String.trim_trailing(output, "\n")}
  end

  # `required` is sorted, so every directory comes before what it holds.
  defp walk(run, base_sha, required) do
    state = %{
      facts: %{},
      trees: %{"" => base_sha},
      listings: %{},
      wanted: wanted(required),
      bytes_left: @max_listings_bytes,
      entries_left: @max_entries
    }

    Enum.reduce_while(required, {:ok, state}, fn path, {:ok, state} ->
      case walk_path(run, state, path) do
        {:ok, state} -> {:cont, {:ok, state}}
        error -> {:halt, error}
      end
    end)
  end

  # Each directory's names the walk looks up, and its .gitattributes.
  defp wanted(required) do
    required
    |> Enum.group_by(&parent/1, &Path.basename/1)
    |> Map.new(fn {dir, names} -> {dir, MapSet.new([".gitattributes" | names])} end)
  end

  defp parent(path), do: path |> BaseFacts.ancestors() |> List.last("")

  defp walk_path(run, state, path) do
    parent = parent(path)

    with {:ok, entries, state} <- listing(run, state, parent),
         {:ok, fact} <- entry_fact(entries && entries[Path.basename(path)]) do
      {:ok, put_fact(state, path, fact)}
    end
  end

  # Beneath anything but a tree, nothing exists.
  defp listing(_run, state, dir) when not is_map_key(state.trees, dir), do: {:ok, nil, state}

  defp listing(_run, state, dir) when is_map_key(state.listings, dir),
    do: {:ok, state.listings[dir], state}

  defp listing(run, state, dir) do
    args = ["ls-tree", "-z", "-l", "--end-of-options", state.trees[dir]]

    with {:ok, output} <- run.(args, min(@max_listing_bytes, state.bytes_left)),
         {:ok, entries, count} <- parse_listing(output, state.wanted[dir], state.entries_left) do
      {:ok, entries,
       %{
         state
         | listings: Map.put(state.listings, dir, entries),
           bytes_left: state.bytes_left - byte_size(output),
           entries_left: state.entries_left - count
       }}
    end
  end

  # Kept entries are copied out, so the listing's binary can be freed.
  defp parse_listing(output, wanted, entries_left) do
    output
    |> String.split(<<0>>, trim: true)
    |> Enum.reduce_while({:ok, %{}, 0}, fn
      _record, {:ok, _acc, ^entries_left} ->
        {:halt, {:error, :base_facts_too_large}}

      record, {:ok, acc, count} ->
        case parse_record(record) do
          {:ok, name, entry} -> {:cont, {:ok, keep(acc, wanted, name, entry), count + 1}}
          :error -> {:halt, {:error, :base_read_failed}}
        end
    end)
  end

  defp keep(acc, wanted, name, {mode, type, sha, size}) do
    if MapSet.member?(wanted, name),
      do: Map.put(acc, :binary.copy(name), {:binary.copy(mode), type, :binary.copy(sha), size}),
      else: acc
  end

  # "<mode> <type> <sha> <size, padded, or ->\t<name>"
  defp parse_record(record) do
    with [meta, name] <- :binary.split(record, "\t"),
         [mode, type, sha, size] <- String.split(meta, " ", trim: true),
         true <- mode =~ ~r/\A[0-7]{6}\z/ and sha =~ ~r/\A[0-9a-f]{40}\z/,
         {:ok, size} <- size(size) do
      {:ok, name, {mode, type, sha, size}}
    else
      _malformed -> :error
    end
  end

  defp size("-"), do: {:ok, nil}

  defp size(digits) do
    case Integer.parse(digits) do
      {size, ""} -> {:ok, size}
      _malformed -> :error
    end
  end

  defp entry_fact(nil), do: {:ok, %{type: :missing}}
  defp entry_fact({"040000", "tree", sha, _size}), do: {:ok, {:tree, sha}}
  defp entry_fact({"160000", "commit", _sha, _size}), do: {:ok, %{type: :commit}}

  defp entry_fact({"120000", "blob", sha, _size}),
    do: {:ok, %{type: :blob, mode: "120000", sha: sha, content: nil}}

  defp entry_fact({mode, "blob", sha, size}) when mode in @regular and is_integer(size),
    do: {:ok, {:read, %{mode: mode, sha: sha, size: size}}}

  defp entry_fact(_other), do: {:error, :base_read_failed}

  defp put_fact(state, path, {:tree, sha}),
    do: %{
      state
      | facts: Map.put(state.facts, path, %{type: :tree}),
        trees: Map.put(state.trees, path, sha)
    }

  defp put_fact(state, path, fact), do: put_in(state.facts[path], fact)

  # Every blob whose content base facts carry: the regular files on the
  # paths, and each listed directory's .gitattributes.
  defp reads(walked) do
    files =
      for {path, {:read, blob}} <- walked.facts,
          do: Map.merge(blob, %{key: {:path, path}, cap: @max_blob_bytes})

    attributes =
      for {dir, %{".gitattributes" => {mode, "blob", sha, size}}} <- walked.listings,
          mode in @regular,
          do: %{key: {:attributes, dir}, sha: sha, size: size, cap: @max_attributes_bytes}

    files ++ attributes
  end

  defp budget(reads) do
    if Enum.all?(reads, &(&1.size <= &1.cap)) and
         reads |> Enum.map(& &1.size) |> Enum.sum() <= @max_content_bytes,
       do: :ok,
       else: {:error, :base_facts_too_large}
  end

  defp contents(run, reads) do
    Enum.reduce_while(reads, {:ok, %{}}, fn %{key: key, sha: sha, size: size}, {:ok, acc} ->
      with {:ok, content} <- run.(["cat-file", "blob", sha], size),
           ^sha <- ChangeSet.blob_sha(content) do
        {:cont, {:ok, Map.put(acc, key, content)}}
      else
        {:error, reason} when reason in [:base_read_timeout, :base_facts_too_large] ->
          {:halt, {:error, reason}}

        _failed ->
          {:halt, {:error, :base_read_failed}}
      end
    end)
  end

  defp facts(base_sha, walked, contents) do
    paths =
      Map.new(walked.facts, fn
        {path, {:read, %{mode: mode, sha: sha}}} ->
          {path, %{type: :blob, mode: mode, sha: sha, content: contents[{:path, path}]}}

        fact ->
          fact
      end)

    attributes = for {{:attributes, dir}, text} <- contents, into: %{}, do: {dir, text}
    %BaseFacts{base_sha: base_sha, paths: paths, attributes: attributes}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
