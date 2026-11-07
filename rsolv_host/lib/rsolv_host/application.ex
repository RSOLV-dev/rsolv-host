defmodule RsolvHost.Application do
  @moduledoc """
  Starts the host. In a release (`run_cli`), it runs the command line once and
  halts with its exit code; Burrito runs the release embedded, so this is the
  entry point.
  """

  use Application

  alias Burrito.Util.Args
  alias RsolvHost.CLI

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(children(Application.get_env(:rsolv_host, :run_cli, false)),
      strategy: :one_for_one,
      name: RsolvHost.Supervisor
    )
  end

  defp children(false), do: []

  defp children(true) do
    [
      {Task,
       fn ->
         System.halt(CLI.main(Args.argv(), System.get_env(), :code.root_dir()))
       end}
    ]
  end
end
