defmodule RsolvHost.FakeGithub do
  @moduledoc """
  An in-memory GitHub repository behind `Req.Test`, for the Git Data API, pull
  requests, labels, comments and compare. Blobs are keyed by their real git blob
  SHA (`RsolvCore.ChangeSet.blob_sha/1`); trees are nested and keyed by a SHA-1
  over their sorted entries, as GitHub's are by content. Every request is
  recorded, so a test can assert what was, or wasn't, written.

  As on GitHub, a commit's SHA covers its author date, so writing the same
  commit twice gives two SHAs; a second open pull request for the same head
  and base is refused with 422; adding labels is a union. `drop_response/3`
  commits a write and then loses its response.
  """

  alias RsolvCore.ChangeSet

  @repo "/repos/acme/app"

  @doc "Starts an empty repository and routes `RsolvHost.GitHub` to it."
  @spec start() :: pid()
  def start do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          blobs: %{},
          trees: %{},
          commits: %{},
          refs: %{},
          requests: [],
          pulls: [],
          labels: [],
          comments: [],
          compare: "identical",
          tamper: nil,
          truncated: false,
          delays: %{},
          drops: MapSet.new(),
          clock: 0
        }
      end)

    Req.Test.stub(RsolvHost.GitHub, &handle(agent, &1))
    agent
  end

  @doc """
  Builds a base commit from `%{path => {mode, bytes}}` (`"100644"`, `"100755"` or
  `"120000"` for a symlink, whose bytes are its target) and returns its SHA.
  """
  @spec seed(pid(), %{String.t() => {String.t(), binary()}}) :: String.t()
  def seed(agent, files) do
    Agent.get_and_update(agent, fn state ->
      {state, nested} =
        Enum.reduce(files, {state, %{}}, fn {path, {mode, bytes}}, {state, nested} ->
          sha = ChangeSet.blob_sha(bytes)

          {put_in(state.blobs[sha], bytes),
           put_path(nested, String.split(path, "/"), {:blob, mode, sha})}
        end)

      {state, tree} = store(state, nested)
      {state, commit} = commit(state, tree, [], "base")
      {commit, state}
    end)
  end

  @doc "Every request, oldest first, as `{method, path}` below the repository."
  @spec requests(pid()) :: [{String.t(), String.t()}]
  def requests(agent), do: Agent.get(agent, &Enum.reverse(&1.requests))

  @doc "The recorded pull requests, labels and comments."
  @spec writes(pid()) :: %{pulls: [map()], labels: [map()], comments: [map()]}
  def writes(agent),
    do:
      Agent.get(
        agent,
        &%{
          pulls: &1.pulls |> Enum.reverse() |> Enum.map(fn pull -> pull.request end),
          labels: &1.labels,
          comments: Enum.map(&1.comments, fn {n, _id, body} -> {n, body} end)
        }
      )

  @doc "Rewrites each tree entry a later `POST /git/trees` writes (to fake a misbehaving GitHub)."
  @spec tamper(pid(), (map() -> map())) :: :ok
  def tamper(agent, fun), do: Agent.update(agent, &%{&1 | tamper: fun})

  @doc """
  Sets what `GET /compare` reports (`ahead`, `behind`, `diverged`, `identical`),
  or `:not_found` for a 404.
  """
  @spec compare(pid(), String.t() | :not_found) :: :ok
  def compare(agent, status), do: Agent.update(agent, &%{&1 | compare: status})

  @doc "Delays GitHub's answer to every `method` request to `path` by `ms` (a slow write)."
  @spec delay(pid(), String.t(), String.t(), non_neg_integer()) :: :ok
  def delay(agent, method, path, ms),
    do: Agent.update(agent, &put_in(&1.delays[{method, path}], ms))

  @doc """
  The next `method` request to `path` is carried out, then its connection
  closes before the answer: the client can't tell whether it was written.
  """
  @spec drop_response(pid(), String.t(), String.t()) :: :ok
  def drop_response(agent, method, path),
    do: Agent.update(agent, &%{&1 | drops: MapSet.put(&1.drops, {method, path})})

  @doc "Opens a pull request directly, as someone else (or an earlier run) would have."
  @spec put_pull(pid(), map()) :: :ok
  def put_pull(agent, request),
    do: Agent.update(agent, fn state -> state |> open_pull(request) |> elem(1) end)

  @doc "Makes every tree listing say `truncated: true`."
  @spec truncate(pid()) :: :ok
  def truncate(agent), do: Agent.update(agent, &%{&1 | truncated: true})

  @doc "Points `refs/heads/<branch>` at `sha`."
  @spec put_ref(pid(), String.t(), String.t()) :: :ok
  def put_ref(agent, branch, sha),
    do: Agent.update(agent, &put_in(&1.refs["refs/heads/" <> branch], sha))

  @doc "Writes a commit directly (`tree` from `commit_info/2`), returning its SHA."
  @spec put_commit(pid(), String.t(), [String.t()], String.t()) :: String.t()
  def put_commit(agent, tree, parents, message),
    do:
      Agent.get_and_update(agent, fn state ->
        {state, sha} = commit(state, tree, parents, message)
        {sha, state}
      end)

  @doc "The commit's tree as `%{path => {mode, bytes}}`, for assertions."
  @spec files(pid(), String.t()) :: %{String.t() => {String.t(), binary()}}
  def files(agent, commit) do
    Agent.get(agent, fn state -> flatten(state, state.commits[commit].tree, "") end)
  end

  @doc "A commit's parents and message."
  @spec commit_info(pid(), String.t()) :: %{
          parents: [String.t()],
          message: String.t(),
          tree: String.t()
        }
  def commit_info(agent, sha), do: Agent.get(agent, & &1.commits[sha])

  defp flatten(state, tree, prefix) do
    for entry <- state.trees[tree], reduce: %{} do
      acc ->
        path = prefix <> entry["path"]

        case entry["type"] do
          "tree" -> Map.merge(acc, flatten(state, entry["sha"], path <> "/"))
          "blob" -> Map.put(acc, path, {entry["mode"], state.blobs[entry["sha"]]})
        end
    end
  end

  defp handle(agent, conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    body = if raw == "", do: nil, else: JSON.decode!(raw)
    @repo <> path = conn.request_path
    Agent.update(agent, &%{&1 | requests: [{conn.method, path} | &1.requests]})
    query = URI.decode_query(conn.query_string)

    {status, json} =
      Agent.get_and_update(agent, &route(&1, conn.method, path, body || query))

    agent |> Agent.get(& &1.delays[{conn.method, path}]) |> then(&Process.sleep(&1 || 0))

    dropped? =
      Agent.get_and_update(agent, fn state ->
        {MapSet.member?(state.drops, {conn.method, path}),
         %{state | drops: MapSet.delete(state.drops, {conn.method, path})}}
      end)

    if dropped?,
      do: Req.Test.transport_error(conn, :closed),
      else: conn |> Plug.Conn.put_status(status) |> Req.Test.json(json)
  end

  defp route(state, "POST", "/git/blobs", %{"content" => content, "encoding" => "base64"}) do
    bytes = Base.decode64!(content)
    sha = ChangeSet.blob_sha(bytes)
    {{201, %{sha: sha}}, put_in(state.blobs[sha], bytes)}
  end

  defp route(state, "POST", "/git/trees", %{"base_tree" => base, "tree" => entries}) do
    nested =
      Enum.reduce(entries, load(state, base), fn entry, nested ->
        entry = if state.tamper, do: state.tamper.(entry), else: entry
        segments = String.split(entry["path"], "/")

        case entry["sha"] do
          nil -> delete_path(nested, segments)
          sha -> put_path(nested, segments, {:blob, entry["mode"], sha})
        end
      end)

    {state, sha} = store(state, nested)
    {{201, %{sha: sha}}, state}
  end

  defp route(state, "GET", "/git/trees/" <> sha, _query) do
    case state.trees[sha] do
      nil -> {{404, %{message: "Not Found"}}, state}
      entries -> {{200, %{sha: sha, tree: entries, truncated: state.truncated}}, state}
    end
  end

  defp route(state, "POST", "/git/commits", %{
         "message" => message,
         "tree" => tree,
         "parents" => parents
       }) do
    {state, sha} = commit(state, tree, parents, message)
    {{201, %{sha: sha}}, state}
  end

  defp route(state, "GET", "/git/commits/" <> sha, _query) do
    case state.commits[sha] do
      nil ->
        {{404, %{}}, state}

      commit ->
        json = %{
          sha: sha,
          tree: %{sha: commit.tree},
          parents: Enum.map(commit.parents, &%{sha: &1}),
          message: commit.message
        }

        {{200, json}, state}
    end
  end

  defp route(state, "POST", "/git/refs", %{"ref" => ref, "sha" => sha}) do
    if Map.has_key?(state.refs, ref),
      do: {{422, %{message: "Reference already exists"}}, state},
      else: {{201, %{ref: ref, object: %{sha: sha}}}, put_in(state.refs[ref], sha)}
  end

  defp route(state, "GET", "/git/ref/heads/" <> branch, _query) do
    case state.refs["refs/heads/" <> URI.decode(branch)] do
      nil -> {{404, %{}}, state}
      sha -> {{200, %{ref: "refs/heads/" <> branch, object: %{sha: sha}}}, state}
    end
  end

  defp route(state, "POST", "/pulls", body) do
    if Enum.any?(state.pulls, &(&1.state == "open" and same_pull?(&1, body))),
      do: {{422, %{message: "Validation Failed"}}, state},
      else:
        state
        |> open_pull(body)
        |> then(fn {pull, state} -> {{201, pull_json(state, pull)}, state} end)
  end

  defp route(state, "GET", "/pulls", %{"head" => "acme:" <> head, "base" => base}) do
    pulls =
      for pull <- Enum.reverse(state.pulls),
          same_pull?(pull, %{"head" => head, "base" => base}),
          do: pull_json(state, pull)

    {{200, pulls}, state}
  end

  defp route(state, "GET", "/issues/" <> rest, %{"page" => page}) do
    [n, "comments"] = String.split(rest, "/")
    issue = String.to_integer(n)
    comments = for {^issue, id, %{"body" => body}} <- state.comments, do: %{id: id, body: body}
    {{200, comments |> Enum.chunk_every(100) |> Enum.at(String.to_integer(page) - 1, [])}, state}
  end

  defp route(state, "POST", "/issues/" <> rest, body) do
    case String.split(rest, "/") do
      [n, "labels"] ->
        n = String.to_integer(n)
        state = %{state | labels: state.labels ++ [{n, body}]}

        {{200, []},
         %{
           state
           | pulls:
               Enum.map(
                 state.pulls,
                 &if(&1.number == n,
                   do: %{&1 | labels: Enum.uniq(&1.labels ++ body["labels"])},
                   else: &1
                 )
               )
         }}

      [n, "comments"] ->
        id = length(state.comments) + 1

        {{201, %{id: id}},
         %{state | comments: state.comments ++ [{String.to_integer(n), id, body}]}}
    end
  end

  defp route(%{compare: :not_found} = state, "GET", "/compare/" <> _range, _query),
    do: {{404, %{message: "Not Found"}}, state}

  defp route(state, "GET", "/compare/" <> _range, _query),
    do: {{200, %{status: state.compare}}, state}

  defp load(_state, nil), do: %{}

  defp load(state, sha) do
    Map.new(state.trees[sha], fn
      %{"type" => "tree", "path" => name, "sha" => sub} ->
        {name, {:tree, load(state, sub)}}

      %{"type" => "blob", "path" => name, "mode" => mode, "sha" => blob} ->
        {name, {:blob, mode, blob}}
    end)
  end

  defp put_path(nested, [name], leaf), do: Map.put(nested, name, leaf)

  defp put_path(nested, [dir | rest], leaf) do
    sub =
      case nested[dir] do
        {:tree, sub} -> sub
        _absent_or_blob -> %{}
      end

    Map.put(nested, dir, {:tree, put_path(sub, rest, leaf)})
  end

  defp delete_path(nested, [name]), do: Map.delete(nested, name)

  defp delete_path(nested, [dir | rest]) do
    case nested[dir] do
      {:tree, sub} ->
        sub = delete_path(sub, rest)

        if map_size(sub) == 0,
          do: Map.delete(nested, dir),
          else: Map.put(nested, dir, {:tree, sub})

      _other ->
        nested
    end
  end

  defp store(state, nested) do
    {state, entries} =
      Enum.reduce(Enum.sort(nested), {state, []}, fn
        {name, {:tree, sub}}, {state, entries} ->
          {state, sha} = store(state, sub)

          {state,
           [%{"path" => name, "mode" => "040000", "type" => "tree", "sha" => sha} | entries]}

        {name, {:blob, mode, sha}}, {state, entries} ->
          {state, [%{"path" => name, "mode" => mode, "type" => "blob", "sha" => sha} | entries]}
      end)

    entries = Enum.reverse(entries)
    sha = :sha |> :crypto.hash(:erlang.term_to_binary(entries)) |> Base.encode16(case: :lower)
    {put_in(state.trees[sha], entries), sha}
  end

  # The SHA covers a clock that ticks on every commit, as GitHub's author date does.
  defp commit(state, tree, parents, message) do
    state = %{state | clock: state.clock + 1}

    sha =
      :sha
      |> :crypto.hash(:erlang.term_to_binary({tree, parents, message, state.clock}))
      |> Base.encode16(case: :lower)

    {put_in(state.commits[sha], %{tree: tree, parents: parents, message: message}), sha}
  end

  defp open_pull(state, request) do
    number = 100 + length(state.pulls)

    pull = %{
      number: number,
      request: request,
      state: "open",
      labels: []
    }

    {pull, %{state | pulls: [pull | state.pulls]}}
  end

  defp same_pull?(%{request: request}, %{"head" => head, "base" => base}),
    do: request["head"] == head and request["base"] == base

  # As on GitHub, a pull request's head is wherever its branch points now.
  defp pull_json(state, pull) do
    %{
      number: pull.number,
      html_url: "https://github.com/acme/app/pull/#{pull.number}",
      state: pull.state,
      title: pull.request["title"],
      body: pull.request["body"],
      head: %{ref: pull.request["head"], sha: state.refs["refs/heads/" <> pull.request["head"]]},
      base: %{ref: pull.request["base"]},
      labels: Enum.map(pull.labels, &%{name: &1})
    }
  end
end
