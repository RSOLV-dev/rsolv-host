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
      assert VerifyPlan.decode(plan(%{"prepare" => [find]})) == {:error, :invalid_plan}
    end

    test "refuses -c anywhere in an argv" do
      assert VerifyPlan.decode(plan(%{"prepare" => [["python", "-c", "print(1)"]]})) ==
               {:error, :invalid_plan}
    end

    test "refuses find -exec of anything but cat" do
      for exec <- ~w(-exec -execdir -ok -okdir) do
        find = ["find", ".", exec, "curl", "x", ";"]
        assert VerifyPlan.decode(plan(%{"prepare" => [find]})) == {:error, :invalid_plan}
      end
    end

    test "refuses find -exec of a shell outside the refused names" do
      find = ["find", ".", "-exec", "/bin/dash", "p.sh", ";"]
      assert VerifyPlan.decode(plan(%{"prepare" => [find]})) == {:error, :invalid_plan}
    end

    test "refuses -c attached to its argument" do
      argv = ["python", "-c__import__('os').system('id')"]
      assert VerifyPlan.decode(plan(%{"prepare" => [argv]})) == {:error, :invalid_plan}
    end

    test "refuses python's -c inside a cluster of short options" do
      argv = ["python", "-Bc", "import os"]
      assert VerifyPlan.decode(plan(%{"prepare" => [argv]})) == {:error, :invalid_plan}
    end

    test "refuses npx --call" do
      for call <- [["npx", "--call", "id"], ["npx", "--call=id"]] do
        assert VerifyPlan.decode(plan(%{"test" => call})) == {:error, :invalid_plan}
      end
    end

    test "refuses every shell and env by name or path" do
      for shell <- ~w(sh bash dash zsh ksh ash fish busybox env /usr/bin/env /bin/zsh) do
        find = ["find", ".", "-exec", "cat", shell, ";"]
        assert VerifyPlan.decode(plan(%{"prepare" => [find]})) == {:error, :invalid_plan}
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
