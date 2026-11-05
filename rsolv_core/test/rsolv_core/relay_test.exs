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
        "timeout_ms" => 5_000
      }

      assert {:ok, %ToolRequest{id: "req_1", tool: :bash, timeout_ms: 5_000}} =
               ToolRequest.from_wire(wire)
    end

    test "defaults the timeout to 30 s" do
      assert {:ok, %ToolRequest{timeout_ms: 30_000}} =
               ToolRequest.from_wire(%{"id" => "req_1", "tool" => "glob", "input" => %{}})
    end

    test "refuses an unknown tool without creating an atom" do
      name = "pwn_#{System.unique_integer([:positive])}"

      assert {:error, :unknown_tool} =
               ToolRequest.from_wire(%{"id" => "r", "tool" => name, "input" => %{}})

      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "refuses a malformed request" do
      assert {:error, :malformed_tool_request} =
               ToolRequest.from_wire(%{"id" => 1, "tool" => "bash"})
    end
  end
end
