defmodule RsolvCore.Canonicalize do
  @moduledoc """
  Canonicalization (RFC-150 §4.2, §4.2a): a parsed patch plus trusted base facts
  gives the canonical change set and the post-image of every added or modified
  file. Post-images are the base content with the hunks applied exactly (no
  offset, no fuzz); the patch's `index` lines play no part.

  Refusals, as `{:error, {reason, path}}`:
  - `:missing_base_fact` — the facts don't cover the path or an ancestor;
  - `:ancestor_not_tree` — an ancestor of the path is a blob (file or symlink)
    or a gitlink in base, or exists beneath a missing directory;
  - `:filter_attribute` — a base `.gitattributes` puts the path under a filter
    (`RsolvCore.GitAttributes`);
  - `:add_exists` — an add of a path base has;
  - `:modify_missing` — a modify or delete of a path base doesn't have;
  - `:not_regular_file` — a modify or delete of a symlink, gitlink or tree;
  - `:hunk_mismatch` — a hunk that doesn't apply, or a delete that doesn't empty the file;
  - `:no_change` — a modify whose result equals its base;
  - `{:path_conflict, nil}` — `x` and `x/y` both added or modified.
  """

  alias RsolvCore.{BaseFacts, ChangeSet, GitAttributes, Patch}
  alias RsolvCore.ChangeSet.Entry

  @regular ["100644", "100755"]

  @type reason ::
          :missing_base_fact
          | :ancestor_not_tree
          | :filter_attribute
          | :add_exists
          | :modify_missing
          | :not_regular_file
          | :hunk_mismatch
          | :no_change
          | :path_conflict

  @doc "The change set and post-images of `diffs` against `facts`."
  @spec change_set([Patch.FileDiff.t()], BaseFacts.t()) ::
          {:ok, [Entry.t()], %{String.t() => binary()}} | {:error, {reason(), String.t() | nil}}
  def change_set(diffs, %BaseFacts{} = facts) do
    attributes = GitAttributes.compile(facts.attributes)

    diffs
    |> Enum.sort_by(& &1.path)
    |> Enum.reduce_while({:ok, [], %{}}, fn diff, {:ok, entries, images} ->
      case entry(diff, facts, attributes) do
        {:ok, entry, nil} ->
          {:cont, {:ok, [entry | entries], images}}

        {:ok, entry, image} ->
          {:cont, {:ok, [entry | entries], Map.put(images, entry.path, image)}}

        {:error, reason} ->
          {:halt, {:error, {reason, diff.path}}}
      end
    end)
    |> checked()
  end

  defp checked({:ok, entries, images}) do
    entries = Enum.reverse(entries)

    case entries |> ChangeSet.to_json() |> ChangeSet.from_json() do
      {:ok, _valid} -> {:ok, entries, images}
      {:error, reason} -> {:error, {reason, nil}}
    end
  end

  defp checked(error), do: error

  defp entry(%Patch.FileDiff{path: path, op: op, hunks: hunks}, facts, attributes) do
    with :ok <- covered(path, facts),
         :ok <- ancestors(path, facts),
         :ok <- unfiltered(path, attributes),
         {:ok, fact, base} <- base(op, Map.fetch!(facts.paths, path)),
         {:ok, image} <- apply_hunks(base, hunks) do
      build(op, path, fact, base, image)
    end
  end

  defp covered(path, facts) do
    if Enum.all?([path | BaseFacts.ancestors(path)], &Map.has_key?(facts.paths, &1)),
      do: :ok,
      else: {:error, :missing_base_fact}
  end

  defp ancestors(path, facts) do
    types = path |> BaseFacts.ancestors() |> Enum.map(&facts.paths[&1].type)
    {_trees, rest} = Enum.split_while(types, &(&1 == :tree))

    if Enum.all?(rest, &(&1 == :missing)),
      do: :ok,
      else: {:error, :ancestor_not_tree}
  end

  defp unfiltered(path, attributes),
    do:
      if(GitAttributes.filtered?(path, attributes),
        do: {:error, :filter_attribute},
        else: :ok
      )

  defp base(:add, %{type: :missing} = fact), do: {:ok, fact, ""}
  defp base(:add, _fact), do: {:error, :add_exists}

  defp base(_op, %{type: :blob, mode: mode, content: content} = fact) when mode in @regular,
    do: {:ok, fact, content}

  defp base(_op, %{type: :missing}), do: {:error, :modify_missing}
  defp base(_op, _fact), do: {:error, :not_regular_file}

  defp build(:add, path, _fact, _base, image),
    do:
      {:ok,
       %Entry{
         path: path,
         op: :add,
         base_mode: nil,
         base_blob_sha: nil,
         mode: "100644",
         new_blob_sha: ChangeSet.blob_sha(image)
       }, image}

  defp build(:modify, _path, _fact, same, same), do: {:error, :no_change}

  defp build(:modify, path, fact, _base, image),
    do:
      {:ok,
       %Entry{
         path: path,
         op: :modify,
         base_mode: fact.mode,
         base_blob_sha: fact.sha,
         mode: fact.mode,
         new_blob_sha: ChangeSet.blob_sha(image)
       }, image}

  defp build(:delete, path, fact, _base, ""),
    do:
      {:ok,
       %Entry{
         path: path,
         op: :delete,
         base_mode: fact.mode,
         base_blob_sha: fact.sha,
         mode: nil,
         new_blob_sha: nil
       }, nil}

  defp build(:delete, _path, _fact, _base, _left_over), do: {:error, :hunk_mismatch}

  @doc """
  Applies `hunks` to `base` exactly: every context and deleted line must match
  the base at the hunk's own position, hunks must be in order and must not
  overlap, and only the result's last line may lack a newline.
  """
  @spec apply_hunks(binary(), [Patch.FileDiff.hunk()]) ::
          {:ok, binary()} | {:error, :hunk_mismatch}
  def apply_hunks(base, hunks), do: base |> lines() |> patch_lines(1, hunks, [])

  defp lines(""), do: []

  defp lines(text) do
    case text |> :binary.split("\n", [:global]) |> Enum.reverse() do
      ["" | rest] -> rest |> Enum.reverse() |> Enum.map(&{&1, true})
      [last | rest] -> (rest |> Enum.reverse() |> Enum.map(&{&1, true})) ++ [{last, false}]
    end
  end

  defp patch_lines(rest, _line, [], acc), do: finish(Enum.reverse(acc, rest))

  defp patch_lines(rest, line, [%{old_start: start, old_count: count, lines: hunk} | more], acc) do
    first = if count == 0, do: start + 1, else: start
    old = for {kind, text, newline?} <- hunk, kind != :add, do: {text, newline?}
    new = for {kind, text, newline?} <- hunk, kind != :del, do: {text, newline?}
    skip = first - line

    with true <- skip >= 0,
         {kept, rest} when length(kept) == skip <- Enum.split(rest, skip),
         {^old, rest} <- Enum.split(rest, length(old)) do
      patch_lines(rest, first + length(old), more, Enum.reverse(new, Enum.reverse(kept, acc)))
    else
      _mismatch -> {:error, :hunk_mismatch}
    end
  end

  defp finish(lines) do
    if lines |> Enum.drop(-1) |> Enum.all?(&elem(&1, 1)),
      do:
        {:ok,
         Enum.map_join(lines, fn {text, newline?} -> if newline?, do: text <> "\n", else: text end)},
      else: {:error, :hunk_mismatch}
  end

  @doc false
  # Runs a reject vector of test/vectors/patch.json to the stage that refuses it:
  # {stage, reason, path}. Used by this repository's tests and the platform's.
  @spec run(map()) :: {String.t(), String.t(), String.t() | nil} | {:accepted, nil, nil}
  def run(%{"patch" => patch, "base_sha" => base, "base_facts" => facts_json}) do
    with {:parse, {:ok, diffs}} <- {:parse, patch |> Base.decode64!() |> Patch.parse()},
         {:ok, facts} <- BaseFacts.decode(facts_json, base, Patch.touched_paths(diffs)),
         {:canonicalize, {:error, {reason, path}}} <- {:canonicalize, change_set(diffs, facts)} do
      {"canonicalize", Atom.to_string(reason), path}
    else
      {:parse, {:error, reason}} -> {"parse", Atom.to_string(reason), nil}
      {:error, :invalid_base_facts} -> {"base_facts", "invalid_base_facts", nil}
      {:canonicalize, {:ok, _entries, _images}} -> {:accepted, nil, nil}
    end
  end
end
