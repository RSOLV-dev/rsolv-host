defmodule RsolvHost.Roles.VerifyExactPlanFixtureTest do
  # The vendored pytest demo is the platform's plan (verify base-built plan,
  # H′1), checked without Docker so default CI runs it.
  use ExUnit.Case, async: true

  alias RsolvCore.{ChangeSet, VerifyPlan}
  alias RsolvHost.PytestDemo

  describe "the vendored pytest demo" do
    test "is the plan's change set: every base and new blob hashes to its entry" do
      plan = PytestDemo.plan()

      for {path, base, new} <- PytestDemo.change() do
        entry = Enum.find(plan["change_set"], &(&1["path"] == path))
        assert entry["base_blob_sha"] == (base && ChangeSet.blob_sha(base)), path
        assert entry["new_blob_sha"] == ChangeSet.blob_sha(new), path
      end

      assert length(plan["change_set"]) == length(PytestDemo.change())
      assert {:ok, %VerifyPlan{framework: "pytest", test_prepare: []}} = VerifyPlan.decode(plan)
    end

    # requirements.txt isn't in the change set, so no SHA pins it; the plan's
    # install step carries the pin the platform read from it.
    test "has the requirements.txt the plan's pip install pin was read from" do
      assert [["python", "-m", "pip", "install", "--no-input", pin] | _freeze] =
               PytestDemo.plan()["install"]

      assert PytestDemo.base()["requirements.txt"] == pin <> "\n"
    end

    # .tool-versions has no check: neither the plan nor any platform export
    # carries it (the platform's base facts for the demo aren't exported). It
    # is copied verbatim from `Rsolv.VerifyFixtures`' @tool_versions.
  end
end
