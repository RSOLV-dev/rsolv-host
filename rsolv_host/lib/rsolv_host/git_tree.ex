defmodule RsolvHost.GitTree do
  @moduledoc """
  Checks a change set against GitHub's trees (RFC-150 §6.2): the base, and the
  `.gitattributes` the decision signs for it, before any write (step 2), and the
  written commits after (step 5).

  Lookups read one non-recursive tree per directory, memoized by tree SHA, so a
  change set costs one request per directory it touches, and a truncated listing
  is refused rather than trusted. A path whose parent is a blob or a symlink is
  never looked through. The checks take a tree SHA (`tree/2`) and a cache and
  return the cache, so one publish threads one cache through all of them: a tree
  shared by the base and the written commits is read once, and no cache ever
  holds more than `max_tree_reads/0` trees (`{:error, :base_check_too_large}`).
  """

  alias RsolvCore.ChangeSet.Entry
  alias RsolvCore.Decision
  alias RsolvHost.GitHub

  @type found :: %{mode: String.t(), type: String.t(), sha: String.t()}
  @type attribute :: %{String.t() => String.t() | nil}
  @type cache :: %{optional(String.t()) => [map()]}

  @regular ["100644", "100755"]
  # ponytail: one publish's tree reads. Its checks read at most
  # 2 x D(change set) + D(RED paths) trees (D: the root and each directory on the
  # paths; base and fix trees once each, RED's new ones once). 200 admits D up to
  # about 66, e.g. 20 files 3 directories deep in disjoint directories, far more
  # than real fixes touch, while five publishes an hour fit the 1,000 requests a
  # repository's GITHUB_TOKEN gets. Raise it with Policy.max_files.
  @max_tree_reads 200
  # A directory, a symlink and a submodule: git reads no attributes from them.
  @not_files [{"tree", "040000"}, {"blob", "120000"}, {"commit", "160000"}]

  @doc "The most trees one cache may hold, so the most one publish reads."
  @spec max_tree_reads() :: pos_integer()
  def max_tree_reads, do: @max_tree_reads

  @doc """
  Before any request: whether checking `entries` against the base, and the
  RED (`red_paths`) and fix commits, fits `max_tree_reads/0`.
  """
  @spec within_budget([Entry.t()], [String.t()]) :: :ok | {:error, :base_check_too_large}
  def within_budget(entries, red_paths) do
    dirs = entries |> Enum.map(& &1.path) |> Decision.attribute_dirs() |> length()

    if 2 * dirs + length(Decision.attribute_dirs(red_paths)) <= @max_tree_reads,
      do: :ok,
      else: {:error, :base_check_too_large}
  end

  @doc "The tree SHA of `commit`."
  @spec tree(GitHub.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def tree(gh, commit) do
    case GitHub.get_commit(gh, commit) do
      {:ok, %{"tree" => %{"sha" => tree}}} when is_binary(tree) -> {:ok, tree}
      {:ok, _malformed} -> {:error, :malformed_response}
      error -> error
    end
  end

  @doc "Looks `path` up in the tree `tree_sha`."
  @spec lookup(GitHub.t(), String.t(), String.t(), cache()) ::
          {:ok, found(), cache()} | {:absent, cache()} | {:error, term()}
  def lookup(gh, tree_sha, path, cache), do: walk(gh, tree_sha, String.split(path, "/"), cache)

  defp walk(gh, tree_sha, [name | rest], cache) do
    with {:ok, entries, cache} <- entries(gh, tree_sha, cache) do
      case {Enum.find(entries, &(&1["path"] == name)), rest} do
        {nil, _rest} ->
          {:absent, cache}

        {entry, []} ->
          {:ok, %{mode: entry["mode"], type: entry["type"], sha: entry["sha"]}, cache}

        {%{"type" => "tree", "mode" => "040000", "sha" => sub}, rest} ->
          walk(gh, sub, rest, cache)

        {_blob_or_symlink, _rest} ->
          {:error, :ancestor_not_tree}
      end
    end
  end

  defp entries(_gh, tree_sha, cache) when is_map_key(cache, tree_sha),
    do: {:ok, cache[tree_sha], cache}

  defp entries(_gh, _tree_sha, cache) when map_size(cache) >= @max_tree_reads,
    do: {:error, :base_check_too_large}

  defp entries(gh, tree_sha, cache) do
    case GitHub.get_tree(gh, tree_sha) do
      {:ok, %{"truncated" => false, "tree" => entries}} when is_list(entries) ->
        {:ok, entries, Map.put(cache, tree_sha, entries)}

      {:ok, %{"truncated" => true}} ->
        {:error, :truncated}

      {:ok, _malformed} ->
        {:error, :malformed_response}

      error ->
        error
    end
  end

  @doc """
  §6.2 step 2: in the base tree, every `add` is absent, and every `modify` and
  `delete` is a blob with its `base_mode` and `base_blob_sha`.
  """
  @spec check_base(GitHub.t(), String.t(), [Entry.t()], cache()) ::
          {:ok, cache()} | {:error, term()}
  def check_base(gh, tree, entries, cache),
    do:
      check(
        gh,
        tree,
        for(e <- entries, do: {e.path, {:base_mismatch, e.path}, &base?(e, &1)}),
        cache
      )

  @doc """
  §6.2 step 2, for the decision's `base_attributes`: in `base_commit`, each
  `<dir>/.gitattributes` with a `blob_sha` is a regular file with that blob, and
  each without one is absent, a directory, a symlink or a submodule, which git
  doesn't read attributes from. Any other entry is a mismatch.
  """
  @spec check_attributes(GitHub.t(), String.t(), [attribute()], cache()) ::
          {:ok, cache()} | {:error, term()}
  def check_attributes(gh, tree, attributes, cache) do
    checks =
      for %{"dir" => dir, "blob_sha" => sha} <- attributes,
          do: {attributes_path(dir), {:attributes_mismatch, dir}, &attributes?(sha, &1)}

    check(gh, tree, checks, cache)
  end

  @doc """
  §6.2 step 5: in a written commit's tree, every `add` and `modify` is a blob with its `mode`
  and `new_blob_sha`, and every `delete` is absent.
  """
  @spec check_result(GitHub.t(), String.t(), [Entry.t()], cache()) ::
          {:ok, cache()} | {:error, term()}
  def check_result(gh, tree, entries, cache),
    do:
      check(
        gh,
        tree,
        for(e <- entries, do: {e.path, {:tree_mismatch, e.path}, &result?(e, &1)}),
        cache
      )

  # Each check is `{path, mismatch, expected?}`, looked up through `cache`.
  defp check(gh, tree, checks, cache),
    do: Enum.reduce_while(checks, {:ok, cache}, &check_path(gh, tree, &1, &2))

  defp check_path(gh, tree, {path, mismatch, expected?}, {:ok, cache}) do
    case lookup(gh, tree, path, cache) do
      {:error, :ancestor_not_tree} ->
        {:halt, {:error, mismatch}}

      {:error, _reason} = error ->
        {:halt, error}

      found ->
        if expected?.(found),
          do: {:cont, {:ok, cache_of(found)}},
          else: {:halt, {:error, mismatch}}
    end
  end

  defp cache_of({:absent, cache}), do: cache
  defp cache_of({:ok, _found, cache}), do: cache

  defp base?(%Entry{op: :add}, {:absent, _cache}), do: true

  defp base?(%Entry{op: op, base_mode: mode, base_blob_sha: sha}, {:ok, found, _cache})
       when op in [:modify, :delete],
       do: found == %{mode: mode, type: "blob", sha: sha}

  defp base?(_entry, _found), do: false

  defp result?(%Entry{op: :delete}, {:absent, _cache}), do: true

  defp result?(%Entry{op: op, mode: mode, new_blob_sha: sha}, {:ok, found, _cache})
       when op in [:add, :modify],
       do: found == %{mode: mode, type: "blob", sha: sha}

  defp result?(_entry, _found), do: false

  defp attributes_path(""), do: ".gitattributes"
  defp attributes_path(dir), do: dir <> "/.gitattributes"

  defp attributes?(sha, {:ok, %{type: "blob", mode: mode, sha: sha}, _cache})
       when mode in @regular and is_binary(sha),
       do: sha =~ ~r/\A[0-9a-f]{40}\z/

  defp attributes?(nil, {:absent, _cache}), do: true

  defp attributes?(nil, {:ok, %{type: type, mode: mode}, _cache})
       when {type, mode} in @not_files,
       do: true

  defp attributes?(_sha, _found), do: false
end
