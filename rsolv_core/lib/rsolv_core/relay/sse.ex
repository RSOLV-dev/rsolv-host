defmodule RsolvCore.Relay.SSE do
  @moduledoc """
  SSE (Server-Sent Events) encoding and decoding for the relay protocol.

  Encodes relay events into the SSE wire format and decodes incoming
  SSE streams back into structured events.

  ## SSE Format

  Each event follows the standard SSE format:

      event: <type>
      id: <monotonic_id>
      data: <json_payload>

      (blank line terminates event)

  ## Event Types

  - `tool_request` — platform asks the host to execute a tool
  - `progress` — informational progress update
  - `complete` — session completed successfully
  - `error` — session failed with error
  - `heartbeat` — keepalive (no data payload)
  """

  @types %{
    "tool_request" => :tool_request,
    "progress" => :progress,
    "complete" => :complete,
    "error" => :error,
    "heartbeat" => :heartbeat
  }

  @type event_type :: :tool_request | :progress | :complete | :error | :heartbeat
  @type event :: %{type: event_type(), id: integer() | nil, data: term()}

  @doc """
  Feeds one chunk of an SSE byte stream into the parser.

  `buffer` is the partial tail returned by the previous call (`""` at first).
  Returns the complete events in the chunk and the new tail. Comments such as
  keepalives, and events of an unknown type, are dropped.

      iex> RsolvCore.Relay.SSE.parse("", "event: heartbeat\\nid: 1\\n\\nevent: prog")
      {[%{type: :heartbeat, id: 1, data: nil}], "event: prog"}
  """
  @spec parse(binary(), binary()) :: {[event()], binary()}
  def parse(buffer, chunk) do
    {complete, [rest]} = (buffer <> chunk) |> String.split("\n\n") |> Enum.split(-1)

    events =
      Enum.flat_map(complete, fn raw ->
        case decode_event(raw) do
          {:ok, event} -> [event]
          {:error, _comment_or_unknown} -> []
        end
      end)

    {events, rest}
  end

  @doc """
  Encodes a relay event into SSE wire format.

  ## Parameters
  - `event_type` — atom: `:tool_request`, `:progress`, `:complete`, `:error`, `:heartbeat`
  - `data` — map to JSON-encode as the data payload (nil for heartbeat)
  - `event_id` — monotonic integer ID for reconnection support

  ## Examples

      iex> encoded = RsolvCore.Relay.SSE.encode_event(:heartbeat, nil, 1)
      iex> encoded =~ "event: heartbeat"
      true
      iex> encoded =~ "id: 1"
      true

      iex> encoded = RsolvCore.Relay.SSE.encode_event(:progress, %{step: 1}, 2)
      iex> encoded =~ "event: progress"
      true
      iex> encoded =~ "data: "
      true
  """
  @spec encode_event(atom(), map() | nil, integer()) :: String.t()
  def encode_event(:heartbeat, _data, event_id) do
    "event: heartbeat\nid: #{event_id}\n\n"
  end

  def encode_event(event_type, data, event_id) when is_atom(event_type) and is_map(data) do
    # Convert structs to plain maps for JSON encoding
    encodable = if is_struct(data), do: Map.from_struct(data), else: data
    json = JSON.encode!(encodable)
    "event: #{event_type}\nid: #{event_id}\ndata: #{json}\n\n"
  end

  @doc """
  Decodes a raw SSE event string into a structured event.

  Returns `{:ok, event}` with a map containing `:type`, `:id`, and `:data` fields,
  or `{:error, reason}` for malformed events. Only the five event types of the
  protocol decode; any other `event:` name is `{:error, :unknown_event_type}`,
  so no wire input becomes an atom.

  ## Examples

      iex> raw = "event: heartbeat\\nid: 5\\n\\n"
      iex> {:ok, event} = RsolvCore.Relay.SSE.decode_event(raw)
      iex> event.type
      :heartbeat
      iex> event.id
      5
  """
  @spec decode_event(term()) :: {:ok, event()} | {:error, atom()}
  def decode_event(raw) when is_binary(raw) do
    lines =
      raw
      |> String.trim()
      |> String.split("\n")
      |> Enum.reject(&(&1 == ""))

    parsed =
      Enum.reduce(lines, %{}, fn line, acc ->
        cond do
          String.starts_with?(line, "event: ") ->
            name = String.replace_prefix(line, "event: ", "")
            Map.put(acc, :type, Map.get(@types, name, :unknown))

          String.starts_with?(line, "id: ") ->
            id = line |> String.replace_prefix("id: ", "") |> String.to_integer()
            Map.put(acc, :id, id)

          String.starts_with?(line, "data: ") ->
            Map.put(acc, :data, line |> String.replace_prefix("data: ", "") |> decode_data())

          true ->
            acc
        end
      end)

    to_event(parsed)
  end

  def decode_event(_), do: {:error, :invalid_input}

  defp to_event(%{type: :unknown}), do: {:error, :unknown_event_type}

  defp to_event(%{type: type} = parsed),
    do: {:ok, %{type: type, id: parsed[:id], data: parsed[:data]}}

  defp to_event(_parsed), do: {:error, :missing_event_type}

  defp decode_data(json_str) do
    case JSON.decode(json_str) do
      {:ok, data} -> data
      {:error, _} -> json_str
    end
  end

  @doc """
  Encodes an SSE retry directive.

  Tells the client how long to wait before reconnecting.

  ## Examples

      iex> RsolvCore.Relay.SSE.encode_retry(3000)
      "retry: 3000\\n\\n"
  """
  @spec encode_retry(pos_integer()) :: String.t()
  def encode_retry(milliseconds) when is_integer(milliseconds) and milliseconds > 0 do
    "retry: #{milliseconds}\n\n"
  end
end
