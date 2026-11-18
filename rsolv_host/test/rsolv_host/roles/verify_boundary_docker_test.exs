defmodule RsolvHost.Roles.VerifyBoundaryDockerTest do
  # The verify role's trust boundary (design spec §2.3, §8), end to end on a
  # real Docker with the pinned sandbox image (`RsolvHost.VerifyDocker`).
  # Each test drives shell steps through the base's harness; every sentinel
  # is on the host side (tmp_dir, `deps[:observe]`, or the bytes the host
  # posts), and every comparison is by SHA-256, exit status or reported bytes.
  use ExUnit.Case, async: false

  import RsolvHost.VerifyDocker, except: [verify: 3, verify: 4]

  alias RsolvHost.VerifyDocker

  @moduletag :docker
  @moduletag :tmp_dir
  @moduletag timeout: 900_000

  @base %{
    "app/a.rb" => "class A; end # base\n",
    "app/b.rb" => "class B; end # base\n",
    "lib/keep.rb" => "keep\n",
    "log/.keep" => ""
  }
  @fixed %{
    "app/a.rb" => "class A; end # the fix\n",
    "app/b.rb" => "class B; end # the fix, too\n"
  }
  @red_path "spec/red_spec.rb"
  @red "RSpec.describe(A) { it { expect(A).to be_secure } }\n"
  @fix_paths Map.keys(@fixed)
  @report "/work/rsolv-report"

  setup %{tmp_dir: dir} do
    checkout(dir, Map.put(@base, "vendor/bin/phpunit", harness()),
      executable: ["vendor/bin/phpunit"]
    )
  end

  defp change,
    do: [{@red_path, nil, @red} | for({path, new} <- @fixed, do: {path, @base[path], new})]

  defp plan(overrides), do: plan(change(), [@red_path], overrides)

  defp verify(context, plan, opts \\ []), do: VerifyDocker.verify(context, change(), plan, opts)

  defp tree_sha(dir) do
    for path <- Path.wildcard(Path.join(dir, "**"), match_dot: true), File.regular?(path) do
      {Path.relative_to(path, dir), sha256(File.read!(path))}
    end
    |> Enum.sort()
  end

  defp rsolv_dirs(context), do: File.ls!(Path.join(context.env["RUNNER_TEMP"], "rsolv"))

  describe "BUILD sees only the base (B1)" do
    test "(a) prepare's sha256sum of every change-set target, carried into TEST, is the base's",
         context do
      targets = Enum.join(@fix_paths ++ [@red_path], " ")

      %{result: result, body: body} =
        verify(
          context,
          plan(%{
            "prepare" => [sh("sha256sum #{targets} > .build-shas 2>&1; true")],
            "test" => sh("cp .build-shas #{@report}")
          })
        )

      assert result == {:outcome, :verified, false}

      for side <- ["red", "green"] do
        lines = report(body, side)

        for path <- @fix_paths,
            do: assert(lines =~ "#{sha256(@base[path])}  #{path}", "#{side}: #{path}")

        assert lines =~ "sha256sum: #{@red_path}: No such file or directory"
      end
    end

    test "(f) RED's TEST copy holds the base bytes at every fix path", context do
      %{body: body} =
        verify(
          context,
          plan(%{"test" => sh("sha256sum #{Enum.join(@fix_paths, " ")} > #{@report}")})
        )

      red = report(body, "red")
      green = report(body, "green")

      for path <- @fix_paths do
        assert red =~ "#{sha256(@base[path])}  #{path}"
        assert green =~ "#{sha256(@fixed[path])}  #{path}"
      end
    end
  end

  describe "BUILD's teardown and the copy for TEST (B2, B3)" do
    test "(b) a writer BUILD forked is gone: the build copy, the TEST copy and TEST agree on log/alive",
         context do
      test = self()

      observe = fn %{side: side, build: build, test: copy} ->
        send(
          test,
          {:observed, side, sha256(File.read!(Path.join(build, "log/alive"))),
           sha256(File.read!(Path.join(copy, "log/alive")))}
        )
      end

      writer =
        "(while :; do date +%s%N >> log/alive; sleep 0.05; done) > /dev/null 2>&1 & sleep 1"

      %{body: body} =
        verify(
          context,
          plan(%{
            "prepare" => [sh(writer)],
            "test" => sh("sleep 2; sha256sum log/alive > #{@report}")
          }),
          deps: [observe: observe]
        )

      for side <- ["red", "green"] do
        assert_received {:observed, ^side, at_build, at_copy}
        assert at_build == at_copy
        assert report(body, side) =~ at_copy <> "  log/alive"
      end
    end

    test "(g) BUILD's $HOME carries into TEST", context do
      %{body: body} =
        verify(
          context,
          plan(%{
            "prepare" => [sh("echo home-marker > $HOME/marker")],
            "test" => sh("cat $HOME/marker > #{@report}")
          })
        )

      assert report(body, "red") == "home-marker\n"
      assert report(body, "green") == "home-marker\n"
    end

    test "(j) a BUILD Docker can't confirm removed: a teardown error, and no TEST directory or container",
         context do
      calls = :counters.new(1, [])

      fail_first_rm = fn {"docker", ["rm", "-f" | _], _} ->
        :counters.add(calls, 1, 1)
        :counters.get(calls, 1) == 1
      end

      %{result: result, body: body, out: out} =
        verify(
          context,
          plan(%{
            "prepare" => [
              sh("(while :; do date >> log/alive; sleep 0.1; done) > /dev/null 2>&1 & true")
            ]
          }),
          exec: [{fail_first_rm, {:ok, %{status: 1, output: "refused by the test"}}}],
          answers: %{
            "verification" => {200, %{verification: "verify_error", reasons: ["sandbox"]}}
          }
        )

      assert result == {:error, {:sandbox, :teardown}}

      assert Map.take(body, ~w(error red green build_evidence)) == %{"error" => "sandbox"}

      assert out =~ "::warning"
      refute Enum.any?(rsolv_dirs(context), &String.contains?(&1, "-test"))
      assert "rsolv-#{context.run}-1-7-verify-red-build" in containers(context)
      refute Enum.any?(containers(context), &String.ends_with?(&1, "-test"))
    end

    test "(l) a RED TEST Docker can't confirm removed: no GREEN directory, and the post is a sandbox error",
         context do
      calls = :counters.new(1, [])

      fail_second_rm = fn {"docker", ["rm", "-f" | _], _} ->
        :counters.add(calls, 1, 1)
        :counters.get(calls, 1) == 2
      end

      %{result: result, body: body} =
        verify(context, plan(%{}),
          exec: [{fail_second_rm, {:ok, %{status: 1, output: "refused by the test"}}}],
          answers: %{
            "verification" => {200, %{verification: "verify_error", reasons: ["sandbox"]}}
          }
        )

      assert result == {:error, {:sandbox, :teardown}}
      assert body["error"] == "sandbox"
      refute Enum.any?(rsolv_dirs(context), &String.contains?(&1, "-green"))
      assert "rsolv-#{context.run}-1-7-verify-red-test" in containers(context)
    end
  end

  describe "the overlay (B4)" do
    test "(c) a BUILD that appends to a fix target makes GREEN's overlay refuse", context do
      %{result: result, body: body} =
        verify(context, plan(%{"prepare" => [sh("printf x >> app/a.rb")]}),
          answers: %{"verification" => {200, %{verification: "verify_error", reasons: []}}}
        )

      assert result == {:error, :overlay_refused}
      assert body["error"] == "install_failed_green"
      refute Enum.any?(containers(context), &String.ends_with?(&1, "-green-test"))
    end

    test "(d) a BUILD that swaps app/ for a symlink to a host directory makes the overlay refuse, and the host directory is untouched",
         context do
      host = Path.join(context.env["RUNNER_TEMP"], "host-dir")
      File.mkdir_p!(Path.join(host, "deep"))
      File.write!(Path.join(host, "a.rb"), "host's own\n")
      File.write!(Path.join(host, "deep/b.rb"), "host's own\n")
      before = tree_sha(host)

      %{result: result, body: body} =
        verify(context, plan(%{"prepare" => [sh("rm -rf app && ln -s '#{host}' app")]}),
          answers: %{"verification" => {200, %{verification: "verify_error", reasons: []}}}
        )

      assert result == {:error, :overlay_refused}
      assert body["error"] == "install_failed_green"
      assert tree_sha(host) == before
    end
  end

  describe "TEST is offline, read-only and bounded (B5, B6)" do
    test "(e) TEST resolves nothing and has no proxy variable", context do
      %{body: body} =
        verify(
          context,
          plan(%{
            "test" => sh("{ getent hosts github.com; echo getent=$?; env; } > #{@report} 2>&1")
          })
        )

      for side <- ["red", "green"] do
        report = report(body, side)
        assert report =~ "getent=2"
        refute report =~ ~r/_proxy=/i
      end
    end

    test "(m) TEST can write only /work, HOME, a 1 GiB /tmp and a 64 MiB /dev/shm", context do
      touches =
        for path <- ~w(/x /var/tmp/x /etc/x /usr/local/x /opt/x /run/x /work/x $HOME/x),
            do:
              "if touch #{path} 2>/work/e; then echo '#{path} ok'; else echo '#{path}' $(cat /work/e); fi"

      fills =
        for {name, path, bytes} <- [
              {"tmp", "/tmp/big", 1024 ** 3 + 1},
              {"shm", "/dev/shm/big", 64 * 1024 ** 2 + 1}
            ],
            do:
              "if head -c #{bytes} /dev/zero > #{path} 2>/work/e; then echo '#{name} ok'; else echo '#{name}' $(cat /work/e); fi; rm -f #{path}"

      script = "{ " <> Enum.join(touches ++ fills, "; ") <> "; } > #{@report}"
      %{body: body} = verify(context, plan(%{"test" => sh(script)}))

      lines =
        body
        |> report("red")
        |> String.split("\n", trim: true)
        |> Map.new(&List.to_tuple(String.split(&1, " ", parts: 2)))

      for path <- ~w(/x /var/tmp/x /etc/x /usr/local/x /opt/x /run/x),
          do: assert(lines[path] =~ "Read-only file system", "#{path}: #{lines[path]}")

      assert lines["/work/x"] == "ok"
      assert lines["$HOME/x"] == "ok"
      assert lines["tmp"] =~ "No space left on device"
      assert lines["shm"] =~ "No space left on device"
    end
  end

  describe "what leaves the host (B10) and build evidence (§3.1)" do
    test "(n) a TEST that rewrites every fix file, adds a file and edits the RED file sends nothing but the verification body",
         context do
      marker = "EVIL-#{System.unique_integer([:positive])}"

      tamper =
        Enum.map_join(@fix_paths ++ [@red_path, "app/evil.rb"], "; ", &"echo #{marker} > #{&1}")

      %{body: body} = verify(context, plan(%{"test" => sh(tamper)}))

      events = events()
      after_sandbox = Enum.drop_while(events, &(&1 != :docker_run))
      assert for({:platform, name} <- after_sandbox, do: name) == ["verification"]

      assert for({:platform, name} <- events, do: name) -- ["token"] ==
               ~w(touched-paths base-facts verify-plan post-images verification)

      encoded = JSON.encode!(body)
      refute encoded =~ marker
      refute encoded =~ Base.encode64(marker)

      assert Map.keys(body) |> Enum.sort() ==
               ~w(build_evidence change_set_digest green policy_version red red_digest)
    end

    test "(o) BUILD steps' output is the evidence, a step over 256 KiB truncated, and TEST can't change it",
         context do
      %{body: body} =
        verify(
          context,
          plan(%{
            "prepare" => [sh("printf 0123456789"), sh("head -c 307200 /dev/zero")],
            "test" =>
              sh(
                "echo forged > $HOME/evidence; echo forged > /work/evidence; echo forged > #{@report}"
              )
          })
        )

      for side <- ["red", "green"] do
        assert body["build_evidence"][side] == %{
                 "install" => [],
                 "prepare" => [Base.encode64("0123456789"), %{"truncated" => true}]
               }
      end
    end
  end

  describe "after the review (Astra, Kimi)" do
    test "(c2) a BUILD that leaves a 10 GiB sparse file at a fix target makes GREEN's overlay refuse, without reading it",
         context do
      %{result: result, body: body} =
        verify(context, plan(%{"prepare" => [sh("truncate -s 10G app/a.rb")]}),
          answers: %{"verification" => {200, %{verification: "verify_error", reasons: []}}}
        )

      assert result == {:error, :overlay_refused}
      assert body["error"] == "install_failed_green"
    end

    test "(q) a BUILD that swaps .git/refs for a symlink to a host directory: the host deletes nothing there",
         context do
      host = Path.join(context.env["RUNNER_TEMP"], "host-refs")
      File.mkdir_p!(host)
      File.write!(Path.join(host, "x.lock"), "host's own\n")

      %{result: result} =
        verify(
          context,
          plan(%{"prepare" => [sh("rm -rf .git/refs && ln -s '#{host}' .git/refs")]})
        )

      assert result == {:outcome, :verified, false}
      assert File.read!(Path.join(host, "x.lock")) == "host's own\n"
    end

    test "(r) BUILD's root is read-only: it can write only /work, HOME, /tmp and /dev/shm",
         context do
      touches =
        Enum.map_join(
          ~w(/x /var/tmp/x /etc/x /usr/local/x /opt/x /run/x /work/x $HOME/x /tmp/x /dev/shm/x),
          "; ",
          &"if touch #{&1} 2>/work/e; then echo '#{&1} ok'; else echo '#{&1}' $(cat /work/e); fi"
        )

      %{body: body} = verify(context, plan(%{"prepare" => [sh(touches)]}))

      lines =
        body["build_evidence"]["red"]["prepare"]
        |> hd()
        |> Base.decode64!()
        |> String.split("\n", trim: true)
        |> Map.new(&List.to_tuple(String.split(&1, " ", parts: 2)))

      for path <- ~w(/x /var/tmp/x /etc/x /usr/local/x /opt/x /run/x),
          do: assert(lines[path] =~ "Read-only file system", "#{path}: #{lines[path]}")

      for path <- ~w(/work/x $HOME/x /tmp/x /dev/shm/x), do: assert(lines[path] == "ok", path)
    end

    for phase <- ["BUILD", "TEST"] do
      test "(s) a #{phase} writing past its disk budget is stopped, and is a sandbox error, never a verdict",
           context do
        fill = "head -c 67108864 /dev/zero > /work/fill; sleep 5"

        overrides =
          if unquote(phase) == "BUILD",
            do: %{"prepare" => [sh(fill)]},
            else: %{"test" => sh(fill)}

        %{result: result, body: body} =
          verify(context, plan(overrides),
            deps: [disk_allowance_bytes: 16 * 1024 * 1024, disk_poll_ms: 200],
            answers: %{
              "verification" => {200, %{verification: "verify_error", reasons: ["sandbox"]}}
            }
          )

        assert result == {:error, {:sandbox, :disk_limit}}
        assert Map.take(body, ~w(error red green)) == %{"error" => "sandbox"}
      end
    end
  end
end
