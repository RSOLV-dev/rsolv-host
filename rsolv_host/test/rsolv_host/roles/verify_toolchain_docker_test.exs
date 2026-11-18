defmodule RsolvHost.Roles.VerifyToolchainDockerTest do
  # The verify role on a real Docker with real toolchains (design spec §4.3,
  # §5.4, §8 h, i): bootstrap installs them through the egress proxy in
  # BUILD, and TEST runs them offline. Slower than the boundary tests: each
  # side's BUILD downloads a runtime.
  use ExUnit.Case, async: false

  import RsolvHost.VerifyDocker, except: [verify: 3, verify: 4]

  alias RsolvHost.VerifyDocker

  @moduletag :docker
  @moduletag :tmp_dir
  @moduletag timeout: 1_800_000

  describe "(i) the pytest stale hybrid, three ways (spec §4.3)" do
    # New a.py is a different length (a cache miss); new b.py is the same
    # length as base b.py and gets its mtime back in TEST (a stale hit). The
    # RED test passes only on new a with base b: the hybrid a stale cache
    # gives, never the shipped fix.
    @a0 ~s|from pkg.b import g\n\n\ndef f():\n    return "A0" + g()\n|
    @a1 ~s|from pkg.b import g\n\n\ndef f():\n    return "A1-new" + g()\n|
    @b0 ~s|def g():\n    return "B0"\n|
    @b1 ~s|def g():\n    return "B1"\n|
    @red_test ~s|from pkg.a import f\n\n\ndef test_red():\n    assert f() == "A1-newB0"\n|
    @at 1_700_000_000

    setup %{tmp_dir: dir} do
      files = %{
        "requirements.txt" => "pytest==8.3.3\n",
        "pkg/__init__.py" => "",
        "pkg/a.py" => @a0,
        "pkg/b.py" => @b0,
        "vendor/bin/phpunit" => harness()
      }

      checkout(dir, files,
        executable: ["vendor/bin/phpunit"],
        mtimes: %{"pkg/a.py" => @at, "pkg/b.py" => @at}
      )
    end

    defp pytest_change,
      do: [{"pkg/a.py", @a0, @a1}, {"pkg/b.py", @b0, @b1}, {"tests/test_red.py", nil, @red_test}]

    # GREEN's exit status and whether its RED case failed, after a BUILD
    # whose `prepare` is `prepare`.
    defp green(context, prepare) do
      plan =
        plan(pytest_change(), ["tests/test_red.py"], %{
          "framework" => "pytest",
          "install" => [~w(python -m pip install --no-input pytest==8.3.3)],
          "prepare" => prepare,
          "test_prepare" => [sh("touch -d @#{@at} pkg/b.py")],
          "test" =>
            ~w(python -m pytest -q -p no:cacheprovider -o junit_family=xunit1 --junitxml=/work/rsolv-report tests/test_red.py),
          "report" => %{"format" => "junit_xml", "argv" => ~w(cat -- /work/rsolv-report)}
        })

      %{body: body} = VerifyDocker.verify(context, pytest_change(), plan)
      assert %{"green" => %{"exit_code" => status}} = body, inspect(body)
      report = report(body, "green")
      assert report =~ ~s(tests="1"), report
      {status, report =~ "<failure"}
    end

    test "ground truth: the full fix on a tree with no build cache fails the RED test", context do
      assert {status, true} = green(context, [])
      assert status != 0
    end

    test "hazard: compiled in BUILD with no invalidation, the stale hybrid passes", context do
      assert {0, false} = green(context, [~w(python -m compileall -q pkg)])
    end

    test "fix: compiled in BUILD and then invalidated, it fails, as the ground truth does",
         context do
      assert {status, true} =
               green(context, [~w(python -m compileall -q pkg), ~w(rm -rf -- pkg/__pycache__)])

      assert status != 0
    end
  end

  describe "(h) Ruby's fail-closed install (spec §5.4)" do
    setup %{tmp_dir: dir} do
      lock = """
      GEM
        remote: https://rubygems.org/
        specs:

      PLATFORMS
        ruby

      DEPENDENCIES

      BUNDLED WITH
         2.6.2
      """

      files = %{
        ".ruby-version" => "3.4.1\n",
        "Gemfile" => ~s(source "https://rubygems.org"\n),
        "Gemfile.lock" => lock,
        "vendor/cache/.keep" => "",
        "spec/.keep" => "",
        "vendor/bin/phpunit" => harness()
      }

      checkout(dir, files, executable: ["vendor/bin/phpunit"])
    end

    test "leaves the same Bundler config in both TEST containers, frozen and with no without",
         context do
      change = [{"spec/red_spec.rb", nil, "RSpec.describe(1) { it { expect(1).to eq 2 } }\n"}]

      show =
        "{ sha256sum .bundle/config; cat .bundle/config; " <>
          "sha256sum $HOME/.bundle/config 2>&1 | sed 's#/opt/home#HOME#'; bundle config; } > /work/rsolv-report 2>&1"

      plan =
        plan(change, ["spec/red_spec.rb"], %{
          "install" => [
            ~w(bundle config set --local frozen true),
            ~w(bundle config unset --local without),
            ~w(bundle config unset without),
            ~w(bundle install --local)
          ],
          "test" => sh(show)
        })

      %{body: body} = VerifyDocker.verify(context, change, plan)

      red = report(body, "red")
      assert red == report(body, "green")
      assert red =~ ~s(BUNDLE_FROZEN: "true")
      refute red =~ ~r/without/i
    end
  end

  describe "TEST prepare past its clamped time limit (spec §3.1)" do
    setup %{tmp_dir: dir} do
      checkout(
        dir,
        %{"app/a.rb" => "base\n", "vendor/bin/phpunit" => harness()},
        executable: ["vendor/bin/phpunit"]
      )
    end

    # The role's budget leaves each side seconds, so a step that sleeps is
    # stopped by the clamp, not by its own 5 minutes.
    for {side, sleeper} <- [
          {"red", "sleep 600"},
          {"green", "if grep -q fix app/a.rb; then sleep 600; fi"}
        ] do
      test "is prepare_failed_#{side}, and the test never runs", context do
        change = [{"app/a.rb", "base\n", "fix\n"}, {"spec/red_spec.rb", nil, "red\n"}]

        plan =
          plan(change, ["spec/red_spec.rb"], %{
            "test_prepare" => [sh(unquote(sleeper))],
            "test" => sh("echo ran > /work/rsolv-report")
          })

        started = System.monotonic_time(:millisecond)

        %{body: body} =
          VerifyDocker.verify(context, change, plan,
            deps: [budget_ms: 5 * 60_000 + 50_000],
            answers: %{"verification" => {200, %{verification: "verify_error", reasons: []}}}
          )

        assert body["error"] == "prepare_failed_" <> unquote(side)
        assert System.monotonic_time(:millisecond) - started < 5 * 60_000
        refute ran?("echo ran > /work/rsolv-report", unquote(side))
      end
    end
  end

  # Whether `side`'s TEST exec'd an argv holding `arg`.
  defp ran?(arg, side) do
    Enum.any?(RsolvHost.FakeExec.calls(), fn
      {"docker", ["exec", "-i" | rest], _} ->
        arg in rest and Enum.any?(rest, &String.ends_with?(&1, "-#{side}-test"))

      _other ->
        false
    end)
  end

  describe "(p) Rails preparation in TEST, on railsgoat (spec §5.4)" do
    @railsgoat "https://github.com/arubis/railsgoat-vulnerability-demo"
    @railsgoat_sha "e2cd64e94e3eaeb3ded89c4ea9a64725f4a009ac"
    @db_files ~w(db/test.sqlite3 db/test.sqlite3-journal db/test.sqlite3-wal db/test.sqlite3-shm)
    @rspec_report "/tmp/rsolv-report.json"
    @red_spec ~s|require "spec_helper"\n\nRSpec.describe "RED" do\n  it { expect(1).to eq 2 }\nend\n|

    # Fetched once per machine, at the pinned commit.
    setup do
      tree = Path.join(System.tmp_dir!(), "rsolv-railsgoat-#{@railsgoat_sha}")

      unless File.dir?(Path.join(tree, ".git")) do
        File.mkdir_p!(tree)
        VerifyDocker.git(tree, ["init", "-q"])
        VerifyDocker.git(tree, ["fetch", "-q", "--depth", "1", @railsgoat, @railsgoat_sha])
        VerifyDocker.git(tree, ["checkout", "-q", "FETCH_HEAD"])
      end

      %{railsgoat: tree}
    end

    # railsgoat at #324's base, with a committed test DB holding a marker row
    # (its .gitignore emptied so it's committed), and `extra` files.
    defp railsgoat(context, extra \\ %{}) do
      db = Path.join(context.tmp_dir, "marker.sqlite3")
      marker = "MARKER-ROW-#{System.unique_integer([:positive])}"

      {_out, 0} =
        System.cmd("python3", [
          "-c",
          "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('create table markers(v text)'); c.execute('insert into markers values (?)', (sys.argv[2],)); c.commit()",
          db,
          marker
        ])

      files =
        Map.merge(
          %{
            ".gitignore" => "",
            "db/test.sqlite3" => File.read!(db),
            "vendor/bin/phpunit" => harness()
          },
          extra
        )

      context.tmp_dir
      |> checkout(files, from: context.railsgoat, executable: ["vendor/bin/phpunit"])
      |> Map.put(:marker, marker)
    end

    # The v2 plan spec §5.4 has the platform build for a Rails app.
    defp rails_plan(change, red_paths, overrides) do
      plan(
        change,
        red_paths,
        Map.merge(
          %{
            "install" => [
              ~w(bundle config set --local frozen true),
              ~w(bundle config unset --local without),
              ~w(bundle config unset without),
              ~w(bundle install)
            ],
            "env" => %{"RAILS_ENV" => "test"},
            "test_prepare" => [
              ["rm", "-rf", "--", "tmp/cache/bootsnap", "tmp/cache/bootsnap-compile-cache"] ++
                ["tmp/cache/bootsnap-load-path-cache", "db/schema_cache.yml" | @db_files],
              ~w(bundle exec rake db:prepare),
              ["rm", "-f", "--", @rspec_report]
            ],
            "test" =>
              ~w(bundle exec rspec --format json --out) ++ [@rspec_report, "spec/red_spec.rb"],
            "report" => %{"format" => "rspec_json", "argv" => ["cat", "--", @rspec_report]}
          },
          overrides
        )
      )
    end

    defp rails_verify(context, change, overrides, opts) do
      red_paths = Keyword.get(opts, :red_paths, ["spec/red_spec.rb"])
      plan = rails_plan(change, red_paths, overrides)
      VerifyDocker.verify(context, change, plan, Keyword.delete(opts, :red_paths))
    end

    @verify_error %{"verification" => {200, %{verification: "verify_error", reasons: []}}}

    defp rspec_ran?(side), do: ran?("rspec", side)

    test "writes the DB, its WAL and SHM, tmp/ and log/ under /work only, gives each side a fresh DB, sets RAILS_ENV and no master key, and never reads a report prepare wrote",
         context do
      context = railsgoat(context)

      # GREEN's fix: an initializer that, under rake, writes a fake passing
      # report, and under RSpec, raises while it loads. (RSpec is defined
      # under rake too: rspec-rails is in railsgoat's test group.)
      forger = """
      if File.basename($PROGRAM_NAME) == "rspec"
        raise "the fix breaks RSpec's load"
      else
        File.write("#{@rspec_report}", '{"summary":{"example_count":1,"failure_count":0},"examples":[{"status":"passed"}]}')
      end
      """

      change = [
        {"config/initializers/zz_forger.rb", nil, forger},
        {"spec/red_spec.rb", nil, @red_spec}
      ]

      checks =
        Enum.join(
          [
            "echo db=$(ls db/test.sqlite3 2>&1)",
            "echo marker=$(grep -c -a #{context.marker} db/test.sqlite3)",
            "echo open=$(bundle exec rails runner 'ActiveRecord::Base.connection.execute(%q(select 1)); puts Dir[%q(db/test.sqlite3*)].sort.join(%q(,))' 2>/dev/null)",
            "echo tmp=$(mkdir -p tmp/cache && touch tmp/cache/x && echo ok)",
            "echo log=$(test -s log/test.log && echo ok)",
            "echo root=$(touch /x 2>&1)",
            "echo rails_env=$RAILS_ENV",
            "echo master_key=$(env | grep -c RAILS_MASTER_KEY)"
          ],
          "; "
        )

      %{body: body} =
        rails_verify(
          context,
          change,
          %{
            "test" =>
              sh(
                "{ #{checks}; } > /work/checks 2>&1; exec bundle exec rspec --format json --out #{@rspec_report} spec/red_spec.rb"
              ),
            "report" => %{
              "format" => "rspec_json",
              "argv" => ["cat", "--", "/work/checks", @rspec_report]
            }
          },
          answers: @verify_error
        )

      assert body["red"] && body["green"], inspect(body["error"])

      for side <- ["red", "green"] do
        report = report(body, side)
        assert report =~ "db=db/test.sqlite3\n", "#{side}: #{report}"
        assert report =~ "marker=0\n", "#{side}: #{report}"

        assert report =~ "db/test.sqlite3,db/test.sqlite3-shm,db/test.sqlite3-wal",
               "#{side}: #{report}"

        assert report =~ "tmp=ok\n" and report =~ "log=ok\n", "#{side}: #{report}"
        assert report =~ "Read-only file system", "#{side}: #{report}"
        assert report =~ "rails_env=test\n" and report =~ "master_key=0\n", "#{side}: #{report}"
      end

      # RSpec's own report: GREEN's names the load error, never the fake pass.
      green = report(body, "green")
      refute green =~ ~s("examples":[{"status":"passed"}])
      assert green =~ ~s("errors_outside_of_examples_count":1)
    end

    test "an initializer in the RED snapshot that raises is prepare_failed_red, and RSpec never runs",
         context do
      context = railsgoat(context)

      change = [
        {"config/initializers/zz_red.rb", nil, "raise \"RED fixture\"\n"},
        {"spec/red_spec.rb", nil, @red_spec}
      ]

      # The initializer is part of the RED snapshot, so RED's TEST has it.
      %{body: body} =
        rails_verify(context, change, %{},
          answers: @verify_error,
          red_paths: ["config/initializers/zz_red.rb", "spec/red_spec.rb"]
        )

      assert body["error"] == "prepare_failed_red"
      refute rspec_ran?("red")
    end

    test "an initializer in the fix that raises is prepare_failed_green, and GREEN's RSpec never runs",
         context do
      context = railsgoat(context)

      change = [
        {"config/initializers/zz_fix.rb", nil, "raise \"the fix breaks boot\"\n"},
        {"spec/red_spec.rb", nil, @red_spec}
      ]

      %{body: body} = rails_verify(context, change, %{}, answers: @verify_error)

      assert body["error"] == "prepare_failed_green"
      assert rspec_ran?("red")
      refute rspec_ran?("green")
    end

    test "require_master_key with encrypted credentials and no key is prepare_failed_red",
         context do
      test_rb = File.read!(Path.join(context.railsgoat, "config/environments/test.rb"))

      context =
        railsgoat(context, %{
          "config/environments/test.rb" =>
            String.replace(
              test_rb,
              "config.eager_load = false",
              "config.eager_load = false\n  config.require_master_key = true"
            ),
          "config/credentials.yml.enc" =>
            Base.encode64(:crypto.strong_rand_bytes(48)) <>
              "--" <>
              Base.encode64(:crypto.strong_rand_bytes(12)) <>
              "--" <> Base.encode64(:crypto.strong_rand_bytes(16))
        })

      change = [{"spec/red_spec.rb", nil, @red_spec}]

      %{body: body} = rails_verify(context, change, %{}, answers: @verify_error)

      assert body["error"] == "prepare_failed_red"
      refute rspec_ran?("red")
    end
  end
end
