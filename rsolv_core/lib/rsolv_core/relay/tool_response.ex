defmodule RsolvCore.Relay.ToolResponse do
  @moduledoc """
  A tool execution response, sent from the host to the platform.

  ## Fields
  - `request_id` — matches the `id` from the corresponding `RsolvCore.Relay.ToolRequest`
  - `result` — tool execution result (map or string)
  - `error` — error message if execution failed, nil on success
  """

  @type t :: %__MODULE__{
          request_id: String.t(),
          result: map() | String.t() | nil,
          error: String.t() | nil
        }
  @enforce_keys [:request_id]
  defstruct [:request_id, :result, :error]
end
