defmodule RsolvHost.Roles.VerifyRailsBootsnapDockerTest do
  # Verify base-built plan P2.5 on a stock Rails 8 app with bootsnap
  # (test/fixtures/rails_new_8_bootsnap: `rails new` 8.0.2 output, slimmed
  # with --skip-* flags, rspec-rails added, Gemfile.lock from `bundle lock`,
  # spec/spec_helper.rb added; the master key and credentials removed;
  # .ruby-version "3.4.1", not rails new's "ruby-3.4.1", which the sandbox
  # bootstrap passes to mise as `ruby@ruby-3.4.1` and fails on). The
  # TEST steps are the platform's Rails plan's (railsgoat_324_v2.json) with
  # this app's storage/test.sqlite3.
  use ExUnit.Case, async: false

  import RsolvHost.VerifyDocker, only: [checkout: 3, harness: 0, report: 2, sh: 1, git: 2]

  alias RsolvHost.VerifyDocker

  @moduletag :docker
  @moduletag timeout: 1_800_000

  @app Path.expand("../../fixtures/rails_new_8_bootsnap", __DIR__)
  @platform_plan Path.expand(
                   "../../fixtures/plans/railsgoat_324_v2.json",
                   __DIR__
                 )

  setup do: VerifyDocker.unique_tmp_dir()

  # The platform's four Rails test_prepare steps, its sqlite sweep over this
  # app's db/ and storage/ (both trees here; railsgoat has only db/).
  defp rails_prepare do
    [caches, ["find", "db" | sweep], db_prepare, rm_report] = platform_plan()["test_prepare"]
    [caches, ["find", "db", "storage" | sweep], db_prepare, rm_report]
  end

  defp platform_plan, do: @platform_plan |> File.read!() |> JSON.decode!()

  defp plan(change, red, overrides) do
    exact = platform_plan()

    VerifyDocker.plan(
      change,
      [red],
      Map.merge(
        %{
          "install" => exact["install"],
          "env" => exact["env"],
          "test" => List.replace_at(exact["test"], -1, red),
          "report" => exact["report"]
        },
        overrides
      )
    )
  end

  defp why(%{result: result, out: out}), do: "result: #{inspect(result)}\n#{out}"

  describe "the bootsnap stale hybrid, three ways (spec §4.3)" do
    # New a.rb is a different length (a cache miss); new b.rb is the same
    # length as base b.rb and gets its mtime back in TEST (a stale hit). The
    # RED test passes only on new A with base B: the hybrid a stale bootsnap
    # compile cache gives, never the shipped fix.
    @a0 ~s|class A\n  def self.f = "A0" + B.g\nend\n|
    @a1 ~s|class A\n  def self.f = "A1-new" + B.g\nend\n|
    @b0 ~s|class B\n  def self.g = "B0"\nend\n|
    @b1 ~s|class B\n  def self.g = "B1"\nend\n|
    @red ~s|require "spec_helper"\n\nRSpec.describe A do\n  it { expect(A.f).to eq "A1-newB0" }\nend\n|
    @at 1_700_000_000

    setup %{tmp_dir: dir} do
      files = %{
        "app/models/a.rb" => @a0,
        "app/models/b.rb" => @b0,
        "vendor/bin/phpunit" => harness()
      }

      checkout(dir, files,
        from: @app,
        executable: ["vendor/bin/phpunit"],
        mtimes: %{"app/models/a.rb" => @at, "app/models/b.rb" => @at}
      )
    end

    defp change,
      do: [
        {"app/models/a.rb", @a0, @a1},
        {"app/models/b.rb", @b0, @b1},
        {"spec/models/red_spec.rb", nil, @red}
      ]

    # GREEN's exit status and RSpec's failure count, after a BUILD whose
    # `prepare` is `prepare` and a TEST whose `test_prepare` restores b.rb's
    # base mtime, then runs `steps`.
    defp green(context, prepare, steps) do
      plan =
        plan(change(), "spec/models/red_spec.rb", %{
          "prepare" => prepare,
          "test_prepare" => [sh("touch -d @#{@at} app/models/b.rb") | steps]
        })

      %{body: body} = run = VerifyDocker.verify(context, change(), plan)
      assert %{"green" => %{"exit_code" => status}} = body, why(run)
      summary = body |> report("green") |> JSON.decode!() |> Map.fetch!("summary")
      assert summary["example_count"] == 1, inspect(summary)
      assert summary["errors_outside_of_examples_count"] == 0, inspect(summary)
      {status, summary["failure_count"]}
    end

    # The base's bootsnap compile cache, as a committed one would be: base A
    # and B compiled in BUILD (on the base alone) at their base mtimes.
    @warm [sh("bundle exec rails runner 'A.f' && ls tmp/cache/bootsnap/compile-cache-iseq")]

    test "ground truth: the full fix on a tree with no bootsnap cache fails the RED test",
         context do
      assert {status, 1} = green(context, [], rails_prepare())
      assert status != 0
    end

    test "hazard: a base bootsnap cache and no invalidation, the stale hybrid passes", context do
      [_rm | rest] = rails_prepare()
      assert {0, 0} = green(context, @warm, rest)
    end

    test "fix: the plan's test_prepare removes the cache, and it fails as the ground truth does",
         context do
      assert {status, 1} = green(context, @warm, rails_prepare())
      assert status != 0
    end
  end

  # Spec §18 (review of rsolv-platform #366): whatever config/database.yml
  # names, TEST's sweep deletes every committed sqlite file in db/ and
  # storage/, so a database only ERB names is prepared fresh too.
  describe "the sweep, for a database only ERB names (spec §18)" do
    @erb_yml """
    default: &default
      adapter: sqlite3
      pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
      timeout: 5000

    test:
      <<: *default
      database: <%= ENV.fetch("TEST_DB") { "storage/x.sqlite3" } %>
    """

    test "deletes committed storage/x.sqlite3 and db/development.sqlite3; db:prepare makes x fresh",
         %{tmp_dir: dir} do
      marked = Path.join(dir, "marked.sqlite3")

      {_out, 0} =
        System.cmd("python3", [
          "-c",
          "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('create table m(v text)'); c.execute(\"insert into m values ('SWEEP-MARKER')\"); c.commit()",
          marked
        ])

      context =
        checkout(
          dir,
          %{
            "config/database.yml" => @erb_yml,
            "storage/x.sqlite3" => File.read!(marked),
            "db/development.sqlite3" => File.read!(marked),
            "vendor/bin/phpunit" => harness()
          },
          from: @app,
          executable: ["vendor/bin/phpunit"]
        )

      red = ~s|require "spec_helper"\n\nRSpec.describe "x" do\n  it { expect(1).to eq 1 }\nend\n|
      change = [{"spec/x_spec.rb", nil, red}]

      checks =
        Enum.join(
          [
            "echo x=$(test -f storage/x.sqlite3 && echo yes || echo no)",
            "echo marker=$(grep -c -a SWEEP-MARKER storage/x.sqlite3)",
            "echo dev=$(test -e db/development.sqlite3 && echo yes || echo no)"
          ],
          "; "
        )

      plan =
        plan(change, "spec/x_spec.rb", %{
          "test_prepare" => rails_prepare(),
          "test" => sh("{ #{checks}; } > /work/rsolv-report 2>&1"),
          "report" => %{"format" => "rspec_json", "argv" => ~w(cat -- /work/rsolv-report)}
        })

      %{body: body} = run = VerifyDocker.verify(context, change, plan)
      assert body["red"] && body["green"], why(run)

      for side <- ~w(red green) do
        out = report(body, side)
        assert out =~ "x=yes\n", "#{side}: #{out}"
        assert out =~ "marker=0\n", "#{side}: #{out}"
        assert out =~ "dev=no\n", "#{side}: #{out}"
      end
    end
  end

  describe "a committed DB symlink, a multi-database test section (spec §5.4)" do
    @multi """
    default: &default
      adapter: sqlite3
      pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
      timeout: 5000

    test:
      primary:
        <<: *default
        database: storage/test.sqlite3
      cache:
        <<: *default
        database: storage/test_cache.sqlite3
        migrations_paths: db/cache_migrate
    """

    # storage/test.sqlite3 is committed as a symlink to /tmp/outside.sqlite3,
    # outside /work; a step before the plan's writes a marker there.
    test "the plan's rm deletes the symlink without following it, and db:prepare makes both DBs",
         %{tmp_dir: dir} do
      context =
        checkout(dir, %{"config/database.yml" => @multi, "vendor/bin/phpunit" => harness()},
          from: @app,
          executable: ["vendor/bin/phpunit"]
        )

      File.ln_s!("/tmp/outside.sqlite3", Path.join(context.checkout, "storage/test.sqlite3"))
      git(context.checkout, ["add", "-A"])
      git(context.checkout, ["commit", "-q", "--amend", "--no-edit"])
      context = %{context | base: git(context.checkout, ["rev-parse", "HEAD"])}

      red = ~s|require "spec_helper"\n\nRSpec.describe "x" do\n  it { expect(1).to eq 1 }\nend\n|
      change = [{"spec/x_spec.rb", nil, red}]

      checks =
        Enum.join(
          [
            "echo link=$(test -L storage/test.sqlite3 && echo yes || echo no)",
            "echo file=$(test -f storage/test.sqlite3 && echo yes || echo no)",
            "echo cache=$(test -f storage/test_cache.sqlite3 && echo yes || echo no)",
            "echo outside=$(cat /tmp/outside.sqlite3)"
          ],
          "; "
        )

      plan =
        plan(change, "spec/x_spec.rb", %{
          "test_prepare" => [
            sh("echo OUTSIDE-MARKER > /tmp/outside.sqlite3") | rails_prepare()
          ],
          "test" => sh("{ #{checks}; } > /work/rsolv-report 2>&1"),
          "report" => %{"format" => "rspec_json", "argv" => ~w(cat -- /work/rsolv-report)}
        })

      %{body: body} = run = VerifyDocker.verify(context, change, plan)
      assert body["red"] && body["green"], why(run)

      for side <- ~w(red green) do
        out = report(body, side)
        assert out =~ "link=no\n", "#{side}: #{out}"
        assert out =~ "file=yes\n", "#{side}: #{out}"
        assert out =~ "cache=yes\n", "#{side}: #{out}"
        assert out =~ "outside=OUTSIDE-MARKER\n", "#{side}: #{out}"
      end
    end
  end
end
