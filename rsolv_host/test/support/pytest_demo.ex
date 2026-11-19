defmodule RsolvHost.PytestDemo do
  @moduledoc """
  The platform's pytest demo, for the H′1 tests (verify base-built plan).

  `plan/0` is test/fixtures/plans/pytest_demo_v1.json, rsolv-platform's
  test/fixtures/exported/pytest_demo_v1.json at 66d4fb2a, the v1 plan
  `Verification.plan/3` serves for the demo; its P1.6 test ("exports the plan
  it serves the pytest demo …", test/rsolv/runners/verification_test.exs)
  regenerates it.

  The files are vendored from rsolv-platform's test/support/verify_fixtures.ex
  (`Rsolv.VerifyFixtures`, last changed in 29375b4a; main at 66d4fb2a): the
  base's requirements.txt, .tool-versions and app/render.py, and
  `post_images/0`, its fix and RED test.
  """

  @plan Path.expand("../fixtures/plans/pytest_demo_v1.json", __DIR__)
        |> File.read!()
        |> JSON.decode!()

  @render "def render(x):\n    return eval(x)\n"
  @fixed "def render(x):\n    return str(x)\n"
  @red_test "def test_escapes(): from app.render import render; assert render('1+1') == '1+1'\n"

  @doc "The platform's exported plan, decoded from JSON."
  @spec plan() :: map()
  def plan, do: @plan

  @doc "The demo's base tree: path => bytes."
  @spec base() :: %{String.t() => binary()}
  def base,
    do: %{
      "requirements.txt" => "pytest==8.3.3\n",
      ".tool-versions" => "python 3.12.7\n",
      "app/render.py" => @render
    }

  @doc "The fix and the RED test, as `RsolvHost.VerifyDocker` takes a change."
  @spec change() :: [{String.t(), binary() | nil, binary()}]
  def change, do: [{"app/render.py", @render, @fixed}, {"tests/test_xss.py", nil, @red_test}]
end
