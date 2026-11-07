defmodule RsolvHost.RuntimesTest do
  use ExUnit.Case, async: true

  alias RsolvHost.Runtimes

  @digest String.duplicate("ab", 32)
  @artifact "cpython-3.11.11+20261026-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz sha256:" <>
              @digest

  defp annotate(reports) do
    {:ok, io} = StringIO.open("")
    :ok = Runtimes.annotate(reports, io)
    io |> StringIO.contents() |> elem(1)
  end

  describe "annotate/2" do
    test "warns of a same-minor fallback, with the requested and actual versions and the artifact" do
      out =
        annotate([
          %{
            "runtime" => "python",
            "requested" => "3.11.9",
            "actual" => "3.11.11",
            "status" => "fallback",
            "artifact" => @artifact
          }
        ])

      assert [line] = String.split(out, "\n", trim: true)
      assert line =~ ~r/\A::warning title=RSOLV runtime::/
      assert line =~ "Python 3.11.9 has no published build attestations"
      assert line =~ "3.11.11, the newest attested 3.11 patch"

      assert line =~
               "cpython-3.11.11+20261026-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz"

      assert line =~ "sha256:" <> @digest
      assert line =~ "RSOLV_EXACT_RUNTIME_VERSIONS=true"
    end

    test "annotates a failed install as an error naming the version and why" do
      for {reason, why} <- [
            {"no_attestations", "it has no published build attestations"},
            {"verification_failed", "its build attestations failed verification"},
            {"transient", "the download kept failing"},
            {"build_failed", "the build failed"},
            {"timeout", "the build ran out of time"},
            {"unsupported", "mise doesn't offer that version"}
          ] do
        out =
          annotate([
            %{
              "runtime" => "php",
              "requested" => "8.3.36",
              "status" => "failed",
              "reason" => reason
            }
          ])

        assert out =~ ~r/\A::error title=RSOLV runtime::PHP 8.3.36 was not installed/
        assert out =~ why
        assert out =~ "No other version was substituted"
      end
    end

    test "says nothing about a runtime installed as asked" do
      assert annotate([
               %{
                 "runtime" => "maven",
                 "requested" => "3.9.11",
                 "actual" => "3.9.11",
                 "status" => "installed"
               }
             ]) == ""
    end

    test "never puts a value it can't vouch for into an annotation" do
      bad = [
        %{
          "runtime" => "python",
          "requested" => "3.11.9\n::error::x",
          "status" => "failed",
          "reason" => "transient"
        },
        %{
          "runtime" => "python",
          "requested" => "3.11.9",
          "actual" => "3.12.0",
          "status" => "fallback"
        },
        %{
          "runtime" => "rust",
          "requested" => "1.80.0",
          "status" => "failed",
          "reason" => "transient"
        },
        %{
          "runtime" => "php",
          "requested" => "8.3.1",
          "status" => "failed",
          "reason" => "%0A::error::x"
        },
        %{
          "runtime" => "python",
          "requested" => "3.11.9",
          "actual" => "3.11.11",
          "status" => "fallback",
          "artifact" => "x\n::error::y"
        },
        "python",
        nil
      ]

      for report <- bad do
        out = annotate([report])
        assert [line] = String.split(out, "\n", trim: true), inspect(report)

        assert line ==
                 "::warning title=RSOLV runtime::The sandbox returned a runtime report the host couldn't read."
      end
    end

    test "writes a bounded number of annotations, however many reports the sandbox returns" do
      failed = %{
        "runtime" => "php",
        "requested" => "8.3.36",
        "status" => "failed",
        "reason" => "build_failed"
      }

      lines =
        [failed]
        |> Stream.cycle()
        |> Enum.take(10_000)
        |> annotate()
        |> String.split("\n", trim: true)

      assert length(lines) == 4
      assert List.last(lines) =~ "couldn't read"
    end

    test "reads nothing from a result that isn't a list of reports" do
      assert annotate(nil) == ""
      assert annotate("python") =~ "couldn't read"
    end
  end
end
