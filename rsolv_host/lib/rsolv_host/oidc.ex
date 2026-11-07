defmodule RsolvHost.Oidc do
  @moduledoc """
  The job's GitHub Actions OIDC token. The audience is one fixed identifier
  (`oidc_audience`, `https://api.rsolv.dev`), never derived from the platform URL
  the host talks to: the platform verifies one audience in every environment.
  """

  alias RsolvCore.StrictJson
  alias RsolvHost.{ActionsLog, Http}

  @max_body_bytes 64 * 1024
  @max_jwt_bytes 8 * 1024

  @doc """
  Requests an OIDC token for the configured audience and masks it in the log.
  Option: `:io` for the mask (default `:stdio`).
  """
  @spec fetch(map(), keyword()) ::
          {:ok, String.t()}
          | {:error, :oidc_unavailable | {:oidc_http, pos_integer()} | {:transport, term()}}
  def fetch(env, opts \\ []) do
    with %{
           "ACTIONS_ID_TOKEN_REQUEST_URL" => "https://" <> _ = url,
           "ACTIONS_ID_TOKEN_REQUEST_TOKEN" => token
         }
         when is_binary(token) and token != "" <- env,
         {:ok, jwt} <- request(url, token) do
      ActionsLog.mask(jwt, Keyword.get(opts, :io, :stdio))
      {:ok, jwt}
    else
      %{} -> {:error, :oidc_unavailable}
      error -> error
    end
  end

  defp request(url, token) do
    audience = Application.fetch_env!(:rsolv_host, :oidc_audience)
    extra = :rsolv_host |> Application.get_env(__MODULE__, []) |> Keyword.get(:req_options, [])

    query = URI.encode_query(audience: audience)
    headers = [authorization: "bearer " <> token]

    [retry: :transient]
    |> Keyword.merge(extra)
    |> Req.new()
    |> Http.request([method: :get, url: url <> "&" <> query, headers: headers], @max_body_bytes)
    |> case do
      {:ok, %{status: 200, body: body}} -> value(StrictJson.decode(body))
      {:ok, %{status: status}} -> {:error, {:oidc_http, status}}
      error -> error
    end
  end

  # Three unpadded base64url segments, checked before the token is masked.
  defp value({:ok, %{"value" => jwt}})
       when is_binary(jwt) and byte_size(jwt) <= @max_jwt_bytes do
    if jwt =~ ~r/\A[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\z/,
      do: {:ok, jwt},
      else: {:error, :oidc_unavailable}
  end

  defp value(_other), do: {:error, :oidc_unavailable}

  @doc "Decodes a JWT's payload without verifying it: the job's own token, read for its claims."
  @spec claims(String.t()) :: {:ok, map()} | {:error, :malformed_jwt}
  def claims(jwt) do
    with [_header, payload, _signature] <- String.split(jwt, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{} = claims} <- StrictJson.decode(json, max_bytes: @max_body_bytes) do
      {:ok, claims}
    else
      _malformed -> {:error, :malformed_jwt}
    end
  end
end
