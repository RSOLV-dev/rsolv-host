defmodule RsolvHost.Relay do
  @moduledoc """
  The tool relay of one VALIDATE or MITIGATE session (RFC-096, RFC-150 §2.1):
  the platform streams `tool_request` events over SSE, the host runs each one as
  `rsolv-sandbox tool` inside the sandbox, and posts the result back.

  Everything the sandbox returns is untrusted: its output is capped, only the
  last non-empty line is decoded, as a JSON object, and anything else is replaced
  with a fixed error. The host logs tool names and durations only.

  ## Replay protection

  On reconnect the platform replays every request still pending, and a stream may
  repeat one. The relay records each request id before running it, in a table
  that lives for the whole session (across reconnects and transport errors), and
  ignores any id it has already seen, so a replay never runs `bash` twice. An id
  is 1 to 128 of `[A-Za-z0-9_-]`, checked before it is remembered, so the table
  holds at most 2,000 × 128 bytes of ids.

  ## Time budget

  A session has one monotonic deadline (`:deadline`; the work role shares one
  across both its sessions and the upload). It's checked before every event,
  buffered or not, heartbeats included, and before every reconnect; it caps
  each tool's time and each wait on the stream. Past it: `{:error,
  :session_timeout}`.
  """

  alias RsolvCore.Relay.{SSE, ToolRequest, ToolResponse}
  alias RsolvCore.StrictJson
  alias RsolvHost.{Frame, Platform, Sandbox, TokenKeeper}

  @max_tool_ms 900_000
  @max_output_bytes 8 * 1024 * 1024
  @max_requests 2_000
  @backoff_ms [2_000, 4_000, 8_000, 16_000, 32_000]
  @timed_out 124
  @max_session_ms 2 * 60 * 60 * 1_000
  @max_stream_wait_ms 120_000
  @request_id ~r/\A[A-Za-z0-9_-]{1,128}\z/

  @doc """
  Runs a session to its end: `{:ok, data}` on `complete` (or a cached result),
  `{:error, {:session, data}}` on `error`, `{:error, :stream_exhausted}` after
  five failed reconnects, `{:error, :session_timeout}` past the deadline.
  Options: `:backoff_ms` (the reconnect delays), `:deadline` (monotonic
  milliseconds; default two hours from now) and `:io`.
  """
  @spec run_session(GenServer.server(), Sandbox.t(), Platform.phase(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_session(keeper, sbx, phase, body, opts \\ []) do
    with {:ok, %{req: req, raw: raw}} <- TokenKeeper.token(keeper) do
      case Platform.start_session(req, raw, phase, body) do
        {:cached, result} -> {:ok, result}
        {:ok, %{"session_id" => id}} -> relay(keeper, sbx, phase, id, opts)
        error -> error
      end
    end
  end

  defp relay(keeper, sbx, phase, session_id, opts) do
    if session_id =~ ~r/\A[A-Za-z0-9_-]{1,128}\z/ do
      seen = :ets.new(__MODULE__, [:set, :private])

      session = %{
        keeper: keeper,
        sbx: sbx,
        phase: phase,
        id: session_id,
        seen: seen,
        io: Keyword.get(opts, :io, :stdio),
        deadline:
          Keyword.get_lazy(opts, :deadline, fn ->
            System.monotonic_time(:millisecond) + @max_session_ms
          end)
      }

      try do
        connect(session, Keyword.get(opts, :backoff_ms, @backoff_ms))
      after
        :ets.delete(seen)
      end
    else
      {:error, :malformed_response}
    end
  end

  defp connect(session, backoff) do
    case stream_once(session) do
      {:done, result} -> result
      :dropped -> after_drop(session, backoff)
    end
  end

  defp after_drop(session, backoff) do
    case status(session) do
      {:ok, %{"status" => "failed"}} -> {:error, {:session, %{"status" => "failed"}}}
      {:ok, %{"status" => "completed"}} -> {:error, :stream_exhausted}
      {:error, {:platform, 404, _code}} -> {:error, :stream_exhausted}
      _still_running_or_unknown -> reconnect(session, backoff)
    end
  end

  defp reconnect(_session, []), do: {:error, :stream_exhausted}

  defp reconnect(session, [delay | rest]) do
    case left_ms(session) do
      left when left > 0 ->
        Process.sleep(min(delay, left))
        connect(session, rest)

      _spent ->
        {:error, :session_timeout}
    end
  end

  defp left_ms(session), do: session.deadline - System.monotonic_time(:millisecond)

  defp status(session) do
    with {:ok, %{req: req, raw: raw}} <- TokenKeeper.token(session.keeper),
         do: Platform.session_status(req, raw, session.phase, session.id)
  end

  defp stream_once(session) do
    with {:ok, wait_ms} <- wait_ms(session),
         {:ok, %{req: req, raw: raw}} <- TokenKeeper.token(session.keeper),
         req = Req.merge(req, receive_timeout: wait_ms),
         {:ok, resp} <-
           Platform.stream(req, raw, session.phase, session.id, &chunk(&1, &2, session)) do
      case resp.private[:relay] do
        %{outcome: nil} -> :dropped
        %{outcome: outcome} -> {:done, outcome}
        nil -> :dropped
      end
    else
      {:error, {:transport, _reason}} -> :dropped
      {:error, {:platform, status, _code}} when status >= 500 -> :dropped
      error -> {:done, error}
    end
  end

  defp wait_ms(session) do
    case left_ms(session) do
      left when left > 0 -> {:ok, min(left, @max_stream_wait_ms)}
      _spent -> {:error, :session_timeout}
    end
  end

  defp chunk({:data, data}, {req, resp}, session) do
    state = resp.private[:relay] || %{parser: SSE.new(), outcome: nil}

    case SSE.parse(state.parser, data) do
      {:ok, events, parser} -> events(events, %{state | parser: parser}, session, {req, resp})
      {:error, reason} -> halt({req, resp}, state, {:error, {:stream, reason}})
    end
  end

  defp events([], state, _session, {req, resp}),
    do: {:cont, {req, Req.Response.put_private(resp, :relay, state)}}

  defp events([event | rest], state, session, acc) do
    if left_ms(session) > 0,
      do: event(event, rest, state, session, acc),
      else: halt(acc, state, {:error, :session_timeout})
  end

  defp event(%{type: :complete, data: data}, _rest, state, _session, acc),
    do: halt(acc, state, {:ok, data})

  defp event(%{type: :error, data: data}, _rest, state, _session, acc),
    do: halt(acc, state, {:error, {:session, data}})

  defp event(%{type: :tool_request, data: data}, rest, state, session, acc) do
    case answer(session, data) do
      :ok -> events(rest, state, session, acc)
      {:error, _reason} = error -> halt(acc, state, error)
    end
  end

  defp event(_progress_or_heartbeat, rest, state, session, acc),
    do: events(rest, state, session, acc)

  defp halt({req, resp}, state, outcome),
    do: {:halt, {req, Req.Response.put_private(resp, :relay, %{state | outcome: outcome})}}

  defp answer(session, %{"id" => id} = data) when is_binary(id) do
    cond do
      not (id =~ @request_id) -> {:error, :malformed_tool_request}
      :ets.member(session.seen, id) -> :ok
      :ets.info(session.seen, :size) >= @max_requests -> {:error, :too_many_tool_requests}
      true -> run_request(session, id, data)
    end
  end

  defp answer(_session, _data), do: {:error, :malformed_tool_request}

  defp run_request(session, id, data) do
    case ToolRequest.from_wire(data) do
      {:error, {:protocol_version, _theirs}} = error ->
        error

      decoded ->
        true = :ets.insert_new(session.seen, {id})

        with {:ok, result} <- result(session, decoded),
             do: respond(session, id, result)
    end
  end

  defp result(session, {:ok, %ToolRequest{} = request}) do
    started = System.monotonic_time(:millisecond)
    tool = Atom.to_string(request.tool)

    outcome =
      Sandbox.exec(session.sbx, ["rsolv-sandbox", "tool"],
        input: Frame.encode(%{"tool" => tool, "input" => request.input}),
        timeout_ms: Enum.min([request.timeout_ms, @max_tool_ms, max(left_ms(session), 1)]),
        max_bytes: @max_output_bytes
      )

    IO.puts(
      session.io,
      "rsolv: #{session.phase} #{tool} #{System.monotonic_time(:millisecond) - started} ms"
    )

    sandbox_result(outcome)
  end

  defp result(_session, {:error, :unknown_tool}), do: {:ok, %{"error" => "unknown tool"}}
  defp result(_session, {:error, _malformed}), do: {:ok, %{"error" => "malformed tool request"}}

  defp sandbox_result({:ok, %{status: @timed_out}}), do: {:ok, %{"error" => "timeout"}}
  defp sandbox_result({:ok, %{output: output}}), do: {:ok, last_object(output)}
  defp sandbox_result({:error, :timeout}), do: {:ok, %{"error" => "timeout"}}
  defp sandbox_result({:error, :output_too_large}), do: {:ok, %{"error" => "output too large"}}
  defp sandbox_result({:error, :enoent}), do: {:error, {:sandbox, :enoent}}

  @doc """
  The JSON object on the last non-empty line of `output`, or a fixed error; the
  raw bytes are dropped either way.
  """
  @spec last_object(binary()) :: map()
  def last_object(output) do
    line =
      output
      |> String.split(["\r\n", "\n"])
      |> Enum.reverse()
      |> Enum.find("", &(String.trim(&1) != ""))

    case StrictJson.decode(line, max_bytes: @max_output_bytes, max_depth: 64) do
      {:ok, %{} = object} -> object
      _other -> %{"error" => "sandbox returned malformed output"}
    end
  end

  defp respond(session, id, result) do
    with {:ok, %{req: req, raw: raw}} <- TokenKeeper.token(session.keeper) do
      wire = ToolResponse.to_wire(%ToolResponse{request_id: id, result: result})
      Platform.tool_response(req, raw, session.phase, session.id, wire)
    end
  end
end
