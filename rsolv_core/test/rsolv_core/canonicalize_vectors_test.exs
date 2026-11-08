defmodule RsolvCore.CanonicalizeVectorsTest do
  use ExUnit.Case, async: true

  @committed Path.expand("../vectors/patch.json", __DIR__)
  @generator Path.expand("../vectors/gen_patch_vectors.exs", __DIR__)

  @moduletag :tmp_dir

  describe "test/vectors/patch.json" do
    test "is exactly what the generator writes from real git", %{tmp_dir: tmp_dir} do
      out = Path.join(tmp_dir, "patch.json")
      # A caller's git environment, which the generator must not let reach git.
      hostile = [
        {"GIT_CONFIG_COUNT", "1"},
        {"GIT_CONFIG_KEY_0", "diff.noprefix"},
        {"GIT_CONFIG_VALUE_0", "true"}
      ]

      assert {_output, 0} =
               System.cmd("elixir", [@generator, out], env: hostile, stderr_to_stdout: true)

      assert out |> File.read!() |> JSON.decode!() == @committed |> File.read!() |> JSON.decode!()
    end
  end
end
