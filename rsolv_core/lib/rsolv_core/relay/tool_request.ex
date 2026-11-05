defmodule RsolvCore.Relay.ToolRequest do
  @moduledoc """
  A tool execution request, sent from the platform to the host.

  ## Fields
  - `id` — unique request ID (e.g., `req_abc123`)
  - `tool` — tool name atom (`:read_file`, `:write_file`, `:bash`, etc.)
  - `input` — tool-specific input map
  - `timeout_ms` — maximum time to wait for response (default: 30s)
  - `protocol_version` — the relay protocol version (`RsolvCore.Relay.protocol_version/0`)
  """

  @type t :: %__MODULE__{
          id: String.t(),
          tool: RsolvCore.Relay.tool(),
          input: map(),
          timeout_ms: non_neg_integer(),
          protocol_version: pos_integer()
        }
  @enforce_keys [:id, :tool, :input]
  defstruct [:id, :tool, :input, timeout_ms: 30_000, protocol_version: 1]

  @doc "Decodes a `tool_request` event's data. Tool names go through `RsolvCore.Relay.tool/1`, never `String.to_atom/1`."
  @spec from_wire(term()) ::
          {:ok, t()}
          | {:error, :unknown_tool | :malformed_tool_request | {:protocol_version, term()}}
  def from_wire(%{"id" => id, "tool" => name, "input" => %{} = input} = wire)
      when is_binary(id) and is_binary(name) do
    with :ok <- RsolvCore.Relay.check_version(wire["protocol_version"]),
         {:ok, tool} <- RsolvCore.Relay.tool(name) do
      {:ok,
       %__MODULE__{id: id, tool: tool, input: input, timeout_ms: timeout(wire["timeout_ms"])}}
    end
  end

  def from_wire(_wire), do: {:error, :malformed_tool_request}

  defp timeout(ms) when is_integer(ms) and ms > 0, do: ms
  defp timeout(_absent_or_invalid), do: 30_000
end
