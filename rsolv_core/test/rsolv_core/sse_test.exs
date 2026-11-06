defmodule RsolvCore.Relay.SSETest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest RsolvCore.Relay.SSE

  alias RsolvCore.Relay.SSE

  describe "encode_event/3" do
    test "formats tool_request event with JSON data" do
      data = %{id: "req_1", tool: "read_file", input: %{path: "/app/server.js"}}
      encoded = SSE.encode_event(:tool_request, data, 1)

      assert encoded =~ "event: tool_request\n"
      assert encoded =~ "id: 1\n"
      assert encoded =~ "data: "
      assert encoded =~ "\n\n"

      [data_line] =
        encoded
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "data: "))

      json_str = String.replace_prefix(data_line, "data: ", "")
      assert {:ok, %{"id" => "req_1", "tool" => "read_file"}} = JSON.decode(json_str)
    end

    test "formats progress event" do
      data = %{message: "Generating test...", step: 3, total_steps: 10}
      encoded = SSE.encode_event(:progress, data, 2)

      assert encoded =~ "event: progress\n"
      assert encoded =~ "id: 2\n"
    end

    test "formats complete event" do
      data = %{result: "success", summary: "Test generated"}
      encoded = SSE.encode_event(:complete, data, 5)

      assert encoded =~ "event: complete\n"
      assert encoded =~ "id: 5\n"
    end

    test "formats error event" do
      data = %{error: "timeout", message: "Session timed out"}
      encoded = SSE.encode_event(:error, data, 6)

      assert encoded =~ "event: error\n"
    end

    test "formats heartbeat without data payload" do
      encoded = SSE.encode_event(:heartbeat, nil, 7)

      assert encoded =~ "event: heartbeat\n"
      assert encoded =~ "id: 7\n"
      refute encoded =~ "data: "
    end

    test "includes monotonic event ID for reconnection" do
      encoded1 = SSE.encode_event(:progress, %{step: 1}, 1)
      encoded2 = SSE.encode_event(:progress, %{step: 2}, 2)

      assert encoded1 =~ "id: 1\n"
      assert encoded2 =~ "id: 2\n"
    end

    test "escapes newlines in JSON data field" do
      data = %{content: "line1\nline2\nline3"}
      encoded = SSE.encode_event(:tool_request, data, 1)

      data_lines =
        encoded
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "data: "))

      assert [_one_line] = data_lines
    end
  end

  describe "decode_event/1 when the frame is malformed" do
    test "refuses a non-integer id instead of raising" do
      assert SSE.decode_event("event: progress\nid: abc\ndata: {}\n\n") ==
               {:error, :malformed_event}
    end

    test "refuses data that is not JSON" do
      assert SSE.decode_event("event: complete\nid: 1\ndata: {broken\n\n") ==
               {:error, :malformed_event}
    end

    test "decodes a CRLF frame" do
      assert {:ok, %{type: :heartbeat, id: 5}} =
               SSE.decode_event("event: heartbeat\r\nid: 5\r\n\r\n")
    end
  end

  describe "decode_event/1" do
    test "parses a tool_request event" do
      raw = "event: tool_request\nid: 1\ndata: {\"id\":\"req_1\",\"tool\":\"read_file\"}\n\n"

      assert {:ok, %{type: :tool_request, id: 1, data: %{"id" => "req_1"}}} =
               SSE.decode_event(raw)
    end

    test "parses a heartbeat event" do
      raw = "event: heartbeat\nid: 5\n\n"

      assert {:ok, %{type: :heartbeat, id: 5, data: nil}} = SSE.decode_event(raw)
    end

    test "returns error for malformed event" do
      assert {:error, _reason} = SSE.decode_event("garbage data")
    end
  end

  @max_line_bytes 8 * 1024 * 1024
  @max_frame_bytes 16 * 1024 * 1024

  defp feed(chunks) do
    Enum.reduce_while(chunks, {:ok, [], SSE.new()}, fn chunk, {:ok, seen, parser} ->
      case SSE.parse(parser, chunk) do
        {:ok, events, parser} -> {:cont, {:ok, seen ++ events, parser}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp events(chunks) do
    {:ok, events, _parser} = feed(chunks)
    events
  end

  defp bytewise(binary), do: for(<<byte <- binary>>, do: <<byte>>)

  describe "parse/2" do
    test "returns complete events and keeps the partial tail for the next chunk" do
      {:ok, events, parser} =
        SSE.parse(SSE.new(), "event: progress\nid: 1\ndata: {\"a\":1}\n\nevent: heart")

      assert [%{type: :progress, id: 1, data: %{"a" => 1}}] = events
      assert {:ok, [%{type: :heartbeat, id: 2}], _parser} = SSE.parse(parser, "beat\nid: 2\n\n")
    end

    test "delivers an event split across chunks once" do
      assert [%{type: :complete, id: 2, data: %{"ok" => true}}] =
               events(["event: complete\nid: 2\nda", "ta: {\"ok\":true}\n\n"])
    end

    test "delivers several events from one chunk in order" do
      chunk = SSE.encode_event(:heartbeat, nil, 1) <> SSE.encode_event(:progress, %{n: 2}, 2)
      assert [%{type: :heartbeat, id: 1}, %{type: :progress, id: 2}] = events([chunk])
    end

    test "drops keepalive comments" do
      assert events([": keepalive\n\n"]) == []
    end

    test "drops an event of an unknown type" do
      assert events(["event: pwn\nid: 1\ndata: {}\n\n"]) == []
    end

    test "drops an event of an unknown type even when its id is malformed" do
      assert events(["event: pwn\nid: nope\n\n"]) == []
    end

    test "drops an event name that is not valid UTF-8" do
      assert events([<<"event: ", 0xFF, "\nid: 1\n\n">>]) == []
    end
  end

  describe "parse/2 on SSE framing" do
    test "accepts CRLF line endings" do
      assert [%{type: :progress, id: 1, data: %{"a" => 1}}] =
               events(["event: progress\r\nid: 1\r\ndata: {\"a\":1}\r\n\r\n"])
    end

    test "accepts CR line endings" do
      assert [%{type: :heartbeat, id: 3}] = events(["event: heartbeat\rid: 3\r\r"])
    end

    test "treats a CRLF split across chunks as one line ending" do
      assert [%{type: :heartbeat, id: 1}] =
               events(["event: heartbeat\r", "\nid: 1\r", "\n\r", "\n"])
    end

    test "keeps a split CRLF together across an empty chunk" do
      assert [%{type: :heartbeat, id: 1}] = events(["event: heartbeat\r", "", "\nid: 1\n\n"])
    end

    test "joins several data lines with a newline" do
      assert [%{type: :progress, data: %{"a" => 1}}] =
               events(["event: progress\ndata: {\"a\":\ndata: 1}\n\n"])
    end

    test "joins data lines with a newline, not by concatenation" do
      assert SSE.parse(SSE.new(), "event: progress\ndata: {\"a\":1\ndata: 2}\n\n") ==
               {:error, :malformed_event}
    end

    test "accepts a field with no space after the colon" do
      assert [%{type: :progress, id: 4, data: %{"a" => 1}}] =
               events(["event:progress\nid:4\ndata:{\"a\":1}\n\n"])
    end

    test "removes only one space after the colon" do
      assert [%{type: :progress, data: %{"a" => " x"}}] =
               events(["event: progress\ndata: {\"a\":\" x\"}\n\n"])
    end

    property "decodes the same events however the stream is split" do
      check all(
              frames <- list_of(member_of([:heartbeat, :progress, :complete]), max_length: 5),
              eol <- member_of(["\n", "\r\n", "\r"]),
              cuts <- list_of(positive_integer(), max_length: 8)
            ) do
        stream =
          frames
          |> Enum.with_index(1)
          |> Enum.map_join(fn {type, id} -> SSE.encode_event(type, %{"n" => id}, id) end)
          |> String.replace("\n", eol)

        expected = frames |> Enum.with_index(1) |> Enum.map(fn {type, id} -> {type, id} end)
        decoded = stream |> split_at(cuts) |> events() |> Enum.map(&{&1.type, &1.id})
        assert decoded == expected
      end
    end
  end

  describe "parse/2 when a frame is malformed" do
    for {label, frame} <- [
          non_integer_id: "event: heartbeat\nid: nope\n\n",
          fractional_id: "event: heartbeat\nid: 1.5\n\n",
          negative_id: "event: heartbeat\nid: -1\n\n",
          signed_id: "event: heartbeat\nid: +1\n\n",
          empty_id: "event: heartbeat\nid:\n\n",
          id_over_19_digits: "event: heartbeat\nid: 12345678901234567890\n\n",
          broken_json: "event: complete\nid: 1\ndata: {broken\n\n",
          json_that_is_not_an_object: "event: complete\nid: 1\ndata: \"done\"\n\n",
          repeated_json_member: "event: complete\nid: 1\ndata: {\"ok\":true,\"ok\":false}\n\n",
          complete_without_data: "event: complete\nid: 1\n\n",
          heartbeat_with_data: "event: heartbeat\nid: 1\ndata: {}\n\n",
          invalid_utf8_data: <<"event: progress\nid: 1\ndata: {\"a\":\"", 0xFF, "\"}\n\n">>
        ] do
      test "refuses #{label}" do
        assert SSE.parse(SSE.new(), unquote(frame)) == {:error, :malformed_event}
      end
    end
  end

  describe "parse/2 when a limit is exceeded" do
    test "refuses a line longer than 8 MiB, even split across chunks" do
      chunk = String.duplicate("x", 1024 * 1024)
      chunks = ["data: " | List.duplicate(chunk, 8)]
      assert feed(chunks) == {:error, :line_too_long}
    end

    test "refuses an unterminated frame over 16 MiB made of short lines" do
      line = "data: " <> String.duplicate("x", 1024) <> "\n"
      chunk = String.duplicate(line, 1024)
      assert feed(List.duplicate(chunk, 17)) == {:error, :frame_too_large}
    end

    test "refuses an endless stream of comments with no blank line" do
      chunk = String.duplicate(": keepalive\n", 64 * 1024)

      assert feed(Stream.repeatedly(fn -> chunk end) |> Enum.take(25)) ==
               {:error, :frame_too_large}
    end

    test "counts each frame separately, so a long stream of small frames is fine" do
      frame = SSE.encode_event(:progress, %{"pad" => String.duplicate("p", 1000)}, 1)
      chunk = String.duplicate(frame, 1024)
      assert {:ok, _events, _parser} = feed(List.duplicate(chunk, 20))
    end

    test "accepts a 4 MiB data line" do
      payload = String.duplicate("a", 4 * 1024 * 1024)
      frame = SSE.encode_event(:complete, %{"blob" => payload}, 1)

      assert [%{type: :complete, data: %{"blob" => ^payload}}] =
               frame |> split_at([1_000_000, 3_000_000]) |> events()
    end

    test "uses #{@max_line_bytes} and #{@max_frame_bytes} as the limits" do
      assert SSE.max_line_bytes() == @max_line_bytes
      assert SSE.max_frame_bytes() == @max_frame_bytes
    end
  end

  describe "parse/2 cost" do
    test "stays linear: a 1 MiB event fed one byte at a time completes quickly" do
      frame = SSE.encode_event(:complete, %{"blob" => String.duplicate("a", 1024 * 1024)}, 1)
      {microseconds, events} = :timer.tc(fn -> frame |> bytewise() |> events() end)

      assert [%{type: :complete}] = events
      assert microseconds < 5_000_000
    end
  end

  describe "parse/2 on arbitrary input" do
    property "returns a result for any chunks, and never raises" do
      check all(chunks <- list_of(binary(), max_length: 6)) do
        assert match?({:ok, _, _}, feed(chunks)) or match?({:error, _}, feed(chunks))
      end
    end
  end

  defp split_at(binary, cuts) do
    cuts
    |> Enum.map(&min(&1, byte_size(binary)))
    |> Enum.concat([0, byte_size(binary)])
    |> Enum.sort()
    |> Enum.uniq()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [from, to] -> binary_part(binary, from, to - from) end)
  end

  describe "decode_event/1 when the event type is unknown" do
    test "refuses it instead of creating an atom" do
      name = "pwn_#{System.unique_integer([:positive])}"
      assert {:error, :unknown_event_type} = SSE.decode_event("event: #{name}\nid: 1\n\n")
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end
  end

  describe "encode_retry/1" do
    test "encodes retry directive in milliseconds" do
      assert SSE.encode_retry(3000) == "retry: 3000\n\n"
    end
  end
end
