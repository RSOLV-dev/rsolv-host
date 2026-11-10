defmodule RsolvHost.KilledVm do
  @moduledoc """
  Test helpers for a job the runner stops with SIGTERM: a separate VM running
  a script, the containers another job could own, and Docker's view of them.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @doc "Runs `script` in a new VM with this build's code; the script prints `ready <os pid>`."
  @spec start(String.t()) :: port()
  def start(script) do
    ebin =
      for dir <- Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin")),
          arg <- ["-pa", dir],
          do: arg

    Port.open({:spawn_executable, System.find_executable("elixir")}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: ebin ++ ["-e", script]
    ])
  end

  @doc "Waits for the VM's `ready <os pid>` and answers the pid."
  @spec ready(port(), String.t()) :: String.t()
  def ready(port, acc \\ "") do
    receive do
      {^port, {:data, data}} ->
        case Regex.run(~r/ready (\d+)/, acc <> data) do
          [_, pid] -> pid
          nil -> ready(port, acc <> data)
        end

      {^port, {:exit_status, status}} ->
        flunk("the VM exited #{status} before it was ready: #{acc}")
    after
      300_000 -> flunk("the VM never became ready: #{acc}")
    end
  end

  @doc "Waits for the VM to exit: `{status, output}`."
  @spec exited(port(), String.t()) :: {non_neg_integer(), String.t()}
  def exited(port, acc \\ "") do
    receive do
      {^port, {:data, data}} -> exited(port, acc <> data)
      {^port, {:exit_status, status}} -> {status, acc}
    after
      120_000 -> flunk("the VM didn't stop after SIGTERM: #{acc}")
    end
  end

  @doc "A container another job could own, labelled `rsolv.<key>=<value>`; removed on exit."
  @spec bystander(map(), String.t()) :: String.t()
  def bystander(labels, image) do
    args = for {key, value} <- labels, arg <- ["--label", "rsolv.#{key}=#{value}"], do: arg

    {id, 0} =
      System.cmd("docker", ["run", "-d" | args] ++ ["--entrypoint", "sleep", image, "300"])

    id = String.trim(id)

    ExUnit.Callbacks.on_exit(fn ->
      System.cmd("docker", ["rm", "-f", id], stderr_to_stdout: true)
    end)

    id
  end

  @doc "Whether Docker still has the container or network `id`."
  @spec alive?(String.t()) :: boolean()
  def alive?(id),
    do: match?({_, 0}, System.cmd("docker", ["inspect", id], stderr_to_stdout: true))
end
