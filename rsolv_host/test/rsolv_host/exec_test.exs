defmodule RsolvHost.ExecTest do
  use ExUnit.Case, async: true

  alias RsolvHost.Exec

  describe "run/3" do
    test "argv reaches the program verbatim, with stdin input" do
      assert {:ok, %{status: 0, output: "hello"}} =
               Exec.run("head", ["-c", "5"], input: "hello world")
    end

    test "shell metacharacters are just bytes" do
      assert {:ok, %{output: "$(id);`id`\n"}} = Exec.run("echo", ["$(id);`id`"])
    end

    test "returns the program's exit status" do
      assert {:ok, %{status: 1, output: ""}} = Exec.run("false", [])
    end

    test "a hung program is killed at the deadline" do
      started = System.monotonic_time(:millisecond)

      assert {:error, :timeout} = Exec.run("sleep", ["5"], timeout_ms: 100)
      assert System.monotonic_time(:millisecond) - started < 2_000
    end

    test "output over the cap is refused" do
      assert {:error, :output_too_large} =
               Exec.run("head", ["-c", "1001", "/dev/zero"], max_bytes: 1_000)
    end

    test "output exactly at the cap is kept" do
      assert {:ok, %{output: output}} =
               Exec.run("head", ["-c", "1000", "/dev/zero"], max_bytes: 1_000)

      assert byte_size(output) == 1_000
    end

    test "an endless stream is cut off at the cap" do
      assert {:error, :output_too_large} = Exec.run("yes", [], max_bytes: 1_000)
    end

    test "a missing executable is an error, not a crash" do
      assert {:error, :enoent} = Exec.run("rsolv-no-such-binary", [])
    end

    test "stderr joins the captured output, so it never reaches the Actions log" do
      assert {:ok, %{status: 2, output: output}} = Exec.run("ls", ["/rsolv-no-such-path"])
      assert output =~ "/rsolv-no-such-path"
    end

    test "leaves no port messages behind after a kill" do
      {:error, :output_too_large} = Exec.run("yes", [], max_bytes: 1_000)

      refute_receive {_port, {:data, _}}, 50
    end
  end

  describe "open/3 and command/3" do
    test "talks to a long-running program both ways" do
      {:ok, port} = Exec.open("head", ["-c", "4"], [])
      :ok = Exec.command(port, "ping", System.monotonic_time(:millisecond) + 5_000)

      assert_receive {^port, {:data, "ping"}}, 1_000
      assert_receive {^port, {:exit_status, 0}}, 1_000
    end

    test "a missing executable is an error" do
      assert {:error, :enoent} = Exec.open("rsolv-no-such-binary", [], [])
    end
  end

  describe "command/3" do
    test "when the program doesn't read its input, gives up at the deadline instead of blocking" do
      {:ok, port} = Exec.open("sleep", ["5"], [])
      deadline = System.monotonic_time(:millisecond) + 300
      chunk = :binary.copy("x", 1024 * 1024)

      results = for _ <- 1..4, do: Exec.command(port, chunk, deadline)

      assert {:error, :timeout} in results
      assert System.monotonic_time(:millisecond) - deadline < 1_000
      Port.close(port)
    end
  end
end
