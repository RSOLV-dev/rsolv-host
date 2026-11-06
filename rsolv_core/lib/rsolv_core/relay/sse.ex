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

  Every other type carries one JSON object as its data. The decoder (`parse/2`
  for a stream, `decode_event/1` for one frame) is bounded and never raises on
  wire input; see `parse/2`.
  """

  alias RsolvCore.StrictJson

  @types %{
    "tool_request" => :tool_request,
    "progress" => :progress,
    "complete" => :complete,
    "error" => :error,
    "heartbeat" => :heartbeat
  }

  @max_line_bytes 8 * 1024 * 1024
  @max_frame_bytes 16 * 1024 * 1024
  @max_id_digits 19
  @eol ["\r\n", "\n", "\r"]

  @type event_type :: :tool_request | :progress | :complete | :error | :heartbeat
  @type event :: %{type: event_type(), id: non_neg_integer() | nil, data: map() | nil}
  @type error :: :line_too_long | :frame_too_large | :malformed_event

  defstruct [:eol, tail: [], tail_bytes: 0, skip_lf: false, frame: %{}, frame_bytes: 0]

  @typedoc "The parser's state between chunks. Build one with `new/0`."
  @opaque parser :: %__MODULE__{
            eol: :binary.cp(),
            tail: [binary()],
            tail_bytes: non_neg_integer(),
            skip_lf: boolean(),
            frame: map(),
            frame_bytes: non_neg_integer()
          }

  @doc "The longest line `parse/2` accepts, in bytes (8 MiB)."
  @spec max_line_bytes() :: pos_integer()
  def max_line_bytes, do: @max_line_bytes

  @doc """
  The largest frame `parse/2` accepts, in bytes (16 MiB): every line from one
  blank line to the next, comments included, so a stream that never ends a frame
  is refused rather than buffered.
  """
  @spec max_frame_bytes() :: pos_integer()
  def max_frame_bytes, do: @max_frame_bytes

  @doc "A parser at the start of a stream."
  @spec new() :: parser()
  def new, do: %__MODULE__{eol: :binary.compile_pattern(@eol)}

  @doc """
  Feeds one chunk of an SSE byte stream into the parser.

  Returns the events the chunk completes, in order, and the parser for the next
  chunk. Lines end in CRLF, LF or CR (also when a CRLF is split across chunks),
  one space after a field's colon is dropped, and several `data:` lines are
  joined with `\\n`. Comments, such as keepalives, and events of an unknown type
  are dropped.

  ## Limits

  The parser holds at most one partial line and one partial frame, so its memory
  is bounded by these limits, and its work is linear in the bytes fed to it:
  - a line, including the pending tail of one, is at most `max_line_bytes/0`,
    else `{:error, :line_too_long}`;
  - a frame is at most `max_frame_bytes/0`, else `{:error, :frame_too_large}`;
  - a frame of a known type that is malformed is `{:error, :malformed_event}`:
    an `id` that is not 1–#{@max_id_digits} decimal digits, a `heartbeat` with
    data, or any other type without data that `RsolvCore.StrictJson` decodes to
    an object.

  An error ends the stream: the caller treats it as a protocol failure and
  never as an outcome.

      iex> {:ok, events, _parser} = RsolvCore.Relay.SSE.parse(RsolvCore.Relay.SSE.new(), "event: heartbeat\\nid: 1\\n\\nevent: prog")
      iex> events
      [%{type: :heartbeat, id: 1, data: nil}]
  """
  @spec parse(parser(), binary()) :: {:ok, [event()], parser()} | {:error, error()}
  def parse(%__MODULE__{} = parser, chunk) when is_binary(chunk) do
    {chunk, parser} = skip_split_lf(chunk, parser)
    lines(chunk, 0, parser, [])
  catch
    reason when reason in [:line_too_long, :frame_too_large, :malformed_event] ->
      {:error, reason}
  end

  defp skip_split_lf("\n" <> rest, %{skip_lf: true} = parser),
    do: {rest, %{parser | skip_lf: false}}

  defp skip_split_lf("", parser), do: {"", parser}
  defp skip_split_lf(chunk, parser), do: {chunk, %{parser | skip_lf: false}}

  # Scans only the new chunk, from `pos`; the pending tail is never rescanned.
  defp lines(chunk, pos, parser, events) do
    case :binary.match(chunk, parser.eol, scope: {pos, byte_size(chunk) - pos}) do
      :nomatch ->
        {:ok, Enum.reverse(events), pend(parser, binary_part(chunk, pos, byte_size(chunk) - pos))}

      {at, eol_bytes} ->
        parser = pend(parser, binary_part(chunk, pos, at - pos))
        line = parser.tail |> Enum.reverse() |> IO.iodata_to_binary()
        parser = %{parser | tail: [], tail_bytes: 0, frame_bytes: parser.frame_bytes + eol_bytes}
        next = at + eol_bytes
        # A CR that ends the chunk may be the first half of a CRLF.
        parser = %{
          parser
          | skip_lf: eol_bytes == 1 and next == byte_size(chunk) and :binary.at(chunk, at) == ?\r
        }

        {parser, events} = line(line, parser, events)
        lines(chunk, next, parser, events)
    end
  end

  defp pend(parser, ""), do: parser

  defp pend(parser, bytes) do
    tail_bytes = parser.tail_bytes + byte_size(bytes)
    frame_bytes = parser.frame_bytes + byte_size(bytes)
    if tail_bytes > @max_line_bytes, do: throw(:line_too_long)
    if frame_bytes > @max_frame_bytes, do: throw(:frame_too_large)
    %{parser | tail: [bytes | parser.tail], tail_bytes: tail_bytes, frame_bytes: frame_bytes}
  end

  defp line("", %{frame: frame} = parser, events) do
    parser = %{parser | frame: %{}, frame_bytes: 0}

    case finish(frame) do
      {:ok, event} -> {parser, [event | events]}
      {:skip, _comment_or_unknown} -> {parser, events}
      {:error, reason} -> throw(reason)
    end
  end

  defp line(line, parser, events), do: {%{parser | frame: field(parser.frame, line)}, events}

  defp field(frame, ":" <> _comment), do: frame

  defp field(frame, line) do
    case :binary.split(line, ":") do
      [name, " " <> value] -> put_field(frame, name, value)
      [name, value] -> put_field(frame, name, value)
      [name] -> put_field(frame, name, "")
    end
  end

  defp put_field(frame, "event", name), do: Map.put(frame, :type, name)
  defp put_field(frame, "id", id), do: Map.put(frame, :id, id)
  defp put_field(frame, "data", data), do: Map.update(frame, :data, [data], &[data, "\n" | &1])
  defp put_field(frame, _retry_or_other, _value), do: frame

  defp finish(frame) when map_size(frame) == 0, do: {:skip, :missing_event_type}

  defp finish(frame) do
    with {:ok, type} <- type(frame[:type]),
         {:ok, id} <- id(frame[:id]),
         {:ok, data} <- data(type, frame[:data]) do
      {:ok, %{type: type, id: id, data: data}}
    end
  end

  defp type(nil), do: {:skip, :missing_event_type}

  defp type(name) do
    case Map.fetch(@types, name) do
      {:ok, type} -> {:ok, type}
      :error -> {:skip, :unknown_event_type}
    end
  end

  defp id(nil), do: {:ok, nil}

  defp id(<<digit, _rest::binary>> = text)
       when digit in ?0..?9 and byte_size(text) <= @max_id_digits do
    case Integer.parse(text) do
      {id, ""} -> {:ok, id}
      _not_decimal -> {:error, :malformed_event}
    end
  end

  defp id(_text), do: {:error, :malformed_event}

  defp data(:heartbeat, nil), do: {:ok, nil}
  defp data(:heartbeat, _data), do: {:error, :malformed_event}
  defp data(_type, nil), do: {:error, :malformed_event}

  defp data(_type, lines) do
    case lines
         |> Enum.reverse()
         |> IO.iodata_to_binary()
         |> StrictJson.decode(max_bytes: @max_frame_bytes) do
      {:ok, %{} = object} -> {:ok, object}
      _not_an_object -> {:error, :malformed_event}
    end
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
  def decode_event(raw) when is_binary(raw) and byte_size(raw) <= @max_frame_bytes do
    frame =
      raw
      |> :binary.split(@eol, [:global])
      |> Enum.reject(&(&1 == ""))
      |> Enum.reduce(%{}, &field(&2, &1))

    case finish(frame) do
      {:ok, event} -> {:ok, event}
      {:skip, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  def decode_event(raw) when is_binary(raw), do: {:error, :frame_too_large}
  def decode_event(_), do: {:error, :invalid_input}

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
