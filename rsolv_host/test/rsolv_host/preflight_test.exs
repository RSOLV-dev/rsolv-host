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
