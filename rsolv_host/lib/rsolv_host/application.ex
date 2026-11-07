defmodule RsolvHost.Application do
  @moduledoc """
  Starts the host. In a release (`run_cli`), `start/2` runs the command line to
  the end and halts with its exit code, before it returns: Burrito boots the
  release with `-s elixir start_cli`, which, once boot finishes, would run the
  first argument as an Elixir script file. `RsolvHost.TaskSupervisor` (started
  first) runs the token keeper's refreshes.
  """

  use Application

  alias Burrito.Util.Args
  alias RsolvHost.{CLI, Outcome}

  @impl true
  def start(_type, _args) do
    {:ok, sup} =
      Supervisor.start_link([{Task.Supervisor, name: RsolvHost.TaskSupervisor}],
        strategy: :one_for_one,
        name: RsolvHost.Supervisor
      )

    if Application.get_env(:rsolv_host, :run_cli, false),
      do:
        run_cli(
          fn -> CLI.main(Args.argv(), System.get_env(), :code.root_dir()) end,
          &System.halt/1
        )

    {:ok, sup}
  end

  @doc """
  Runs `main` (the command line, returning its exit code) in a monitored
  process and calls `halt` with that code. Whatever ends the command line, an
  exit, a throw or a linked process failing, `halt` is called: an abnormal end
  is a host bug (1), annotated without its reason, which may hold a secret.
  """
  @spec run_cli((-> non_neg_integer()), (non_neg_integer() -> term())) :: term()
  def run_cli(main, halt) do
    callers = [self() | Process.get(:"$callers", [])]

    {pid, ref} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)
        exit({:shutdown, {:exit_code, main.()}})
      end)

    receive do
      {:DOWN, ^ref, :process, ^pid, {:shutdown, {:exit_code, code}}} ->
        halt.(code)

      {:DOWN, ^ref, :process, ^pid, _abnormal} ->
        Outcome.annotate({:unexpected, :exit})
        halt.(1)
    end
  end
end
