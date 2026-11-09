defmodule RsolvHost.Http do
  @moduledoc """
  The one way the host reads an HTTP response: raw (never decompressed, never
  auto-decoded) and streamed into a buffer that stops at a byte cap, so no
  server, compromised or not, can make the host buffer more than it allows.

  It also holds the two policies every client shares: which failures are worth
  repeating and how long to wait (`retry/3`), and a deadline that bounds a
  request, its attempts and its waits (`deadline/3`).
  """

  defmodule Expired do
    @moduledoc "The deadline set with `RsolvHost.Http.deadline/3` passed before an attempt."
    defexception [:reason]

    @impl true
    def message(_expired), do: "the request's deadline passed"
  end

  @doc """
  Bounds every request later sent with `req` by `deadline` (monotonic
  milliseconds). Before each attempt, retries included, the deadline is
  checked: once it has passed, nothing is sent and the request is `{:error,
  reason}`. Each attempt's receive timeout is cut to the time left, and so is
  each retry's wait (`retry/3`). Setting it again replaces the deadline.
  """
  @spec deadline(Req.Request.t(), integer(), term()) :: Req.Request.t()
  def deadline(req, deadline, reason) do
    req = Req.Request.put_private(req, :deadline, {deadline, reason})

    if Keyword.has_key?(req.request_steps, :deadline),
      do: req,
      else: Req.Request.append_request_steps(req, deadline: &check_deadline/1)
  end

  defp check_deadline(%{private: %{deadline: {deadline, reason}}} = req) do
    case deadline - System.monotonic_time(:millisecond) do
      left when left > 0 ->
        timeout = Req.Request.get_option(req, :receive_timeout, 15_000)
        Req.Request.put_option(req, :receive_timeout, min(timeout, left))

      _spent ->
        Req.Request.halt(req, %Expired{reason: reason})
    end
  end

  @doc """
  Sends `opts` through `req` and returns the response with its whole body, or
  `{:error, {:transport, :response_too_large}}` past `max_bytes`, or
  `{:error, {:transport, reason}}`, or the deadline's reason (`deadline/3`).
  """
  @spec request(Req.Request.t(), keyword(), pos_integer()) ::
          {:ok, Req.Response.t()} | {:error, term()}
  def request(req, opts, max_bytes) do
    case Req.request(req, [raw: true, into: capped(max_bytes)] ++ opts) do
      {:ok, %Req.Response{private: %{too_large: true}}} ->
        {:error, {:transport, :response_too_large}}

      {:ok, response} ->
        {:ok, response}

      {:error, exception} ->
        {:error, failure(exception)}
    end
  end

  @doc "The error reason for an exception `Req` returned."
  @spec failure(Exception.t()) :: term()
  def failure(%Expired{reason: reason}), do: reason
  def failure(%Req.TransportError{reason: reason}), do: {:transport, reason}
  def failure(_exception), do: {:transport, :request_failed}

  @max_retry_after_ms 60_000

  @doc """
  A `Req` retry decision: `false`, or the wait before repeating a request that
  `repeatable?` and whose failure is `transient?/1`. The wait is the server's
  `Retry-After` on 429 and 503 (at most 60 seconds), otherwise 1, 2, then 4
  seconds (the `:retry_base_ms` setting times 2^attempt), and never more than
  what's left before the request's deadline.
  """
  @spec retry(Req.Request.t(), Req.Response.t() | Exception.t(), boolean()) ::
          false | {:delay, non_neg_integer()}
  def retry(req, result, repeatable?) do
    if repeatable? and transient?(result),
      do: {:delay, req |> wait(result) |> within(req)},
      else: false
  end

  defp wait(req, %Req.Response{status: status} = response) when status in [429, 503],
    do: min(Req.Response.get_retry_after(response) || backoff(req), @max_retry_after_ms)

  defp wait(req, _result), do: backoff(req)

  defp backoff(req),
    do:
      Application.get_env(:rsolv_host, :retry_base_ms, 1_000) *
        Integer.pow(2, Req.Request.get_private(req, :req_retry_count, 0))

  defp within(wait, %{private: %{deadline: {deadline, _reason}}}),
    do: wait |> min(deadline - System.monotonic_time(:millisecond)) |> max(0)

  defp within(wait, _req), do: wait

  @doc """
  Whether a failed attempt is worth repeating: a timeout, or a refused or
  closed connection, or 408, 429, 500, 502, 503 or 504. Each client decides
  which requests may be repeated at all (`RsolvHost.GitHub.retry/2`,
  `RsolvHost.Platform.retry/2`): a closed connection can hide a write that
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
