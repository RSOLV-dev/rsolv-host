defmodule RsolvHost.GitHub do
  @moduledoc """
  The GitHub REST client of the scan and publish jobs, with the job's own
  `GITHUB_TOKEN`, for the job's own repository (`GITHUB_REPOSITORY`) only.

  Bodies are read through `RsolvHost.Http` (raw, capped). A refusal is
  `{:github, status, code}`, where `code` is a fixed atom for the status, never
  GitHub's message text.
  """

  alias RsolvCore.StrictJson
  alias RsolvHost.Http

  @enforce_keys [:req, :repository]
  defstruct @enforce_keys

  @type t :: %__MODULE__{req: Req.Request.t(), repository: String.t()}
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
            retry: :transient,
            receive_timeout: 60_000
          ] ++ extra
        )

      {:ok, %__MODULE__{req: req, repository: repository}}
    else
      true -> {:error, {:missing_env, "GITHUB_REPOSITORY"}}
      error -> error
    end
  end

  defp fetch(env, name, format) do
    case env[name] do
      value when is_binary(value) ->
        if value =~ format, do: {:ok, value}, else: {:error, {:missing_env, name}}

      nil ->
        {:error, {:missing_env, name}}
    end
  end

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
