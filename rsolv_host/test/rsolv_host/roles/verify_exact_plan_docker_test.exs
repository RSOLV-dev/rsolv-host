defmodule RsolvHost.Roles.VerifyExactPlanDockerTest do
  # The platform's exact pytest plan, end to end on a real Docker (verify
  # base-built plan, H′1). The plan and the demo's files: `RsolvHost.PytestDemo`.
  use ExUnit.Case, async: false

  import RsolvHost.VerifyDocker, only: [checkout: 2, report: 2]

  alias RsolvHost.{FakeExec, PytestDemo, VerifyDocker}

  @moduletag :docker
  @moduletag timeout: 1_800_000

  setup do: VerifyDocker.unique_tmp_dir()

  # One run, as each side BUILDs a Python: RED fails behaviourally, GREEN
  # passes, and each BUILD runs the plan's pip steps, then its rm.
  test "the plan, run by the role on the demo's base, fails RED and passes GREEN", %{
    tmp_dir: dir
  } do
    plan = PytestDemo.plan()
    context = checkout(dir, PytestDemo.base())
    %{body: body} = run = VerifyDocker.verify(context, PytestDemo.change(), plan)
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
      assert build_steps(side) == plan["install"] ++ plan["prepare"], side
      assert %{"install" => [install, _freeze], "prepare" => [""]} = body["build_evidence"][side]
      assert Base.decode64!(install) =~ "pytest==8.3.3", side
    end

    # The same environment on both sides: what P2's judge compares.
    assert [_install, freeze] = body["build_evidence"]["red"]["install"]
    assert freeze == List.last(body["build_evidence"]["green"]["install"])
    assert Base.decode64!(freeze) =~ ~r/^pytest==8\.3\.3$/m
  end

  # Every argv `side`'s BUILD container exec'd, in order, bootstrap aside, so
  # a step the plan doesn't list shows up.
  defp build_steps(side) do
    for {"docker", ["exec" | rest], _opts} <- FakeExec.calls(),
        {_before, [_container | argv]} <-
          [Enum.split_while(rest, &(not String.ends_with?(&1, "-#{side}-build")))],
        argv = untimed(argv),
        argv != ["rsolv-sandbox", "bootstrap"],
        do: argv
  end

  defp untimed(["timeout", "-k", _kill, _seconds | argv]), do: argv
  defp untimed(argv), do: argv

  defp why(%{result: result, out: out}), do: "result: #{inspect(result)}\n#{out}"
end
