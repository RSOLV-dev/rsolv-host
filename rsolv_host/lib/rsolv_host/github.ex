defmodule RsolvHost.GitHub do
  @moduledoc """
  The GitHub REST client of the scan and publish jobs, with the job's own
  `GITHUB_TOKEN`, for the job's own repository (`GITHUB_REPOSITORY`) only.

  Bodies are read through `RsolvHost.Http` (raw, capped). A refusal is
  `{:github, status, code}`, where `code` is a fixed atom for the status, never
  GitHub's message text. Redirects are never followed (a 3xx is a refusal), and
  only repeatable requests are retried (`retry/2`).
  """

  alias RsolvCore.StrictJson
  alias RsolvHost.Http

  @enforce_keys [:req, :repository, :graphql_url]
  defstruct @enforce_keys

  @type t :: %__MODULE__{req: Req.Request.t(), repository: String.t(), graphql_url: String.t()}
  @type error :: {:github, pos_integer(), atom()} | {:transport, term()}

  @max_body_bytes 32 * 1024 * 1024
  @codes %{
    400 => :bad_request,
    401 => :unauthorized,
    403 => :forbidden,
    404 => :not_found,
    409 => :conflict,
    422 => :unprocessable,
    429 => :rate_limited
  }

  @doc "A client for the job's repository, or the missing variable."
  @spec new(map()) :: {:ok, t()} | {:error, {:missing_env, String.t()}}
  def new(env) do
    extra = :rsolv_host |> Application.get_env(__MODULE__, []) |> Keyword.get(:req_options, [])

    with {:ok, token} <- fetch(env, "GITHUB_TOKEN", ~r/\A\S+\z/),
         {:ok, repository} <-
           fetch(env, "GITHUB_REPOSITORY", ~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/),
         false <- String.contains?(repository, "..") do
      req =
        Req.new(
          [
            base_url: env["GITHUB_API_URL"] || "https://api.github.com",
            auth: {:bearer, token},
            headers: [accept: "application/vnd.github+json", x_github_api_version: "2022-11-28"],
            retry: &retry/2,
            redirect: false,
            receive_timeout: 60_000
          ] ++ extra
        )

      {:ok,
       %__MODULE__{
         req: req,
         repository: repository,
         graphql_url: env["GITHUB_GRAPHQL_URL"] || "https://api.github.com/graphql"
       }}
    else
      true -> {:error, {:missing_env, "GITHUB_REPOSITORY"}}
      error -> error
    end
  end

  @doc """
  Req's retry policy (`RsolvHost.Http.retry/3`): only a read (the one GraphQL
  query, `viewer/1`, included), or a blob or tree (content-addressed, so writing
  it twice gives the same object), is repeated after a transient failure. An issue, comment, label, pull request, commit or ref may have been
  written when the answer was lost; it is never repeated blind.
  """
  @spec retry(Req.Request.t(), Req.Response.t() | Exception.t()) ::
          false | {:delay, non_neg_integer()}
  def retry(%Req.Request{method: method, url: %URI{path: path}} = req, result),
    do: Http.retry(req, result, repeatable?(method, path || ""))

  defp repeatable?(method, _path) when method in [:get, :head], do: true

  defp repeatable?(:post, path),
    do: String.ends_with?(path, ["/git/blobs", "/git/trees", "/graphql"])

  defp repeatable?(_method, _path), do: false

  defp fetch(env, name, format) do
    case env[name] do
      value when is_binary(value) ->
        if value =~ format, do: {:ok, value}, else: {:error, {:missing_env, name}}

      nil ->
        {:error, {:missing_env, name}}
    end
  end

  @typedoc "Who the token acts as: its login, and its database id when GraphQL gives one."
  @type actor :: %{login: String.t(), id: pos_integer() | nil}

  @doc """
  Who the token acts as, asked of GraphQL's `viewer` (`GITHUB_GRAPHQL_URL`),
  since REST's `GET /user` refuses an installation token. The two APIs name a
  bot differently (GraphQL `github-actions`, REST `github-actions[bot]`), so
  compare with `same_actor?/2`, never `==`.
  """
  @spec viewer(t()) :: {:ok, actor()} | {:error, term()}
  def viewer(gh) do
    query = %{query: "query { viewer { login databaseId } }"}

    with {:ok, %{status: 200, body: body}} <-
           Http.request(gh.req, [method: :post, url: gh.graphql_url, json: query], 64 * 1024),
         {:ok, %{"data" => %{"viewer" => %{"login" => login} = viewer}}} when is_binary(login) <-
           StrictJson.decode(body),
         id when is_nil(id) or (is_integer(id) and id > 0) <- viewer["databaseId"] do
      {:ok, %{login: login, id: id}}
    else
      {:ok, %{status: status}} -> {:error, {:github, status, code(status)}}
      {:error, _reason} = error -> error
      _malformed -> {:error, :malformed_response}
    end
  end

  @doc """
  Whether a REST `user` object is `actor`: by id when the actor has one (a
  user without an integer id is then never `actor`), else by login with a
  trailing `[bot]` stripped from both.

      iex> RsolvHost.GitHub.same_actor?(%{login: "github-actions", id: 41898282},
      ...>   %{"login" => "github-actions[bot]", "id" => 41898282})
      true
      iex> RsolvHost.GitHub.same_actor?(%{login: "github-actions", id: 41898282},
      ...>   %{"login" => "github-actions", "id" => 7})
      false
  """
  @spec same_actor?(actor(), map() | nil) :: boolean()
  def same_actor?(%{id: id}, %{"id" => user_id}) when is_integer(id) and is_integer(user_id),
    do: id == user_id

  def same_actor?(%{id: id}, _user) when is_integer(id), do: false

  def same_actor?(%{login: login}, %{"login" => user_login}) when is_binary(user_login),
    do: unbot(login) == unbot(user_login)

  def same_actor?(_actor, _user), do: false

  defp unbot(login), do: String.replace_suffix(login, "[bot]", "")

  @doc "One page (100) of the repository's open issues carrying every label in `labels`."
  @spec list_issues(t(), [String.t()], pos_integer()) :: {:ok, [map()]} | {:error, error()}
  def list_issues(gh, labels, page) do
    params = [state: "open", per_page: 100, labels: Enum.join(labels, ","), page: page]

    case call(gh, :get, "/issues", params: params) do
      {:ok, issues} when is_list(issues) -> {:ok, issues}
      {:ok, _other} -> {:error, :malformed_response}
      error -> error
    end
  end

  @doc "Creates a label; one that already exists (422) counts as created."
  @spec create_label(t(), map()) :: :ok | {:error, error()}
  def create_label(gh, label) do
    case call(gh, :post, "/labels", json: label) do
      {:ok, _label} -> :ok
      {:error, {:github, 422, _code}} -> :ok
      error -> error
    end
  end

  @doc "Creates an issue, returning GitHub's issue object."
  @spec create_issue(t(), map()) :: {:ok, map()} | {:error, error()}
  def create_issue(gh, issue), do: object(call(gh, :post, "/issues", json: issue))

  @doc "Stores `bytes` as a blob and returns its SHA."
  @spec create_blob(t(), binary()) :: {:ok, String.t()} | {:error, term()}
  def create_blob(gh, bytes),
    do:
      sha(
        call(gh, :post, "/git/blobs", json: %{content: Base.encode64(bytes), encoding: "base64"})
      )

  @doc """
  Creates a tree on `base_tree` from entries (`%{"path", "mode", "type", "sha"}`;
  a `nil` SHA deletes the path) and returns its SHA.
  """
  @spec create_tree(t(), String.t(), [map()]) :: {:ok, String.t()} | {:error, term()}
  def create_tree(gh, base_tree, entries),
    do: sha(call(gh, :post, "/git/trees", json: %{base_tree: base_tree, tree: entries}))

  @doc "Creates a commit and returns its SHA."
  @spec create_commit(t(), String.t(), String.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, term()}
  def create_commit(gh, message, tree, parents),
    do:
      sha(
        call(gh, :post, "/git/commits", json: %{message: message, tree: tree, parents: parents})
      )

  @doc "Reads a commit."
  @spec get_commit(t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_commit(gh, sha), do: object(call(gh, :get, "/git/commits/" <> hex!(sha)))

  @doc "Reads one tree, non-recursively."
  @spec get_tree(t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_tree(gh, sha), do: object(call(gh, :get, "/git/trees/" <> hex!(sha)))

  @doc "Creates `refs/heads/<branch>` at `sha` (422 if it exists)."
  @spec create_ref(t(), String.t(), String.t()) :: :ok | {:error, term()}
  def create_ref(gh, branch, sha) do
    with {:ok, _ref} <-
           call(gh, :post, "/git/refs", json: %{ref: "refs/heads/" <> branch, sha: sha}),
         do: :ok
  end

  @doc "The commit SHA `refs/heads/<branch>` points at."
  @spec get_ref(t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def get_ref(gh, branch) do
    case call(
           gh,
           :get,
           "/git/ref/heads/" <> URI.encode(branch, &(URI.char_unreserved?(&1) or &1 == ?/))
         ) do
      {:ok, %{"object" => %{"sha" => sha}}} when is_binary(sha) -> {:ok, sha}
      {:ok, _other} -> {:error, :malformed_response}
      error -> error
    end
  end

  @doc "Opens a pull request."
  @spec create_pull(t(), map()) :: {:ok, map()} | {:error, term()}
  def create_pull(gh, pull), do: object(call(gh, :post, "/pulls", json: pull))

  @doc """
  The pull requests, in any state, from `branch` of this repository into
  `base` (GitHub's `head`/`base` filter; one page of 100).
  """
  @spec list_pulls(t(), String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_pulls(gh, branch, base) do
    [owner, _name] = String.split(gh.repository, "/")
    params = [head: owner <> ":" <> branch, base: base, state: "all", per_page: 100]

    case call(gh, :get, "/pulls", params: params) do
      {:ok, pulls} when is_list(pulls) -> {:ok, pulls}
      {:ok, _other} -> {:error, :malformed_response}
      error -> error
    end
  end

  @doc "One page (100) of an issue's or pull request's comments, oldest first."
  @spec list_comments(t(), pos_integer(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def list_comments(gh, number, page) do
    case call(gh, :get, "/issues/#{number}/comments", params: [per_page: 100, page: page]) do
      {:ok, comments} when is_list(comments) -> {:ok, comments}
      {:ok, _other} -> {:error, :malformed_response}
      error -> error
    end
  end

  @doc "Adds labels to an issue or pull request."
  @spec add_labels(t(), pos_integer(), [String.t()]) :: :ok | {:error, term()}
  def add_labels(gh, number, labels) do
    with {:ok, _labels} <- call(gh, :post, "/issues/#{number}/labels", json: %{labels: labels}),
         do: :ok
  end

  @doc "Comments on an issue or pull request."
  @spec comment(t(), pos_integer(), String.t()) :: :ok | {:error, term()}
  def comment(gh, number, body) do
    with {:ok, _comment} <- call(gh, :post, "/issues/#{number}/comments", json: %{body: body}),
         do: :ok
  end

  @doc "How `head` relates to `base`: `ahead`, `behind`, `diverged` or `identical`."
  @spec compare(t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def compare(gh, base, head) do
    segment =
      URI.encode(base, &URI.char_unreserved?/1) <>
        "..." <> URI.encode(head, &URI.char_unreserved?/1)

    case call(gh, :get, "/compare/" <> segment, max_bytes: 64 * 1024 * 1024) do
      {:ok, %{"status" => status}} when status in ~w(ahead behind diverged identical) ->
        {:ok, status}

      {:ok, _other} ->
        {:error, :malformed_response}

      error ->
        error
    end
  end

  defp sha({:ok, %{"sha" => sha}}) when is_binary(sha), do: {:ok, hex!(sha)}
  defp sha({:ok, _other}), do: {:error, :malformed_response}
  defp sha(error), do: error

  defp hex!(sha) do
    true = sha =~ ~r/\A[0-9a-f]{40}\z/
    sha
  end

  @doc """
  Sends a request under `/repos/{owner}/{name}` and decodes the JSON answer
  (at most 32 MiB, or `opts[:max_bytes]`).
  """
  @spec call(t(), atom(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def call(gh, method, path, opts \\ []) do
    {max_bytes, opts} = Keyword.pop(opts, :max_bytes, @max_body_bytes)

    case Http.request(
           gh.req,
           [method: method, url: "/repos/#{gh.repository}#{path}"] ++ opts,
           max_bytes
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> decode(body, max_bytes)
      {:ok, %{status: status}} -> {:error, {:github, status, code(status)}}
      error -> error
    end
  end

  defp decode(body, max_bytes) do
    case StrictJson.decode(body, max_bytes: max_bytes, max_depth: 64) do
      {:ok, json} -> {:ok, json}
      {:error, _reason} -> {:error, :malformed_response}
    end
  end

  @doc false
  @spec object({:ok, term()} | {:error, term()}) :: {:ok, map()} | {:error, term()}
  def object({:ok, %{} = object}), do: {:ok, object}
  def object({:ok, _other}), do: {:error, :malformed_response}
  def object(error), do: error

  defp code(status) when status >= 500, do: :server_error
  defp code(status), do: Map.get(@codes, status, :refused)
end
