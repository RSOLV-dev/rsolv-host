defmodule RsolvHost.Platform do
  @moduledoc """
  HTTP client for the RSOLV platform. The platform is addressed by an absolute DNS
  name, so a runner's search domains can't redirect the lookup (Burrito spike:
  musl/NODATA), while TLS still verifies the bare name.

  Response bodies are read raw (never decompressed), capped, and decoded with
  `RsolvCore.StrictJson`. A refusal is `{:platform, status, error_code}`, where
  the code is the platform's `error` identifier or `nil`; error bodies are never
  logged.
  """

  alias RsolvCore.{Relay, StrictJson}
  alias RsolvHost.Http

  @allowed %{
    "https://api.rsolv.ai." => "api.rsolv.ai",
    "https://api.rsolv.dev." => "api.rsolv.dev",
    "https://api.rsolv-staging.com." => "api.rsolv-staging.com"
  }
  @max_body_bytes 16 * 1024 * 1024
  @max_post_images_bytes 64 * 1024 * 1024
  @phases %{validation: "validation", mitigation: "mitigation"}

  @type token :: %{
          raw: String.t(),
          expires_at: DateTime.t(),
          binding: %{optional(String.t()) => String.t()}
        }
  @type error :: {:platform, pos_integer(), String.t() | nil} | {:transport, term()}
  @type phase :: :validation | :mitigation

  @doc "A `Req` request for the platform URL in `RSOLV_API_URL`, or the default; any other URL is refused."
  @spec req(map()) :: {:ok, Req.Request.t()} | {:error, :api_url_not_allowed}
  def req(env) do
    url = env["RSOLV_API_URL"] || Application.fetch_env!(:rsolv_host, :api_url)
    extra = :rsolv_host |> Application.get_env(__MODULE__, []) |> Keyword.get(:req_options, [])

    case Map.fetch(@allowed, url) do
      {:ok, hostname} ->
        {:ok,
         Req.new(
           [
             base_url: url,
             retry: :transient,
             receive_timeout: 120_000,
             raw: true,
             connect_options: [
               hostname: hostname,
               transport_opts: [cacerts: :public_key.cacerts_get()]
             ]
           ] ++ extra
         )}

      :error ->
        {:error, :api_url_not_allowed}
    end
  end

  @doc "Exchanges a GitHub Actions OIDC token for a run token (`issue` is `nil` for scan)."
  @spec exchange(Req.Request.t(), String.t(), pos_integer() | nil) ::
          {:ok, token()} | {:error, term()}
  def exchange(req, oidc_token, issue) do
    req
    |> call(:post, "/api/v1/runs/token",
      json: %{oidc_token: oidc_token, issue: issue, protocol_version: Relay.protocol_version()}
    )
    |> token()
  end

  @doc "Refreshes run token `raw` with a fresh OIDC token from the same job."
  @spec refresh(Req.Request.t(), String.t(), String.t()) :: {:ok, token()} | {:error, term()}
  def refresh(req, raw, oidc_token) do
    req
    |> call(:post, "/api/v1/runs/token/refresh",
      auth: {:bearer, raw},
      json: %{oidc_token: oidc_token, protocol_version: Relay.protocol_version()}
    )
    |> token()
  end

  @doc "Registers the scan's issues and scan data (scan role)."
  @spec register(Req.Request.t(), String.t(), map()) :: {:ok, map()} | {:error, error()}
  def register(req, raw, body),
    do: call(req, :post, "/api/v1/runs/register", auth: {:bearer, raw}, json: body)

  @doc "Starts a VALIDATE or MITIGATE session; a cached result comes back as `{:cached, result}`."
  @spec start_session(Req.Request.t(), String.t(), phase(), map()) ::
          {:ok, map()} | {:cached, map()} | {:error, term()}
  def start_session(req, raw, phase, body) do
    case call(req, :post, "/api/v1/#{Map.fetch!(@phases, phase)}/start",
           auth: {:bearer, raw},
           json: body
         ) do
      {:ok, %{"cached" => true, "result" => %{} = result}} ->
        {:cached, result}

      {:ok, %{"session_id" => id, "stream_url" => url} = session}
      when is_binary(id) and is_binary(url) ->
        {:ok, session}

      {:ok, _other} ->
        {:error, :malformed_response}

      error ->
        error
    end
  end

  @doc "Posts one tool response (`RsolvCore.Relay.ToolResponse.to_wire/1`) to a session."
  @spec tool_response(Req.Request.t(), String.t(), phase(), String.t(), map()) ::
          :ok | {:error, error()}
  def tool_response(req, raw, phase, session_id, wire) do
    req
    |> call(
      :post,
      "/api/v1/#{Map.fetch!(@phases, phase)}/tool_response/#{URI.encode(session_id, &URI.char_unreserved?/1)}",
      auth: {:bearer, raw},
      json: wire
    )
    |> ok()
  end

  @doc "Reads a session's status."
  @spec session_status(Req.Request.t(), String.t(), phase(), String.t()) ::
          {:ok, map()} | {:error, error()}
  def session_status(req, raw, phase, session_id) do
    call(
      req,
      :get,
      "/api/v1/#{Map.fetch!(@phases, phase)}/status/#{URI.encode(session_id, &URI.char_unreserved?/1)}",
      auth: {:bearer, raw}
    )
  end

  @doc "Uploads the work job's patch bytes for its issue (work role)."
  @spec upload_result(Req.Request.t(), String.t(), String.t(), pos_integer(), binary()) ::
          :ok | {:error, error()}
  def upload_result(req, raw, run_id, issue, patch) do
    req
    |> call(:post, "/api/v1/runs/#{segment(run_id)}/issues/#{issue}/results",
      auth: {:bearer, raw},
      json: %{issue_number: issue, patch: Base.encode64(patch)}
    )
    |> ok()
  end

  @doc "The enhanced patterns for one scanner language."
  @spec patterns(Req.Request.t(), String.t(), String.t()) :: {:ok, term()} | {:error, error()}
  def patterns(req, raw, language),
    do:
      call(req, :get, "/api/v1/patterns",
        auth: {:bearer, raw},
        params: [language: language, format: "enhanced"]
      )

  @doc "The vulnerability types' severity tiers."
  @spec severity_tiers(Req.Request.t(), String.t()) :: {:ok, term()} | {:error, error()}
  def severity_tiers(req, raw),
    do: call(req, :get, "/api/v1/vulnerability-types/severity-tiers", auth: {:bearer, raw})

  @doc "Validates scan findings (scan role)."
  @spec validate(Req.Request.t(), String.t(), map()) :: {:ok, term()} | {:error, error()}
  def validate(req, raw, body),
    do: call(req, :post, "/api/v1/vulnerabilities/validate", auth: {:bearer, raw}, json: body)

  @doc "Asks for the budget-aware scan plan (scan role)."
  @spec scan_plan(Req.Request.t(), String.t(), map()) :: {:ok, term()} | {:error, error()}
  def scan_plan(req, raw, body),
    do: call(req, :post, "/api/v1/scan/plan", auth: {:bearer, raw}, json: body)

  @doc "The signed publish decision, as the raw response bytes `RsolvCore.Decision.verify/3` takes."
  @spec decision(Req.Request.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, binary()} | {:error, error()}
  def decision(req, raw, run_id, issue) do
    with {:ok, %{body: body}} <-
           send_capped(
             req,
             :get,
             "/api/v1/runs/#{segment(run_id)}/issues/#{issue}/decision",
             [auth: {:bearer, raw}],
             @max_body_bytes
           ),
         do: {:ok, body}
  end

  @doc "The post-images of the decision's added and modified files."
  @spec post_images(Req.Request.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def post_images(req, raw, run_id, issue) do
    call(
      req,
      :get,
      "/api/v1/runs/#{segment(run_id)}/issues/#{issue}/post-images",
      [auth: {:bearer, raw}],
      @max_post_images_bytes
    )
  end

  @doc "Reports the published pull request, consuming the decision."
  @spec published(Req.Request.t(), String.t(), String.t(), pos_integer(), map()) ::
          :ok | {:error, error()}
  def published(req, raw, run_id, issue, body) do
    req
    |> call(:post, "/api/v1/runs/#{segment(run_id)}/issues/#{issue}/published",
      auth: {:bearer, raw},
      json: body
    )
    |> ok()
  end

  @doc """
  Sends a request and decodes its JSON response with `RsolvCore.StrictJson`,
  reading at most `max_bytes` (16 MiB by default).
  """
  @spec call(Req.Request.t(), atom(), String.t(), keyword(), pos_integer()) ::
          {:ok, term()} | {:error, term()}
  def call(req, method, url, opts, max_bytes \\ @max_body_bytes) do
    with {:ok, %{body: body}} <- send_capped(req, method, url, opts, max_bytes) do
      case StrictJson.decode(body, max_bytes: max_bytes, max_depth: 64) do
        {:ok, json} -> {:ok, json}
        {:error, _reason} -> {:error, :malformed_response}
      end
    end
  end

  defp send_capped(req, method, url, opts, max_bytes) do
    case Http.request(req, [method: method, url: url] ++ opts, max_bytes) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        {:ok, resp}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:platform, status, error_code(body)}}

      error ->
        error
    end
  end

  defp error_code(body) do
    case StrictJson.decode(body) do
      {:ok, %{"error" => code}} when is_binary(code) -> if code =~ ~r/\A[a-z_]{1,64}\z/, do: code
      _other -> nil
    end
  end

  defp ok({:ok, _body}), do: :ok
  defp ok(error), do: error

  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp token({:ok, %{"protocol_version" => version} = json}) do
    with :ok <- Relay.check_version(version),
         %{"token" => "rsolv_rt_" <> _ = raw, "expires_at" => expires} when is_binary(expires) <-
           json,
         {:ok, expires_at, 0} <- DateTime.from_iso8601(expires),
         {:ok, binding} <- run_binding(json) do
      {:ok, %{raw: raw, expires_at: expires_at, binding: binding}}
    else
      {:error, {:protocol_version, _theirs}} = error -> error
      _malformed -> {:error, :malformed_response}
    end
  end

  defp token({:ok, _json}), do: {:error, :malformed_response}
  defp token(error), do: error

  # Issue roles carry their run binding; a scan token is run-wide and has none.
  defp run_binding(%{"pipeline_run_id" => run, "base_sha" => base, "target_branch" => branch})
       when is_binary(run) and is_binary(base) and is_binary(branch) do
    if base =~ ~r/\A[0-9a-f]{40}\z/ and RsolvCore.Text.plain?(branch) and
         run =~ ~r/\A[0-9a-f-]{36}\z/,
       do: {:ok, %{"pipeline_run_id" => run, "base_sha" => base, "target_branch" => branch}},
       else: :error
  end

  defp run_binding(json) when not is_map_key(json, "pipeline_run_id"), do: {:ok, %{}}
  defp run_binding(_partial), do: :error
end
