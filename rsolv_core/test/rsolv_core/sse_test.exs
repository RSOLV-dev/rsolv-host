defmodule RsolvCore.Relay.SSETest do
  use ExUnit.Case, async: true
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

  describe "parse/2" do
    test "splits complete events and keeps the partial tail" do
      {events, rest} = SSE.parse("", "event: progress\nid: 1\ndata: {\"a\":1}\n\nevent: heart")
      assert [%{type: :progress, id: 1, data: %{"a" => 1}}] = events
      assert rest == "event: heart"
    end

    test "an event split across chunks arrives once" do
      {[], rest} = SSE.parse("", "event: complete\nid: 2\nda")

      assert {[%{type: :complete, data: %{"ok" => true}}], ""} =
               SSE.parse(rest, "ta: {\"ok\":true}\n\n")
    end

    test "keepalive comments are dropped" do
      assert {[], ""} = SSE.parse("", ": keepalive\n\n")
    end
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
