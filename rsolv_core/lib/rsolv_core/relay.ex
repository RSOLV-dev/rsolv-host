defmodule RsolvCore.Relay do
  @moduledoc """
  The tool-relay protocol between the RSOLV platform and the host (RFC-096).

  The platform streams `tool_request` events over SSE; the host executes each
  tool and posts a `tool_response`. Tool names arrive as strings and are decoded
  only through `tool/1`, an explicit allowlist, so no wire input becomes an atom.

      iex> RsolvCore.Relay.tool("read_file")
      {:ok, :read_file}

      iex> RsolvCore.Relay.tool("rm_rf")
      {:error, :unknown_tool}
  """

  @tools [:read_file, :write_file, :edit_file, :glob, :grep, :bash]
  @by_name Map.new(@tools, &{Atom.to_string(&1), &1})

  @type tool :: :read_file | :write_file | :edit_file | :glob | :grep | :bash

  @doc "The tools of the relay protocol, in protocol order."
  @spec tools() :: [tool()]
  def tools, do: @tools

  @doc "Maps a wire tool name to its atom, refusing any name outside `tools/0`."
  @spec tool(String.t()) :: {:ok, tool()} | {:error, :unknown_tool}
  def tool(name) do
    case Map.fetch(@by_name, name) do
      {:ok, tool} -> {:ok, tool}
      :error -> {:error, :unknown_tool}
    end
  end
end
