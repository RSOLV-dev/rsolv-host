defmodule RsolvHost.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias RsolvHost.CLI

  @env %{
    "RUNNER_TEMP" => "/home/runner/work/_temp",
    "RSOLV_HOST_INSTALL_DIR" => "/home/runner/work/_temp/rsolv-host"
  }
  @root "/home/runner/work/_temp/rsolv-host/.burrito/rsolv_host"

  describe "main/3" do
    test "version prints the version and exits 0" do
      out = capture_io(fn -> assert CLI.main(["version"], @env, @root) == 0 end)

      assert out == "rsolv-host 0.1.0\n"
    end

    test "when work has no --issue, prints usage and exits 2" do
      out = capture_io(fn -> assert CLI.main(["work"], @env, @root) == 2 end)

      assert out =~ "usage: rsolv-host"
    end

    test "when the command is Burrito's maintenance, exits 2" do
      capture_io(fn -> assert CLI.main(["maintenance", "uninstall"], @env, @root) == 2 end)
    end

    test "when the preflight fails, prints one error line, runs no command and exits 2" do
      out =
        capture_io(fn ->
          assert CLI.main(["version"], Map.delete(@env, "RUNNER_TEMP"), @root) == 2
        end)

      assert [line] = String.split(out, "\n", trim: true)
      assert line =~ ~r/\A::error title=RSOLV configuration::.*RUNNER_TEMP/
      refute out =~ "rsolv-host 0.1.0"
    end
  end

  describe "commands/0" do
    test "is exactly the five roles and leaves maintenance to Burrito" do
      assert CLI.commands() == ~w(publish scan selftest version work)
      refute "maintenance" in CLI.commands()
    end
  end
end
