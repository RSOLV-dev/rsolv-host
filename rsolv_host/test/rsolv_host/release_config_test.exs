defmodule RsolvHost.ReleaseConfigTest do
  use ExUnit.Case, async: true

  @vm_args Path.expand("../../rel/vm.args.eex", __DIR__)

  describe "rel/vm.args.eex" do
    test "turns BEAM crash dumps off, so a crash never writes the run token to disk" do
      lines = @vm_args |> File.read!() |> String.split("\n") |> Enum.map(&String.trim/1)

      assert "-env ERL_CRASH_DUMP_SECONDS 0" in lines
    end
  end
end
