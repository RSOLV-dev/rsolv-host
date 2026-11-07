defmodule RsolvHost.ReleaseConfigTest do
  use ExUnit.Case, async: true

  @vm_args Path.expand("../../rel/vm.args.eex", __DIR__)

  describe "rel/vm.args.eex" do
    test "turns BEAM crash dumps off, so a crash never writes the run token to disk" do
      lines = @vm_args |> File.read!() |> String.split("\n") |> Enum.map(&String.trim/1)

      assert "-env ERL_CRASH_DUMP_SECONDS 0" in lines
    end
  end

  describe "the release's steps" do
    test "verify the ERTS against erts.lock before anything is assembled or wrapped" do
      steps = Mix.Project.config()[:releases][:rsolv_host][:steps]

      assert [verify, :assemble, wrap] = steps
      assert verify == (&RsolvHost.Release.verify_erts/1)
      assert wrap == (&Burrito.wrap/1)
    end

    test "add the step that keeps Burrito from writing a musl loader to /tmp" do
      burrito = Mix.Project.config()[:releases][:rsolv_host][:burrito]

      assert burrito[:extra_steps][:build][:pre] == [RsolvHost.Release.NoMuslLoader]
    end

    test "are Mix's own or functions that exist, so `mix release` can run" do
      steps = Mix.Project.config()[:releases][:rsolv_host][:steps]

      for step <- steps, is_function(step) do
        info = Function.info(step)
        assert Code.ensure_loaded?(info[:module]), inspect(step)
        assert function_exported?(info[:module], info[:name], info[:arity]), inspect(step)
      end
    end
  end
end
