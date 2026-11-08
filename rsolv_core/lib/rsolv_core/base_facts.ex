defmodule RsolvCore.BaseFacts do
  @moduledoc """
  Trusted facts about the base commit (RFC-150 §4.2a): what the host read from
  a fresh checkout of `base_sha`, with hardened git, before any sandbox started.
  They're the only base content the platform canonicalizes against.

  JSON form (`decode/3`, `to_json/1`):

      {"base_sha": "<40 hex>",
       "paths": {"<path>": {"type": "blob", "mode": "100644" | "100755", "sha": "<40 hex>", "content": "<base64>"}
                         | {"type": "blob", "mode": "120000", "sha": "<40 hex>"}
                         | {"type": "tree"} | {"type": "commit"} | {"type": "missing"}},
       "attributes": {"<directory, or \\"\\" for the root>": "<base64 of its .gitattributes>"}}

  `paths` covers exactly the requested paths and their ancestor directories,
  and only `missing` lies beneath an ancestor that isn't a tree. A regular blob
  carries content (at most 5 MiB) that must hash to `sha`.
  `attributes` keys are the root and directories on those chains that are trees.

      iex> RsolvCore.BaseFacts.ancestors("a/b/c.js")
      ["a", "a/b"]
  """

  alias RsolvCore.ChangeSet

  @enforce_keys [:base_sha, :paths, :attributes]
  defstruct @enforce_keys

  @type fact ::
          %{type: :blob, mode: String.t(), sha: String.t(), content: binary() | nil}
          | %{type: :tree | :commit | :missing}
  @type t :: %__MODULE__{
          base_sha: String.t(),
          paths: %{String.t() => fact()},
          attributes: %{String.t() => binary()}
        }

  @max_paths 4_096
  @max_content_bytes 5 * 1024 * 1024
  @max_attributes_bytes 1024 * 1024
  @regular ["100644", "100755"]

  @doc "The ancestor directories of `path`, shallowest first."
  @spec ancestors(String.t()) :: [String.t()]
  def ancestors(path) do
    segments = path |> String.split("/") |> Enum.drop(-1)
    for n <- 1..length(segments)//1, do: segments |> Enum.take(n) |> Enum.join("/")
  end

  @doc "Every path base facts must cover for `paths`: each one and its ancestors, sorted, unique."
  @spec required_paths([String.t()]) :: [String.t()]
  def required_paths(paths),
    do: paths |> Enum.flat_map(&[&1 | ancestors(&1)]) |> Enum.uniq() |> Enum.sort()

  @doc """
  Decodes the JSON form (as `RsolvCore.StrictJson` decoded it) and checks that it
  is for `base_sha` and covers exactly `requested` and their ancestors.
  """
  @spec decode(term(), String.t(), [String.t()]) :: {:ok, t()} | {:error, :invalid_base_facts}
  def decode(
        %{"base_sha" => base_sha, "paths" => %{} = paths, "attributes" => %{} = attributes} = json,
        base_sha,
        requested
      )
      when map_size(json) == 3 and map_size(paths) <= @max_paths and is_list(requested) do
    with true <- Enum.all?(requested, &is_binary/1),
         true <- paths |> Map.keys() |> Enum.sort() == required_paths(requested),
         {:ok, facts} <- facts(paths),
         true <- consistent?(facts),
         {:ok, attrs} <- attributes(attributes, facts) do
      {:ok, %__MODULE__{base_sha: base_sha, paths: facts, attributes: attrs}}
    else
      _invalid -> {:error, :invalid_base_facts}
    end
  end

  def decode(_json, _base_sha, _requested), do: {:error, :invalid_base_facts}

  @doc "The JSON form of `facts`, the inverse of `decode/3`."
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = facts) do
    %{
      "base_sha" => facts.base_sha,
      "paths" => Map.new(facts.paths, fn {path, fact} -> {path, fact_json(fact)} end),
      "attributes" => Map.new(facts.attributes, fn {dir, text} -> {dir, Base.encode64(text)} end)
    }
  end

  defp fact_json(%{type: :blob, mode: mode, sha: sha, content: nil}),
    do: %{"type" => "blob", "mode" => mode, "sha" => sha}

  defp fact_json(%{type: :blob, mode: mode, sha: sha, content: content}),
    do: %{"type" => "blob", "mode" => mode, "sha" => sha, "content" => Base.encode64(content)}

  defp fact_json(%{type: type}), do: %{"type" => Atom.to_string(type)}

  defp facts(paths) do
    Enum.reduce_while(paths, {:ok, %{}}, fn {path, json}, {:ok, acc} ->
      case ChangeSet.valid_path?(path) && fact(json) do
        {:ok, fact} -> {:cont, {:ok, Map.put(acc, path, fact)}}
        _invalid -> {:halt, :error}
      end
    end)
  end

  defp fact(%{"type" => "blob", "mode" => mode, "sha" => sha, "content" => encoded} = json)
       when map_size(json) == 4 and mode in @regular and is_binary(encoded) do
    with {:ok, content} when byte_size(content) <= @max_content_bytes <- Base.decode64(encoded),
         ^sha <- ChangeSet.blob_sha(content) do
      {:ok, %{type: :blob, mode: mode, sha: sha, content: content}}
    else
      _invalid -> :error
    end
  end

  defp fact(%{"type" => "blob", "mode" => "120000", "sha" => sha} = json)
       when map_size(json) == 3 do
    if is_binary(sha) and sha =~ ~r/\A[0-9a-f]{40}\z/,
      do: {:ok, %{type: :blob, mode: "120000", sha: sha, content: nil}},
      else: :error
  end

  defp fact(%{"type" => "tree"} = json) when map_size(json) == 1, do: {:ok, %{type: :tree}}
  defp fact(%{"type" => "commit"} = json) when map_size(json) == 1, do: {:ok, %{type: :commit}}
  defp fact(%{"type" => "missing"} = json) when map_size(json) == 1, do: {:ok, %{type: :missing}}
  defp fact(_json), do: :error

  defp consistent?(facts) do
    Enum.all?(facts, fn
      {_path, %{type: :missing}} -> true
      {path, _fact} -> path |> ancestors() |> Enum.all?(&match?(%{type: :tree}, facts[&1]))
    end)
  end

  defp attributes(attributes, facts) do
    Enum.reduce_while(attributes, {:ok, %{}}, fn {dir, encoded}, {:ok, acc} ->
      with true <- dir == "" or match?(%{type: :tree}, facts[dir]),
           true <- is_binary(encoded),
           {:ok, text} when byte_size(text) <= @max_attributes_bytes <- Base.decode64(encoded) do
        {:cont, {:ok, Map.put(acc, dir, text)}}
      else
        _invalid -> {:halt, :error}
      end
    end)
  end
end
