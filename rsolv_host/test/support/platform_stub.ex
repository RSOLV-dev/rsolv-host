defmodule RsolvHost.PlatformStub do
  @moduledoc """
  Test helpers for the platform side of a session: a `Req.Test` stub with a run
  token exchange, SSE bodies, and a record of what the host posted.
  """

  alias RsolvCore.Relay.SSE

  @doc "A token-exchange response for an issue-bound role."
  @spec token(String.t()) :: map()
  def token(raw \\ "rsolv_rt_testAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA") do
    %{
      token: raw,
      expires_at:
        DateTime.utc_now()
        |> DateTime.add(3_600)
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601(),
      protocol_version: 1,
      pipeline_run_id: "0b0e5f7c-7d3c-4d8e-9a55-3f6f1b0c2a11",
      base_sha: String.duplicate("b", 40),
      target_branch: "main"
    }
  end

  @doc "An SSE body of `events`, each `{type, data}`, numbered from 1."
  @spec sse([{atom(), map() | nil}]) :: binary()
  def sse(events) do
    events
    |> Enum.with_index(1)
    |> Enum.map_join(fn {{type, data}, id} -> SSE.encode_event(type, data, id) end)
  end

  @doc "A `tool_request` event's data."
  @spec tool_request(String.t(), String.t(), map(), keyword()) :: map()
  def tool_request(id, tool, input, opts \\ []) do
    %{
      "id" => id,
      "tool" => tool,
      "input" => input,
      "timeout_ms" => Keyword.get(opts, :timeout_ms, 30_000),
      "protocol_version" => Keyword.get(opts, :protocol_version, 1)
    }
  end

  @doc "Reads and decodes a JSON request body."
  @spec body(Plug.Conn.t()) :: {map(), Plug.Conn.t()}
  def body(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {JSON.decode!(body), conn}
  end

  @doc "Sends `body` as an event stream."
  @spec stream(Plug.Conn.t(), binary()) :: Plug.Conn.t()
  def stream(conn, body) do
    conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.send_resp(200, body)
  end
end
