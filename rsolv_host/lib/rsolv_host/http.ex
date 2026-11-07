defmodule RsolvHost.Http do
  @moduledoc """
  The one way the host reads an HTTP response: raw (never decompressed, never
  auto-decoded) and streamed into a buffer that stops at a byte cap, so no
  server, compromised or not, can make the host buffer more than it allows.
  """

  @doc """
  Sends `opts` through `req` and returns the response with its whole body, or
  `{:error, {:transport, :response_too_large}}` past `max_bytes`, or
  `{:error, {:transport, reason}}`.
  """
  @spec request(Req.Request.t(), keyword(), pos_integer()) ::
          {:ok, Req.Response.t()} | {:error, {:transport, term()}}
  def request(req, opts, max_bytes) do
    case Req.request(req, [raw: true, into: capped(max_bytes)] ++ opts) do
      {:ok, %Req.Response{private: %{too_large: true}}} ->
        {:error, {:transport, :response_too_large}}

      {:ok, response} ->
        {:ok, response}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport, reason}}

      {:error, _exception} ->
        {:error, {:transport, :request_failed}}
    end
  end

  @doc """
  Whether a failed attempt is worth repeating: a timeout, or a refused or
  closed connection, or 408, 429, 500, 502, 503 or 504. Each client decides
  which requests may be repeated at all (`RsolvHost.GitHub.retry?/2`,
  `RsolvHost.Platform.retry?/2`): a closed connection can hide a write that
  happened.
  """
  @spec transient?(Req.Response.t() | Exception.t()) :: boolean()
  def transient?(%Req.Response{status: status}), do: status in [408, 429, 500, 502, 503, 504]

  def transient?(%Req.TransportError{reason: reason}),
    do: reason in [:timeout, :econnrefused, :closed]

  def transient?(_other), do: false

  defp capped(max_bytes) do
    fn {:data, data}, {req, resp} ->
      body = (resp.body || "") <> data

      if byte_size(body) > max_bytes,
        do: {:halt, {req, %{Req.Response.put_private(resp, :too_large, true) | body: ""}}},
        else: {:cont, {req, %{resp | body: body}}}
    end
  end
end
