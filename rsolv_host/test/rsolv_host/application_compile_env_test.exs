defmodule RsolvHost.ApplicationCompileEnvTest do
  # Not async: it changes the :rsolv_host application environment.
  use ExUnit.Case, async: false

  describe "cli?/0" do
    test "is fixed when the host is compiled, so a VM flag (-rsolv_host run_cli false) can't skip the command line" do
      compiled = RsolvHost.Application.cli?()
      Application.put_env(:rsolv_host, :run_cli, not compiled)
      on_exit(fn -> Application.put_env(:rsolv_host, :run_cli, compiled) end)

      assert RsolvHost.Application.cli?() == compiled
    end
  end
end
