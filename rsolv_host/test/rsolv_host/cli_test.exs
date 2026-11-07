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

  describe "main/4 with a role" do
    @describetag :tmp_dir

    defp commands(fun), do: %{"work" => {fun, [issue: :integer], [:issue]}}

    test "when the role raises, annotates a host bug and exits 1" do
      boom = fn _opts, _env -> raise ArgumentError, "secret detail" end

      out =
        capture_io(fn ->
          assert CLI.main(["work", "--issue", "7"], @env, @root, commands: commands(boom)) == 1
        end)

      assert out =~ "::error title=RSOLV host client bug::"
      assert out =~ "ArgumentError"
      refute out =~ "secret detail"
    end

    test "when the role exits or throws, annotates a host bug and exits 1, logging no reason" do
      for role <- [
            fn _opts, _env -> exit({:timeout, {GenServer, :call, ["secret detail"]}}) end,
            fn _opts, _env -> throw("secret detail") end
          ] do
        out =
          capture_io(fn ->
            assert CLI.main(["work", "--issue", "7"], @env, @root, commands: commands(role)) == 1
          end)

        assert out =~ "::error title=RSOLV host client bug::"
        refute out =~ "secret detail"
      end
    end

    test "when the role reaches a model outcome, reports it and exits 0", %{tmp_dir: dir} do
      env = Map.put(@env, "GITHUB_OUTPUT", Path.join(dir, "out"))
      done = fn %{issue: 7}, ^env -> {:outcome, :mitigated, true} end

      capture_io(fn ->
        assert CLI.main(["work", "--issue", "7"], env, @root, commands: commands(done)) == 0
      end)

      assert File.read!(Path.join(dir, "out")) == "outcome=mitigated\nhas_patch=true\n"
    end

    test "when the role fails, annotates its class and exits with its code" do
      failed = fn _opts, _env -> {:error, :stream_exhausted} end

      out =
        capture_io(fn ->
          assert CLI.main(["work", "--issue", "7"], @env, @root, commands: commands(failed)) == 3
        end)

      assert out =~ "::error title=RSOLV transient failure::"
    end
  end

  describe "main/4 and the retry hand-off token" do
    @describetag :tmp_dir

    setup %{tmp_dir: dir} do
      env = %{"RUNNER_TEMP" => dir, "RSOLV_HOST_INSTALL_DIR" => Path.join(dir, "rsolv-host")}
      path = RsolvHost.TokenKeeper.handoff_path(env, :work, 7)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "{}")
      %{env: env, root: Path.join([dir, "rsolv-host", ".burrito", "r"]), path: path}
    end

    test "is kept for the retry after a transient failure", %{env: env, root: root, path: path} do
      commands = %{
        "work" => {fn _opts, _env -> {:error, :stream_exhausted} end, [issue: :integer], [:issue]}
      }

      capture_io(fn ->
        assert CLI.main(["work", "--issue", "7"], env, root, commands: commands) == 3
      end)

      assert File.exists?(path)
    end

    test "is deleted after any other ending", %{env: env, root: root, path: path} do
      commands = %{
        "work" => {fn _opts, _env -> {:error, :oidc_unavailable} end, [issue: :integer], [:issue]}
      }

      capture_io(fn ->
        assert CLI.main(["work", "--issue", "7"], env, root, commands: commands) == 2
      end)

      refute File.exists?(path)
    end
  end

  describe "commands/0" do
    test "is exactly the five roles and leaves maintenance to Burrito" do
      assert CLI.commands() == ~w(publish scan selftest version work)
      refute "maintenance" in CLI.commands()
    end
  end
end
