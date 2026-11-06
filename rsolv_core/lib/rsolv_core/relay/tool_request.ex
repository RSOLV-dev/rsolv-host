defmodule RsolvCore.Relay.ToolRequest do
  @moduledoc """
  A tool execution request, sent from the platform to the host.

  ## Fields
  - `id` — unique request ID (e.g., `req_abc123`)
  - `tool` — tool name atom (`:read_file`, `:write_file`, `:bash`, etc.)
  - `input` — tool-specific input map
  - `timeout_ms` — maximum time to wait for response: 1 ms to
    `max_timeout_ms/0` (30 minutes), 30 s when the platform omits it
  - `protocol_version` — the relay protocol version (`RsolvCore.Relay.protocol_version/0`)
  """

  @type t :: %__MODULE__{
          id: String.t(),
          tool: RsolvCore.Relay.tool(),
          input: map(),
          timeout_ms: non_neg_integer(),
          protocol_version: pos_integer()
        }
  # Twice the platform's longest tool timeout (15 minutes, for VALIDATE and
  # MITIGATE, which cover uncached dependency installs), so the host never
  # gives up first, yet no request can hold a tool for longer than a decision
  # stays valid.
  @max_timeout_ms 1_800_000

  @enforce_keys [:id, :tool, :input]
  defstruct [:id, :tool, :input, timeout_ms: 30_000, protocol_version: 1]

  @doc "The largest `timeout_ms` a `tool_request` may carry: 30 minutes."
  @spec max_timeout_ms() :: pos_integer()
  def max_timeout_ms, do: @max_timeout_ms

  @doc """
  Decodes a `tool_request` event's data. Tool names go through
  `RsolvCore.Relay.tool/1`, never `String.to_atom/1`. A `timeout_ms` that is
  present but not an integer from 1 to `max_timeout_ms/0` is refused.
  """
  @spec from_wire(term()) ::
          {:ok, t()}
          | {:error, :unknown_tool | :malformed_tool_request | {:protocol_version, term()}}
  def from_wire(%{"id" => id, "tool" => name, "input" => %{} = input} = wire)
      when is_binary(id) and is_binary(name) do
    with :ok <- RsolvCore.Relay.check_version(wire["protocol_version"]),
         {:ok, tool} <- RsolvCore.Relay.tool(name),
         {:ok, timeout_ms} <- timeout(wire) do
      {:ok, %__MODULE__{id: id, tool: tool, input: input, timeout_ms: timeout_ms}}
    end
  end

  def from_wire(_wire), do: {:error, :malformed_tool_request}

  defp timeout(%{"timeout_ms" => ms}) when is_integer(ms) and ms in 1..@max_timeout_ms,
    do: {:ok, ms}

  defp timeout(%{"timeout_ms" => _invalid}), do: {:error, :malformed_tool_request}
  defp timeout(_absent), do: {:ok, 30_000}
end
