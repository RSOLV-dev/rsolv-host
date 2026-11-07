defmodule RsolvHost do
  @moduledoc """
  The trusted host client that RSOLV's reusable workflows run on a customer's
  runner (RFC-150). One role per invocation; see `RsolvHost.CLI`.
  """

  @doc "The process runner: `RsolvHost.Exec` unless the `:exec` setting swaps it (tests)."
  @spec exec() :: module()
  def exec, do: Application.get_env(:rsolv_host, :exec, RsolvHost.Exec)
end
