defmodule RsolvHost.FakeExecTest do
  use ExUnit.Case, async: true

  alias RsolvHost.FakeExec

  describe "run/3" do
    test "answers from the first matching rule and records every call in order" do
      FakeExec.script([
        {fn {"docker", ["inspect" | _], _} -> true end,
         {:ok, %{status: 0, output: "172.18.0.2"}}},
        {fn {"docker", _, _} -> true end,
         fn {_, args, _} -> {:ok, %{status: 0, output: hd(args)}} end}
      ])

      assert {:ok, %{output: "172.18.0.2"}} = FakeExec.run("docker", ["inspect", "x"], [])
      assert {:ok, %{output: "rm"}} = FakeExec.run("docker", ["rm", "x"], timeout_ms: 5)
      assert {:ok, %{status: 0, output: ""}} = FakeExec.run("cp", ["a"], [])

      assert FakeExec.calls() == [
               {"docker", ["inspect", "x"], []},
               {"docker", ["rm", "x"], [timeout_ms: 5]},
               {"cp", ["a"], []}
             ]
    end

    test "is scoped to the test process and the processes it starts" do
      FakeExec.script([])
      Task.await(Task.async(fn -> FakeExec.run("cp", [], []) end))

      assert [{"cp", [], []}] = FakeExec.calls()
    end
  end

  describe "open/3 and command/2" do
    test "hands the opened channel to a scripted process that receives every command" do
      test = self()
      sandbox = spawn_link(fn -> receive do: ({:command, data} -> send(test, {:got, data})) end)
      FakeExec.script([{fn {"docker", ["exec" | _], _} -> true end, {:ok, sandbox}}])

      assert {:ok, ^sandbox} = FakeExec.open("docker", ["exec"], [])
      assert FakeExec.command(sandbox, ["pi", "ng"]) == :ok
      assert_receive {:got, "ping"}
    end
  end
end
