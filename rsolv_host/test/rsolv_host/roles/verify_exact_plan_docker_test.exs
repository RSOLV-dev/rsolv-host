defmodule RsolvHost.Roles.VerifyExactPlanDockerTest do
  # The platform's exact pytest plan, end to end on a real Docker (verify
  # base-built plan, H′1). test/fixtures/plans/pytest_demo_v1.json is
  # rsolv-platform's test/fixtures/exported/pytest_demo_v1.json at 66d4fb2a,
  # the v1 plan `Verification.plan/3` serves for its pytest demo fixture; its
  # P1.6 test ("exports the plan it serves the pytest demo …",
  # test/rsolv/runners/verification_test.exs) regenerates it.
  use ExUnit.Case, async: false

  import RsolvHost.VerifyDocker, only: [checkout: 2, report: 2]

  alias RsolvCore.{ChangeSet, VerifyPlan}
  alias RsolvHost.{FakeExec, VerifyDocker}

  @moduletag :docker
  @moduletag timeout: 1_800_000

  setup do: VerifyDocker.unique_tmp_dir()

  @plan Path.expand("../../fixtures/plans/pytest_demo_v1.json", __DIR__)
        |> File.read!()
        |> JSON.decode!()

  # The fixture's files, vendored from rsolv-platform's
  # test/support/verify_fixtures.ex (`Rsolv.VerifyFixtures`, last changed in
  # 29375b4a; main at 66d4fb2a): the base's requirements.txt, .tool-versions
  # and app/render.py, and `post_images/0`, its fix and RED test.
  @render "def render(x):\n    return eval(x)\n"
  @fixed "def render(x):\n    return str(x)\n"
  @red_test "def test_escapes(): from app.render import render; assert render('1+1') == '1+1'\n"
  @base %{
    "requirements.txt" => "pytest==8.3.3\n",
    ".tool-versions" => "python 3.12.7\n",
    "app/render.py" => @render
  }
  @change [{"app/render.py", @render, @fixed}, {"tests/test_xss.py", nil, @red_test}]

  describe "the vendored fixture" do
    test "is the plan's change set: every base and new blob hashes to its entry" do
      for {path, base, new} <- @change do
        entry = Enum.find(@plan["change_set"], &(&1["path"] == path))
        assert entry["base_blob_sha"] == (base && ChangeSet.blob_sha(base)), path
        assert entry["new_blob_sha"] == ChangeSet.blob_sha(new), path
      end

      assert length(@plan["change_set"]) == length(@change)
      assert {:ok, %VerifyPlan{framework: "pytest", test_prepare: []}} = VerifyPlan.decode(@plan)
    end
  end

  # One run, as each side BUILDs a Python: RED fails behaviourally, GREEN
  # passes, and each BUILD runs the plan's pip steps, then its rm.
  test "the plan, run by the role on the demo's base, fails RED and passes GREEN", %{
    tmp_dir: dir
  } do
    context = checkout(dir, @base)
    %{body: body} = run = VerifyDocker.verify(context, @change, @plan)
    assert body["red"] && body["green"], why(run)

    red = report(body, "red")
    assert body["red"]["exit_code"] == 1, red
    refute body["red"]["timed_out"]
    assert red =~ ~r/<testcase [^>]*name="test_escapes"/, red
    assert red =~ ~r/<failure message="AssertionError: assert 2 == '1\+1'/, red

    green = report(body, "green")
    assert body["green"]["exit_code"] == 0, green
    refute body["green"]["timed_out"]
    assert green =~ ~r/<testcase [^>]*name="test_escapes"/, green
    assert green =~ ~s(tests="1"), green
    refute green =~ ~r/<failure|<error/, green

    for side <- ["red", "green"] do
      assert build_steps(side) == @plan["install"] ++ @plan["prepare"], side
      assert %{"install" => [install, _freeze], "prepare" => [""]} = body["build_evidence"][side]
      assert Base.decode64!(install) =~ "pytest==8.3.3", side
    end

    # The same environment on both sides: what P2's judge compares.
    assert [_install, freeze] = body["build_evidence"]["red"]["install"]
    assert freeze == List.last(body["build_evidence"]["green"]["install"])
    assert Base.decode64!(freeze) =~ ~r/^pytest==8\.3\.3$/m
  end

  # The plan steps `side`'s BUILD container exec'd, in order, bootstrap aside.
  defp build_steps(side) do
    for {"docker", ["exec", "-i" | rest], _opts} <- FakeExec.calls(),
        [container, "timeout", "-k", _kill, _seconds | argv] <- [Enum.drop_while(rest, &env?/1)],
        String.ends_with?(container, "-#{side}-build"),
        argv != ["rsolv-sandbox", "bootstrap"],
        do: argv
  end

  # `-e NAME=value` pairs come before the container's name.
  defp env?(arg), do: arg == "-e" or arg =~ ~r/\A[A-Z_][A-Z0-9_]*=/

  defp why(%{result: result, out: out}), do: "result: #{inspect(result)}\n#{out}"
end
