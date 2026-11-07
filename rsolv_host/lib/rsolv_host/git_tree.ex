defmodule RsolvHost.GitTree do
  @moduledoc """
  Checks a change set against GitHub's trees (RFC-150 §6.2): the base before any
  write (step 2), and the written commits after (step 5).

  Lookups read one non-recursive tree per directory, memoized by tree SHA, so a
  change set costs one request per directory it touches, and a truncated listing
  is refused rather than trusted. A path whose parent is a blob or a symlink is
  never looked through.
  """

  alias RsolvCore.ChangeSet.Entry
  alias RsolvHost.GitHub

  @type found :: %{mode: String.t(), type: String.t(), sha: String.t()}
  @type cache :: %{optional(String.t()) => [map()]}

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
    do: check(gh, base_commit, entries, :base_mismatch, &base?/2)

  @doc """
  §6.2 step 5: in `commit`, every `add` and `modify` is a blob with its `mode`
  and `new_blob_sha`, and every `delete` is absent.
  """
  @spec check_result(GitHub.t(), String.t(), [Entry.t()]) :: :ok | {:error, term()}
  def check_result(gh, commit, entries),
    do: check(gh, commit, entries, :tree_mismatch, &result?/2)

  defp check(gh, commit, entries, mismatch, expected?) do
    with {:ok, %{"tree" => %{"sha" => tree}}} <- GitHub.get_commit(gh, commit),
         {:ok, _cache} <-
           Enum.reduce_while(
             entries,
             {:ok, %{}},
             &check_entry(gh, tree, &1, &2, mismatch, expected?)
           ) do
      :ok
    end
  end

  defp check_entry(gh, tree, entry, {:ok, cache}, mismatch, expected?) do
    case lookup(gh, tree, entry.path, cache) do
      {:error, :ancestor_not_tree} ->
        {:halt, {:error, {mismatch, entry.path}}}

      {:error, _reason} = error ->
        {:halt, error}

      found ->
        if expected?.(entry, found),
          do: {:cont, {:ok, cache_of(found)}},
          else: {:halt, {:error, {mismatch, entry.path}}}
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
end
