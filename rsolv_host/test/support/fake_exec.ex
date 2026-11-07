defmodule RsolvHost.FakeExec do
  @moduledoc """
  A scripted `RsolvHost.Exec` for tests. A test installs rules with `script/1`;
  each call is recorded and answered by the first rule whose matcher returns
  true for `{executable, args, opts}` (a matcher whose clauses don't match is a
  miss). An unmatched `run/3` exits 0 with no output.

  State belongs to the test process (found through `$callers`), so tests using
  it stay `async: true`.
  """

  @behaviour RsolvHost.Exec

  @type call :: {String.t(), [String.t()], keyword()}
  @type rule :: {(call() -> boolean()), term() | (call() -> term())}

  @doc "Starts the registry that maps a test process to its script."
  @spec start() :: {:ok, pid()}
  def start, do: Registry.start_link(keys: :unique, name: __MODULE__.Registry)

  @doc "Installs `rules` for the calling test process."
  @spec script([rule()]) :: :ok
  def script(rules) do
    {:ok, agent} = Agent.start_link(fn -> %{rules: rules, calls: []} end)
    {:ok, _owner} = Registry.register(__MODULE__.Registry, self(), agent)
    :ok
  end

  @doc "The recorded calls, oldest first."
  @spec calls() :: [call()]
  def calls, do: Agent.get(agent(), &Enum.reverse(&1.calls))

  @impl true
  @doc false
  def run(executable, args, opts),
    do: answer({executable, args, opts}, {:ok, %{status: 0, output: ""}})

  @impl true
  @doc false
  def open(executable, args, opts), do: answer({executable, args, opts}, {:error, :enoent})

  @impl true
  @doc false
  def command(pid, data) when is_pid(pid) do
    send(pid, {:command, IO.iodata_to_binary(data)})
    :ok
  end

  defp answer(call, default) do
    rules = Agent.get_and_update(agent(), &{&1.rules, %{&1 | calls: [call | &1.calls]}})

    case Enum.find(rules, fn {matches?, _result} -> matches?(matches?, call) end) do
      nil -> default
      {_matches?, result} when is_function(result, 1) -> result.(call)
      {_matches?, result} -> result
    end
  end

  # A matcher may be a bare pattern (`fn {"docker", ["rm" | _], _} -> true end`).
  defp matches?(matcher, call) do
    matcher.(call)
  rescue
    FunctionClauseError -> false
  end

  defp agent do
    Enum.find_value([self() | Process.get(:"$callers", [])], fn pid ->
      case Registry.lookup(__MODULE__.Registry, pid) do
        [{^pid, agent}] -> agent
        [] -> nil
      end
    end) || raise "RsolvHost.FakeExec: no script for this test; call FakeExec.script/1"
  end
end
