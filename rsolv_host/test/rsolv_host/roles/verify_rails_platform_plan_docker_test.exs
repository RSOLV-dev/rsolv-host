defmodule RsolvHost.Roles.VerifyRailsPlatformPlanDockerTest do
  # Verify base-built plan P2.5: the platform's exact Rails v2 plan for
  # railsgoat #324 (rsolv-platform test/fixtures/exported/railsgoat_324_v2.json,
  # vendored as test/fixtures/plans/), run by the role on railsgoat e2cd64e9
  # with #324's real RED snapshot and fix (staging run a75dd74a, vendored as
  # test/fixtures/railsgoat_324/); then the same plan's steps for a migration
  # transition and a real load failure. With RSOLV_P2_OUT set, each posted
  # body is written there: the platform vendors them as
  # test/fixtures/rsolv_host/verification_railsgoat_*.json.
  use ExUnit.Case, async: false

  import RsolvHost.VerifyDocker, only: [checkout: 3, report: 2]

  alias RsolvHost.VerifyDocker

  @moduletag :docker
  @moduletag timeout: 1_800_000

  @plan Path.expand("../../fixtures/plans/railsgoat_324_v2.json", __DIR__)
  @fixtures Path.expand("../../fixtures/railsgoat_324", __DIR__)
  @railsgoat "https://github.com/arubis/railsgoat-vulnerability-demo"
  @railsgoat_sha "e2cd64e94e3eaeb3ded89c4ea9a64725f4a009ac"
  @red "spec/controllers/users_controller_sql_injection_spec.rb"

  setup do
    tree = VerifyDocker.cached_tree(@railsgoat, @railsgoat_sha)
    Map.put(VerifyDocker.unique_tmp_dir(), :railsgoat, tree)
  end

  defp exact_plan, do: @plan |> File.read!() |> JSON.decode!()

  defp out(name, body) do
    if dir = System.get_env("RSOLV_P2_OUT"),
      do: File.write!(Path.join(dir, name), JSON.encode!(body))
  end

  # The platform's plan's steps for another change set (adds only).
  defp plan_for(change, red_path) do
    exact = exact_plan()

    VerifyDocker.plan(
      change,
      [red_path],
      Map.merge(
        Map.take(
          exact,
          ~w(install prepare test_prepare env report install_timeout_s test_timeout_s)
        ),
        %{"test" => List.replace_at(exact["test"], -1, red_path)}
      )
    )
  end

  defp why(%{result: result, out: out}), do: "result: #{inspect(result)}\n#{out}"

  test "#324: the exact plan fails RED behaviourally and passes GREEN", context do
    context = checkout(context.tmp_dir, %{}, from: context.railsgoat)
    base = File.read!(Path.join(@fixtures, "users_controller.base.rb"))

    change = [
      {"app/controllers/users_controller.rb", base,
       File.read!(Path.join(@fixtures, "users_controller.rb"))},
      {@red, nil, File.read!(Path.join(@fixtures, "users_controller_sql_injection_spec.rb"))}
    ]

    %{body: body} = run = VerifyDocker.verify(context, change, exact_plan())
    assert body["red"] && body["green"], why(run)
    out("verification_railsgoat_324.json", body)

    red = report(body, "red") |> JSON.decode!()
    green = report(body, "green") |> JSON.decode!()
    assert body["red"]["exit_code"] == 1, inspect(red)
    # railsgoat runs specs in random order, db:prepare seeds two users into
    # the fresh DB, and DatabaseCleaner truncates only after each example. So
    # the OR 1=1 case fails RED only when it runs second; run first, its
    # `[0]` is a seeded user. The case that targets the victim by id fails
    # either way.
    assert red["summary"]["failure_count"] in 1..2, inspect(red["summary"])

    assert %{"status" => "failed"} =
             Enum.find(red["examples"], &(&1["description"] =~ "modify another user's data"))

    assert red["summary"]["errors_outside_of_examples_count"] == 0
    assert body["green"]["exit_code"] == 0, inspect(green)
    assert green["summary"]["failure_count"] == 0
    assert green["summary"]["example_count"] == 2
    refute run.out =~ ~r/PendingMigrationError|EnvironmentMismatchError|Could not find table/

    [red_list, green_list] =
      for side <- ~w(red green), do: List.last(body["build_evidence"][side]["install"])

    assert red_list == green_list
    assert Base.decode64!(red_list) =~ "/gems/railties-8.0.4\n"
  end

  test "a migration the fix adds runs in db:prepare, and GREEN passes", context do
    context = checkout(context.tmp_dir, %{}, from: context.railsgoat)

    migration = """
    class AddFlagToUsers < ActiveRecord::Migration[8.0]
      def change
        add_column :users, :flag, :boolean, default: false, null: false
      end
    end
    """

    red = """
    require "spec_helper"

    RSpec.describe User do
      it "keeps a flag on every user" do
        expect(User.column_names).to include("flag")
      end
    end
    """

    change = [
      {"db/migrate/20261119000000_add_flag_to_users.rb", nil, migration},
      {"spec/models/user_flag_spec.rb", nil, red}
    ]

    %{body: body} =
      run =
      VerifyDocker.verify(context, change, plan_for(change, "spec/models/user_flag_spec.rb"))

    assert body["red"] && body["green"], why(run)
    out("verification_railsgoat_migration.json", body)

    assert body["red"]["exit_code"] == 1, report(body, "red")
    assert body["green"]["exit_code"] == 0, report(body, "green")
    refute run.out =~ ~r/PendingMigrationError|EnvironmentMismatchError|Could not find table/
    refute Map.has_key?(body, "files")
  end

  test "a fix whose model raises NameError on load is a load error, not a test failure",
       context do
    context = checkout(context.tmp_dir, %{}, from: context.railsgoat)

    model = """
    class UserFlag
      NoSuchThing::Anywhere

      def ok?
        true
      end
    end
    """

    red = """
    require "spec_helper"

    RSpec.describe UserFlag do
      it { expect(UserFlag.new.ok?).to eq true }
    end
    """

    change = [
      {"app/models/user_flag.rb", nil, model},
      {"spec/models/user_flag_spec.rb", nil, red}
    ]

    %{body: body} =
      run =
      VerifyDocker.verify(context, change, plan_for(change, "spec/models/user_flag_spec.rb"))

    assert body["red"] && body["green"], why(run)
    out("verification_railsgoat_load_error.json", body)

    for side <- ~w(red green) do
      summary = report(body, side) |> JSON.decode!() |> Map.fetch!("summary")
      assert summary["errors_outside_of_examples_count"] == 1, "#{side}: #{inspect(summary)}"
      assert body[side]["exit_code"] != 0
    end
  end
end
