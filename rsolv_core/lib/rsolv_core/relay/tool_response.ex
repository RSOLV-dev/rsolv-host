defmodule RsolvCore.Relay.ToolResponse do
  @moduledoc """
  A tool execution response, sent from the host to the platform.

  ## Fields
  - `request_id` — matches the `id` from the corresponding `RsolvCore.Relay.ToolRequest`
  - `result` — tool execution result (map or string)
  - `error` — error message if execution failed, nil on success
  - `protocol_version` — the relay protocol version (`RsolvCore.Relay.protocol_version/0`)
  """

  @type t :: %__MODULE__{
          request_id: String.t(),
          result: map() | String.t() | nil,
          error: String.t() | nil,
          protocol_version: pos_integer()
        }
  @enforce_keys [:request_id]
  defstruct [:request_id, :result, :error, protocol_version: 1]

  @doc "The string-keyed map posted to the platform as a `tool_response`."
  @spec to_wire(t()) :: %{String.t() => term()}
  def to_wire(%__MODULE__{} = response) do
    %{
      "request_id" => response.request_id,
      "result" => response.result,
      "error" => response.error,
      "protocol_version" => response.protocol_version
    }
  end
end
