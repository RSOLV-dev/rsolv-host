defmodule RsolvHost.PreflightTest do
  use ExUnit.Case, async: true

  alias RsolvHost.Preflight

  @temp "/home/runner/work/_temp"
  @install "/home/runner/work/_temp/rsolv-host"
  @root "/home/runner/work/_temp/rsolv-host/.burrito/rsolv_host_erts-17.0.4_0.1.0"
  @env %{"RUNNER_TEMP" => @temp, "RSOLV_HOST_INSTALL_DIR" => @install}

  describe "check/2" do
    test "accepts a release extracted into an install dir under RUNNER_TEMP" do
      assert Preflight.check(@env, @root) == :ok
    end

    for name <- ~w(ERL_AFLAGS ERL_FLAGS ERL_ZFLAGS ERL_OTP29_FLAGS ERL_OTP30_FLAGS ERL_LIBS
                   ERL_COMPILER_OPTIONS EMU) do
      test "when #{name} is set (it can re-enable crash dumps or change the VM's code and config), names it" do
        env = Map.put(@env, unquote(name), "-env ERL_CRASH_DUMP_SECONDS 10")

        assert Preflight.check(env, @root) == {:error, {:vm_env, unquote(name)}}
      end
    end

    test "when an ERL_ variable erlexec doesn't read is set, accepts it" do
      assert Preflight.check(Map.put(@env, "ERL_EPMD_PORT", "4369"), @root) == :ok
    end

    test "when an ERL_* variable is set but empty, accepts it" do
      assert Preflight.check(Map.put(@env, "ERL_FLAGS", ""), @root) == :ok
    end

    test "when RUNNER_TEMP is unset, names it" do
      assert Preflight.check(Map.delete(@env, "RUNNER_TEMP"), @root) ==
               {:error, {:preflight, "RUNNER_TEMP"}}
    end

    test "when RSOLV_HOST_INSTALL_DIR is unset, names it" do
      assert Preflight.check(Map.delete(@env, "RSOLV_HOST_INSTALL_DIR"), @root) ==
               {:error, {:preflight, "RSOLV_HOST_INSTALL_DIR"}}
    end

    test "when the install dir is outside RUNNER_TEMP, names it" do
      env = %{@env | "RSOLV_HOST_INSTALL_DIR" => "/home/runner/.local/share"}

      assert Preflight.check(env, "/home/runner/.local/share/.burrito/x") ==
               {:error, {:preflight, "RSOLV_HOST_INSTALL_DIR"}}
    end

    test "when the release extracted somewhere else, names the install dir" do
      assert Preflight.check(@env, "/home/runner/.local/share/.burrito/rsolv_host") ==
               {:error, {:preflight, "RSOLV_HOST_INSTALL_DIR"}}
    end

    test "when the install dir only shares a string prefix with RUNNER_TEMP, names it" do
      env = %{"RUNNER_TEMP" => "/tmp/run", "RSOLV_HOST_INSTALL_DIR" => "/tmp/runner-evil/x"}

      assert Preflight.check(env, "/tmp/runner-evil/x/.burrito/r") ==
               {:error, {:preflight, "RSOLV_HOST_INSTALL_DIR"}}
    end

    test "when the install dir climbs out of RUNNER_TEMP with .., names it" do
      env = %{@env | "RSOLV_HOST_INSTALL_DIR" => @temp <> "/../../.local"}

      assert Preflight.check(env, "/home/runner/work/.local/.burrito/r") ==
               {:error, {:preflight, "RSOLV_HOST_INSTALL_DIR"}}
    end
  end
end
