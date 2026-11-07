defmodule RsolvHost.Application do
  @moduledoc """
  Starts the host. In a release (`run_cli`), it runs the command line once and
  halts with its exit code; Burrito runs the release embedded, so this is the
  entry point. `RsolvHost.TaskSupervisor` runs the token keeper's refreshes.
  """

  use Application

  alias Burrito.Util.Args
  alias RsolvHost.{CLI, Outcome}

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(children(Application.get_env(:rsolv_host, :run_cli, false)),
      strategy: :one_for_one,
      name: RsolvHost.Supervisor
    )
  end

  defp children(false), do: [{Task.Supervisor, name: RsolvHost.TaskSupervisor}]

  defp children(true) do
    children(false) ++
      [
        {Task,
         fn ->
           run_cli(
             fn -> CLI.main(Args.argv(), System.get_env(), :code.root_dir()) end,
             &System.halt/1
           )
         end}
      ]
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
