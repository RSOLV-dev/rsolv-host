defmodule RsolvHost.GitTree do
  @moduledoc """
  Checks a change set against GitHub's trees (RFC-150 §6.2): the base, and the
  `.gitattributes` the decision signs for it, before any write (step 2), and the
  written commits after (step 5).

  Lookups read one non-recursive tree per directory, memoized by tree SHA, so a
  change set costs one request per directory it touches, and a truncated listing
  is refused rather than trusted. A path whose parent is a blob or a symlink is
  never looked through.
  """

  alias RsolvCore.ChangeSet.Entry
  alias RsolvHost.GitHub

  @type found :: %{mode: String.t(), type: String.t(), sha: String.t()}
  @type attribute :: %{String.t() => String.t() | nil}
  @type cache :: %{optional(String.t()) => [map()]}

  @regular ["100644", "100755"]
  # A directory, a symlink and a submodule: git reads no attributes from them.
  @not_files [{"tree", "040000"}, {"blob", "120000"}, {"commit", "160000"}]

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
  §6.2 step 2: in `base_commit`, every `add` is absent, and every `modify` and
  `delete` is a blob with its `base_mode` and `base_blob_sha`.
  """
  @spec check_base(GitHub.t(), String.t(), [Entry.t()]) :: :ok | {:error, term()}
  def check_base(gh, base_commit, entries),
    do:
      check(
        gh,
        base_commit,
        for(e <- entries, do: {e.path, {:base_mismatch, e.path}, &base?(e, &1)})
      )

  @doc """
  §6.2 step 2, for the decision's `base_attributes`: in `base_commit`, each
  `<dir>/.gitattributes` with a `blob_sha` is a regular file with that blob, and
  each without one is absent, a directory, a symlink or a submodule, which git
  doesn't read attributes from. Any other entry is a mismatch.
  """
  @spec check_attributes(GitHub.t(), String.t(), [attribute()]) :: :ok | {:error, term()}
  def check_attributes(gh, base_commit, attributes) do
    checks =
      for %{"dir" => dir, "blob_sha" => sha} <- attributes,
          do: {attributes_path(dir), {:attributes_mismatch, dir}, &attributes?(sha, &1)}

    check(gh, base_commit, checks)
  end

  @doc """
  §6.2 step 5: in `commit`, every `add` and `modify` is a blob with its `mode`
  and `new_blob_sha`, and every `delete` is absent.
  """
  @spec check_result(GitHub.t(), String.t(), [Entry.t()]) :: :ok | {:error, term()}
  def check_result(gh, commit, entries),
    do:
      check(
        gh,
        commit,
        for(e <- entries, do: {e.path, {:tree_mismatch, e.path}, &result?(e, &1)})
      )

  # Each check is `{path, mismatch, expected?}`, looked up through one cache.
  defp check(gh, commit, checks) do
    with {:ok, %{"tree" => %{"sha" => tree}}} <- GitHub.get_commit(gh, commit),
         {:ok, _cache} <- Enum.reduce_while(checks, {:ok, %{}}, &check_path(gh, tree, &1, &2)) do
      :ok
    end
  end

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
