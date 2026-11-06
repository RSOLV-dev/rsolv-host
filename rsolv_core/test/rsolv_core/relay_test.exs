defmodule RsolvCore.RelayTest do
  use ExUnit.Case, async: true
  doctest RsolvCore.Relay

  alias RsolvCore.Relay
  alias RsolvCore.Relay.{ToolRequest, ToolResponse}

  describe "tools/0" do
    test "lists the six tools of the RFC-096 protocol" do
      assert Relay.tools() == [:read_file, :write_file, :edit_file, :glob, :grep, :bash]
    end
  end

  describe "tool/1" do
    test "maps a wire name to its atom" do
      assert {:ok, :grep} = Relay.tool("grep")
    end

    test "refuses an unknown name without creating an atom" do
      name = "pwn_#{System.unique_integer([:positive])}"
      assert {:error, :unknown_tool} = Relay.tool(name)
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end
  end

  describe "ToolRequest struct" do
    test "creates a valid tool request" do
      request = %ToolRequest{
        id: "req_123",
        tool: :read_file,
        input: %{path: "/app/server.js"},
        timeout_ms: 30_000
      }

      assert %ToolRequest{
               id: "req_123",
               tool: :read_file,
               input: %{path: "/app/server.js"},
               timeout_ms: 30_000
             } = request
    end

    test "enforces required keys" do
      assert_raise ArgumentError, fn -> struct!(ToolRequest, %{}) end
    end
  end

  describe "ToolResponse struct" do
    test "creates a valid tool response with result" do
      response = %ToolResponse{request_id: "req_123", result: "file contents here", error: nil}

      assert %ToolResponse{request_id: "req_123", result: "file contents here", error: nil} =
               response
    end

    test "creates a valid tool response with error" do
      response = %ToolResponse{request_id: "req_123", result: nil, error: "file not found"}

      assert response.error == "file not found"
    end

    test "enforces required keys" do
      assert_raise ArgumentError, fn -> struct!(ToolResponse, %{}) end
    end
  end

  describe "ToolRequest.from_wire/1" do
    test "decodes a wire request" do
      wire = %{
        "id" => "req_1",
        "tool" => "bash",
        "input" => %{"command" => "ls"},
        "timeout_ms" => 5_000,
        "protocol_version" => 1
      }

      assert {:ok, %ToolRequest{id: "req_1", tool: :bash, timeout_ms: 5_000}} =
               ToolRequest.from_wire(wire)
    end

    test "defaults the timeout to 30 s" do
      assert {:ok, %ToolRequest{timeout_ms: 30_000}} =
               ToolRequest.from_wire(%{
                 "id" => "req_1",
                 "tool" => "glob",
                 "input" => %{},
                 "protocol_version" => 1
               })
    end

    test "refuses an unknown tool without creating an atom" do
      name = "pwn_#{System.unique_integer([:positive])}"

      assert {:error, :unknown_tool} =
               ToolRequest.from_wire(%{
                 "id" => "r",
                 "tool" => name,
                 "input" => %{},
                 "protocol_version" => 1
               })

      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "refuses a malformed request" do
      assert {:error, :malformed_tool_request} =
               ToolRequest.from_wire(%{"id" => 1, "tool" => "bash"})
    end
  end

  describe "protocol_version/0" do
    test "is 1" do
      assert Relay.protocol_version() == 1
    end
  end

  describe "check_version/1" do
    test "accepts our version" do
      assert Relay.check_version(1) == :ok
    end

    test "refuses a newer version" do
      assert Relay.check_version(2) == {:error, {:protocol_version, 2}}
    end

    test "refuses a missing version" do
      assert Relay.check_version(nil) == {:error, {:protocol_version, nil}}
    end
  end

  describe "ToolRequest protocol_version" do
    test "defaults to 1 and is encoded on the wire" do
      request = %ToolRequest{id: "r", tool: :bash, input: %{}}

      assert request.protocol_version == 1
      assert JSON.encode!(Map.from_struct(request)) =~ ~s("protocol_version":1)
    end
  end

  describe "ToolRequest.from_wire/1 when the protocol version differs" do
    test "refuses a newer version" do
      wire = %{"id" => "r", "tool" => "bash", "input" => %{}, "protocol_version" => 2}
      assert ToolRequest.from_wire(wire) == {:error, {:protocol_version, 2}}
    end

    test "refuses a missing version" do
      wire = %{"id" => "r", "tool" => "bash", "input" => %{}}
      assert ToolRequest.from_wire(wire) == {:error, {:protocol_version, nil}}
    end
  end

  describe "ToolRequest.from_wire/1 on timeout_ms" do
    defp request(timeout_ms) do
      %{
        "id" => "r",
        "tool" => "bash",
        "input" => %{},
        "timeout_ms" => timeout_ms,
        "protocol_version" => 1
      }
    end

    test "accepts the 30-minute maximum" do
      assert ToolRequest.max_timeout_ms() == 1_800_000

      assert {:ok, %ToolRequest{timeout_ms: 1_800_000}} =
               ToolRequest.from_wire(request(1_800_000))
    end

    test "accepts the platform's 15-minute tool timeout" do
      assert {:ok, %ToolRequest{timeout_ms: 900_000}} = ToolRequest.from_wire(request(900_000))
    end

    for {label, value} <- [
          over_the_maximum: 1_800_001,
          huge: 1_000_000_000_000_000_000_000,
          zero: 0,
          negative: -1,
          float: 5_000.0,
          string: "5000",
          null: nil
        ] do
      test "refuses #{label}" do
        assert ToolRequest.from_wire(request(unquote(value))) == {:error, :malformed_tool_request}
      end
    end
  end

  describe "ToolResponse.to_wire/1" do
    test "builds the string-keyed wire map with the protocol version" do
      response = %ToolResponse{request_id: "r", result: %{"ok" => true}}

      assert ToolResponse.to_wire(response) == %{
               "request_id" => "r",
               "result" => %{"ok" => true},
               "error" => nil,
               "protocol_version" => 1
             }
    end
  end
end
