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

  @doc """
  Decodes a posted `tool_response`, the inverse of `to_wire/1`. Every key is
  required: a non-empty `request_id`, a `result` that is an object, a string or
  null, and an `error` that is a string or null. The protocol version is checked
  as for `RsolvCore.Relay.ToolRequest.from_wire/1`.
  """
  @spec from_wire(term()) ::
          {:ok, t()} | {:error, :malformed_tool_response | {:protocol_version, term()}}
  def from_wire(%{"request_id" => id, "result" => result, "error" => error} = wire)
      when is_binary(id) and id != "" and
             (is_map(result) or is_binary(result) or is_nil(result)) and
             (is_binary(error) or is_nil(error)) do
    with :ok <- RsolvCore.Relay.check_version(wire["protocol_version"]) do
      {:ok, %__MODULE__{request_id: id, result: result, error: error}}
    end
  end

  def from_wire(_wire), do: {:error, :malformed_tool_response}

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
