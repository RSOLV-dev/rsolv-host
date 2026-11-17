defmodule RsolvCore.VerifyPlanTest do
  use ExUnit.Case, async: true

  alias RsolvCore.{ChangeSet, VerifyPlan}

  @sha String.duplicate("a", 40)

  defp entries do
    [
      %{
        "path" => "src/app.js",
        "op" => "modify",
        "base_mode" => "100644",
        "base_blob_sha" => @sha,
        "mode" => "100644",
        "new_blob_sha" => String.duplicate("c", 40)
      },
      %{
        "path" => "test/app.test.js",
        "op" => "add",
        "base_mode" => nil,
        "base_blob_sha" => nil,
        "mode" => "100644",
        "new_blob_sha" => @sha
      }
    ]
  end

  defp digest(json), do: json |> ChangeSet.from_json() |> elem(1) |> ChangeSet.digest()

  defp plan(overrides \\ %{}) do
    Map.merge(
      %{
        "v" => 1,
        "framework" => "jest",
        "install" => [],
        "prepare" => [],
        "test" => [
          "npx",
          "--no-install",
          "jest",
          "--ci",
          "--json",
          "--outputFile=/tmp/rsolv-report/report.json",
          "--runTestsByPath",
          "test/app.test.js"
        ],
        "report" => %{
          "format" => "jest_json",
          "argv" => ["cat", "--", "/tmp/rsolv-report/report.json"]
        },
        "install_timeout_s" => 1_800,
        "test_timeout_s" => 900,
        "change_set" => entries(),
        "change_set_digest" => digest(entries()),
        "red_paths" => ["test/app.test.js"],
        "red_digest" => digest([Enum.at(entries(), 1)]),
        "policy_version" => "2026-11-v1"
      },
      overrides
    )
  end

  describe "decode/1" do
    test "accepts a plan whose digests match its change set" do
      assert {:ok, %VerifyPlan{framework: "jest", red_paths: ["test/app.test.js"]}} =
               VerifyPlan.decode(plan())
    end

    test "accepts the junit report's find -exec cat" do
      find = ~w(find target/surefire-reports -maxdepth 1 -name TEST-*.xml -exec cat -- {} +)
      report = %{"format" => "junit_xml", "argv" => find}

      assert {:ok, %VerifyPlan{report: %{argv: ^find}}} =
               VerifyPlan.decode(plan(%{"report" => report}))
    end

    # The platform's per-framework templates (RFC-150 steps 4-5 plan, Task 16).
    @templates %{
      "jest" =>
        {[], [],
         ~w(npx --no-install jest --ci --json --outputFile=/tmp/rsolv-report.json --runTestsByPath test/app.test.js),
         "jest_json", ~w(cat -- /tmp/rsolv-report.json)},
      "pytest" =>
        {[], [],
         ~w(python -m pytest -q -p no:cacheprovider -o junit_family=xunit1 --junitxml=/tmp/rsolv-report.xml tests/test_xss.py),
         "junit_xml", ~w(cat -- /tmp/rsolv-report.xml)},
      "rspec" =>
        {[], [],
         ~w(bundle exec rspec --format json --out /tmp/rsolv-report.json spec/xss_spec.rb),
         "rspec_json", ~w(cat -- /tmp/rsolv-report.json)},
      "ex_unit" => {[], [], ~w(mix test --trace test/xss_test.exs), "exunit_trace", nil},
      "junit" =>
        {[~w(mvn -B -q test -Dmaven.test.failure.ignore=true)],
         [~w(rm -rf -- target/surefire-reports)],
         ~w(mvn -B -o -q test -Dsurefire.failIfNoSpecifiedTests=false -Dtest=com.acme.XssTest),
         "junit_xml",
         ~w(find target/surefire-reports -maxdepth 1 -name TEST-*.xml -exec cat -- {} +)},
      "phpunit" =>
        {[], [], ~w(vendor/bin/phpunit --log-junit /tmp/rsolv-report.xml tests/XssTest.php),
         "junit_xml", ~w(cat -- /tmp/rsolv-report.xml)}
    }

    for {framework, {install, prepare, test, format, report_argv}} <- @templates do
      test "accepts the platform's #{framework} template" do
        overrides = %{
          "framework" => unquote(framework),
          "install" => unquote(install),
          "prepare" => unquote(prepare),
          "test" => unquote(test),
          "report" => %{"format" => unquote(format), "argv" => unquote(report_argv)}
        }

        assert {:ok, %VerifyPlan{framework: unquote(framework), test: unquote(test)}} =
                 VerifyPlan.decode(plan(overrides))
      end
    end

    test "keeps long flags and single-dash flags that aren't -c" do
      argv = ["python", "-m", "pytest", "-q", "-p", "no:cacheprovider", "--collect-only"]
      assert {:ok, %VerifyPlan{test: ^argv}} = VerifyPlan.decode(plan(%{"test" => argv}))
    end
  end

  describe "decode/1 when the plan is refused" do
    test "refuses a shell" do
      assert VerifyPlan.decode(plan(%{"test" => ["sh", "-c", "npx jest"]})) ==
               {:error, :invalid_plan}
    end

    test "refuses a shell given by its path" do
      find = ["find", ".", "-name", "*.xml", "-exec", "/bin/sh", "{}", ";"]
      assert VerifyPlan.decode(plan(%{"install" => [find]})) == {:error, :invalid_plan}
    end

    test "refuses -c anywhere in an argv" do
      assert VerifyPlan.decode(plan(%{"install" => [["python", "-c", "print(1)"]]})) ==
               {:error, :invalid_plan}
    end

    test "refuses find -exec of anything but cat" do
      for exec <- ~w(-exec -execdir -ok -okdir) do
        find = ["find", ".", exec, "curl", "x", ";"]
        assert VerifyPlan.decode(plan(%{"install" => [find]})) == {:error, :invalid_plan}
      end
    end

    test "refuses find -exec of a shell outside the refused names" do
      find = ["find", ".", "-exec", "/bin/dash", "p.sh", ";"]
      assert VerifyPlan.decode(plan(%{"install" => [find]})) == {:error, :invalid_plan}
    end

    test "refuses -c attached to its argument" do
      argv = ["python", "-c__import__('os').system('id')"]
      assert VerifyPlan.decode(plan(%{"install" => [argv]})) == {:error, :invalid_plan}
    end

    test "refuses python's -c inside a cluster of short options" do
      argv = ["python", "-Bc", "import os"]
      assert VerifyPlan.decode(plan(%{"install" => [argv]})) == {:error, :invalid_plan}
    end

    test "refuses -c inside any executable's cluster of short options" do
      for argv <- [["npx", "-yc", "echo X"], ["npx", "-Dc", "echo X"]] do
        assert VerifyPlan.decode(plan(%{"test" => argv})) == {:error, :invalid_plan}
      end
    end

    test "refuses npx --call" do
      for call <- [["npx", "--call", "id"], ["npx", "--call=id"]] do
        assert VerifyPlan.decode(plan(%{"test" => call})) == {:error, :invalid_plan}
      end
    end

    test "refuses every shell and env by name or path" do
      for shell <- ~w(sh bash dash zsh ksh ash fish busybox env /usr/bin/env /bin/zsh) do
        find = ["find", ".", "-exec", "cat", shell, ";"]
        assert VerifyPlan.decode(plan(%{"install" => [find]})) == {:error, :invalid_plan}
      end
    end

    test "refuses an executable outside the allowlist" do
      assert VerifyPlan.decode(plan(%{"install" => [["curl", "https://x"]]})) ==
               {:error, :invalid_plan}
    end

    test "refuses a control character in an argument" do
      assert VerifyPlan.decode(plan(%{"test" => ["npx", "jest\n--watch"]})) ==
               {:error, :invalid_plan}
    end

    test "refuses a change-set digest that doesn't match" do
      assert VerifyPlan.decode(
               plan(%{"change_set_digest" => "sha256:" <> String.duplicate("0", 64)})
             ) == {:error, :invalid_plan}
    end

    test "refuses a RED path that isn't an add" do
      assert VerifyPlan.decode(plan(%{"red_paths" => ["src/app.js"]})) == {:error, :invalid_plan}
    end

    test "refuses an unknown member" do
      assert VerifyPlan.decode(Map.put(plan(), "env", %{})) == {:error, :invalid_plan}
    end
  end

  defp v2(overrides \\ %{}) do
    plan(Map.merge(%{"v" => 2, "test_prepare" => [], "env" => %{}}, overrides))
  end

  describe "decode/1, plan v2 (a base-built host)" do
    test "accepts v1's members plus test_prepare and env" do
      assert {:ok, decoded} = VerifyPlan.decode(v2())
      assert {decoded.test_prepare, decoded.env} == {[], %{}}
    end

    test "carries test_prepare and env" do
      steps = [
        ["rm", "-rf", "--", "tmp/cache/bootsnap", "db/test.sqlite3"],
        ["bundle", "exec", "rake", "db:prepare"],
        ["rm", "-f", "--", "/tmp/rsolv-report.json"]
      ]

      assert {:ok, %VerifyPlan{test_prepare: ^steps, env: %{"RAILS_ENV" => "test"}}} =
               VerifyPlan.decode(
                 v2(%{"test_prepare" => steps, "env" => %{"RAILS_ENV" => "test"}})
               )
    end

    test "accepts every allowlisted env key set to test" do
      env = %{"RAILS_ENV" => "test", "RACK_ENV" => "test", "MIX_ENV" => "test"}
      assert {:ok, %VerifyPlan{env: ^env}} = VerifyPlan.decode(v2(%{"env" => env}))
    end

    test "may prepare with project tooling, which runs on base" do
      prepare = [["bundle", "exec", "rake", "assets:precompile"]]

      assert {:ok, %VerifyPlan{prepare: ^prepare}} =
               VerifyPlan.decode(v2(%{"prepare" => prepare}))
    end

    test "accepts up to 8 test_prepare steps and refuses a ninth" do
      step = ["rm", "-f", "--", "x"]
      assert {:ok, _plan} = VerifyPlan.decode(v2(%{"test_prepare" => List.duplicate(step, 8)}))

      assert VerifyPlan.decode(v2(%{"test_prepare" => List.duplicate(step, 9)})) ==
               {:error, :invalid_plan}
    end

    test "holds test_prepare to install's argv rules" do
      for step <- [["sh", "-c", "id"], ["curl", "x"], ["python", "-Bc", "1"], []] do
        assert VerifyPlan.decode(v2(%{"test_prepare" => [step]})) == {:error, :invalid_plan},
               inspect(step)
      end

      assert VerifyPlan.decode(v2(%{"test_prepare" => "rake"})) == {:error, :invalid_plan}
    end

    for {name, env} <- [
          {"a customer secret", %{"RAILS_MASTER_KEY" => "test"}},
          {"PATH", %{"PATH" => "test"}},
          {"RUBYOPT", %{"RUBYOPT" => "test"}},
          {"RAILS_ENV other than test", %{"RAILS_ENV" => "production"}},
          {"a non-string value", %{"RAILS_ENV" => 1}},
          {"a list", [["RAILS_ENV", "test"]]},
          {"a string", "RAILS_ENV=test"},
          {"null", nil}
        ] do
      test "refuses env holding #{name}" do
        assert VerifyPlan.decode(v2(%{"env" => unquote(Macro.escape(env))})) ==
                 {:error, :invalid_plan}
      end
    end

    for key <- ["test_prepare", "env"] do
      test "refuses a v2 plan without #{key}" do
        assert VerifyPlan.decode(Map.delete(v2(), unquote(key))) == {:error, :invalid_plan}
      end

      test "refuses a v1 plan with #{key}" do
        assert VerifyPlan.decode(Map.put(plan(), unquote(key), v2()[unquote(key)])) ==
                 {:error, :invalid_plan}
      end
    end

    test "refuses an extra member" do
      assert VerifyPlan.decode(Map.put(v2(), "secrets", %{})) == {:error, :invalid_plan}
    end
  end

  describe "decode/1, the plan version" do
    for v <- [0, 3, "2", "1", 1.0, nil] do
      test "refuses v #{inspect(v)}" do
        assert VerifyPlan.decode(v2(%{"v" => unquote(v)})) == {:error, :invalid_plan}
        assert VerifyPlan.decode(plan(%{"v" => unquote(v)})) == {:error, :invalid_plan}
      end
    end

    test "gives a v1 plan no test_prepare and no env" do
      assert {:ok, decoded} = VerifyPlan.decode(plan())
      assert {decoded.test_prepare, decoded.env} == {[], %{}}
    end
  end

  describe "decode/1, a v1 plan's prepare" do
    for argv <- [
          ~w(bundle exec rake db:prepare),
          ~w(npx jest --clearCache),
          ~w(python -m compileall pkg),
          ~w(mix compile),
          ~w(mvn -B -q compile),
          ~w(vendor/bin/phpunit --version),
          ~w(cat -- x),
          ~w(find . -name *.pyc)
        ] do
      test "refuses #{hd(argv)}: v1 prepare runs only rm" do
        assert VerifyPlan.decode(plan(%{"prepare" => [unquote(argv)]})) == {:error, :invalid_plan}
      end
    end

    test "refuses rm after a step that isn't rm" do
      prepare = [["rm", "-rf", "--", "a"], ["python", "-m", "compileall", "."]]
      assert VerifyPlan.decode(plan(%{"prepare" => prepare})) == {:error, :invalid_plan}
    end

    test "accepts a __pycache__ rm with 256 arguments, and refuses 257" do
      rm = fn n -> ["rm", "-rf", "--" | for(i <- 1..(n - 3), do: "d#{i}/__pycache__")] end

      assert {:ok, %VerifyPlan{prepare: [argv]}} =
               VerifyPlan.decode(plan(%{"prepare" => [rm.(256)]}))

      assert length(argv) == 256
      assert VerifyPlan.decode(plan(%{"prepare" => [rm.(257)]})) == {:error, :invalid_plan}
    end

    test "accepts the pytest template's fail-closed pip install" do
      install = [
        ["python", "-m", "pip", "install", "--no-input", "pytest==8.3.3"],
        ["python", "-m", "pip", "freeze", "--all"]
      ]

      assert {:ok, %VerifyPlan{install: ^install}} =
               VerifyPlan.decode(plan(%{"framework" => "pytest", "install" => install}))
    end
  end

  describe "decode/1 on arbitrary members" do
    use ExUnitProperties

    property "never raises, whatever a member holds" do
      check all(field <- member_of(Map.keys(plan())), value <- term()) do
        assert match?({:ok, %VerifyPlan{}}, VerifyPlan.decode(plan(%{field => value}))) or
                 VerifyPlan.decode(plan(%{field => value})) == {:error, :invalid_plan}
      end
    end
  end
end
