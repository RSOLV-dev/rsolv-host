defmodule RsolvHost.Exec do
  @moduledoc """
  Runs an executable with an argv list through a Port (`:spawn_executable`).
  No shell is involved: every argument reaches the program as one verbatim
  string. Every run has a deadline and an output cap.

  Callers go through `RsolvHost.exec/0`, so tests can swap in a fake.
  """

  @type result ::
          {:ok, %{status: non_neg_integer(), output: binary()}}
          | {:error, :enoent | :timeout | :output_too_large}

  @callback run(String.t(), [String.t()], keyword()) :: result()
  @callback open(String.t(), [String.t()], keyword()) :: {:ok, port()} | {:error, :enoent}
  @callback command(port(), iodata(), integer()) :: :ok | {:error, :timeout | :closed}

  @default_timeout_ms 60_000
  @default_max_bytes 1_048_576

  @doc """
  Runs `executable` (looked up on `PATH`) with `args` and collects its output.

  Options: `:input` (bytes written to stdin), `:timeout_ms` (default 60 s; the
  program is killed at the deadline), `:max_bytes` (default 1 MiB; the program
  is killed when its output passes it).

  stderr is always merged into stdout: an inherited stderr would be the BEAM's
  own, which is the Actions log, so no child byte reaches it uncapped.
  """
  @spec run(String.t(), [String.t()], keyword()) :: result()
  def run(executable, args, opts \\ []) do
    deadline =
      System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    with {:ok, port} <- open(executable, args, opts) do
      max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

      # A program that exits without reading its input still reports its output.
      case command(port, opts[:input] || "", deadline) do
        {:error, :timeout} -> kill(port, :timeout)
        _written_or_closed -> collect(port, [], 0, max_bytes, deadline)
      end
    end
  end

  @doc """
  Starts `executable` with `args` and returns its Port, owned by the caller, for
  a conversation in both directions (`command/3` writes; the owner receives
  `{port, {:data, bytes}}` and `{port, {:exit_status, status}}`). stderr is
  merged, as for `run/3`.
  """
  @spec open(String.t(), [String.t()], keyword()) :: {:ok, port()} | {:error, :enoent}
  def open(executable, args, _opts) do
    case System.find_executable(executable) do
      nil ->
        {:error, :enoent}

      path ->
        {:ok,
         Port.open(
           {:spawn_executable, path},
           [:binary, :exit_status, :use_stdio, :stderr_to_stdout, :hide, args: args]
         )}
    end
  end

  @doc """
  Writes `data` to the program's stdin, but only before `deadline` (monotonic
  milliseconds): past it, nothing is written and the answer is `{:error,
  :timeout}`. While the port is busy (the program isn't reading), it waits until
  the deadline. `{:error, :closed}` once the program has exited.
  """
  @spec command(port(), iodata(), integer()) :: :ok | {:error, :timeout | :closed}
  def command(port, data, deadline) do
    cond do
      System.monotonic_time(:millisecond) >= deadline -> {:error, :timeout}
      Port.command(port, data, [:nosuspend]) -> :ok
      true -> wait_and_command(port, data, deadline)
    end
  rescue
    ArgumentError -> {:error, :closed}
  end

  defp wait_and_command(port, data, deadline) do
    Process.sleep(10)
    command(port, data, deadline)
  end

  defp collect(port, acc, size, max, deadline) do
    receive do
      {^port, {:data, data}} when size + byte_size(data) > max ->
        kill(port, :output_too_large)

      {^port, {:data, data}} ->
        collect(port, [acc, data], size + byte_size(data), max, deadline)

      {^port, {:exit_status, status}} ->
        {:ok, %{status: status, output: IO.iodata_to_binary(acc)}}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> kill(port, :timeout)
    end
  end

  defp kill(port, reason) do
    with {:os_pid, pid} <- Port.info(port, :os_pid),
         do: System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

    close(port)
    flush(port)
    {:error, reason}
  end

  # The killed program's port may close on its own between the kill and here.
  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> true
  end

  defp flush(port) do
    receive do
      {^port, _message} -> flush(port)
    after
      0 -> :ok
    end
  end
end
