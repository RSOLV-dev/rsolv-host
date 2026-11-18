defmodule RsolvHost.Roles.VerifyBoundaryDockerTest do
  # The verify role's trust boundary (design spec §2.3, §8), end to end on a
  # real Docker with the pinned sandbox image; only the platform is stubbed.
  #
  # The base checkout carries `vendor/bin/phpunit`, a one-line shell harness
  # standing in for project tooling: it's base code, and the one plan
  # executable a tree can supply, so each test drives real shell steps
  # through an ordinary plan. Every sentinel is on the host side (tmp_dir,
  # `deps[:observe]`, or the bytes the host posts), and every comparison is
  # by SHA-256, exit status or the reported bytes.
  use ExUnit.Case, async: false

  import RsolvHost.PlatformStub

  alias RsolvCore.ChangeSet
  alias RsolvHost.{Exec, FakeExec, Oidc, Platform}
  alias RsolvHost.Roles.Verify

  @moduletag :docker
  @moduletag :tmp_dir
  @moduletag timeout: 900_000

  @sandbox_image (fn ->
                    config = File.read!(Path.expand("../../../config/config.exs", __DIR__))
                    [_, image] = Regex.run(~r/sandbox_image:\s*"([^"]+)"/, config)
                    image
                  end).()

  @run_id "0b0e5f7c-7d3c-4d8e-9a55-3f6f1b0c2a11"
  @harness ~s(#!/bin/sh\n# Stands in for project tooling: runs its one argument.\nexec /bin/sh -c "$1"\n)
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

  defp git(dir, args) do
    env = [
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_AUTHOR_NAME", "t"},
      {"GIT_AUTHOR_EMAIL", "t@example.com"},
      {"GIT_COMMITTER_NAME", "t"},
      {"GIT_COMMITTER_EMAIL", "t@example.com"}
    ]

    {out, 0} = System.cmd("git", args, cd: dir, env: env, stderr_to_stdout: true)
    String.trim(out)
  end

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:rsolv_host, :sandbox_image)
    Application.put_env(:rsolv_host, :sandbox_image, @sandbox_image)
    run = "#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Application.put_env(:rsolv_host, :sandbox_image, previous)
      remove_run(run)
    end)

    checkout = Path.join(dir, "checkout")

    for {path, bytes} <- Map.put(@base, "vendor/bin/phpunit", @harness) do
      File.mkdir_p!(Path.dirname(Path.join(checkout, path)))
      File.write!(Path.join(checkout, path), bytes)
    end

    File.chmod!(Path.join(checkout, "vendor/bin/phpunit"), 0o755)
    git(checkout, ["init", "-q"])
    git(checkout, ["add", "-A"])
    git(checkout, ["commit", "-q", "-m", "base"])

    env = %{
      "RUNNER_TEMP" => dir,
      "GITHUB_WORKSPACE" => checkout,
      "GITHUB_RUN_ID" => run,
      "GITHUB_RUN_ATTEMPT" => "1",
      "GITHUB_REPOSITORY" => "acme/app",
      "ACTIONS_ID_TOKEN_REQUEST_URL" => "https://token.actions.example/id?v=1",
      "ACTIONS_ID_TOKEN_REQUEST_TOKEN" => "t"
    }

    %{env: env, checkout: checkout, base: git(checkout, ["rev-parse", "HEAD"]), run: run}
  end

  # Whatever a test's role run left: its containers, then its networks.
  defp remove_run(run) do
    for {list, rm} <- [
          {["ps", "-aq"], ["rm", "-f"]},
          {["network", "ls", "-q"], ["network", "rm"]}
        ] do
      {ids, _} = System.cmd("docker", list ++ ["--filter", "label=rsolv.run=#{run}"])
      ids = String.split(ids, "\n", trim: true)
      if ids != [], do: System.cmd("docker", rm ++ ids, stderr_to_stdout: true)
    end
  end

  defp entry(path, op, base, new) do
    %{
      "path" => path,
      "op" => op,
      "base_mode" => base && "100644",
      "base_blob_sha" => base && ChangeSet.blob_sha(base),
      "mode" => "100644",
      "new_blob_sha" => ChangeSet.blob_sha(new)
    }
  end

  defp change_set do
    Enum.sort_by(
      [
        entry(@red_path, "add", nil, @red)
        | for({p, new} <- @fixed, do: entry(p, "modify", @base[p], new))
      ],
      & &1["path"]
    )
  end

  defp digest(json), do: json |> ChangeSet.from_json() |> elem(1) |> ChangeSet.digest()

  defp sh(script), do: ["vendor/bin/phpunit", script]

  # A v2 plan whose steps are harness scripts: `prepare` runs in BUILD,
  # `test_prepare` and `test` in TEST, and the report is `@report`.
  defp plan(overrides) do
    red = Enum.filter(change_set(), &(&1["path"] == @red_path))

    Map.merge(
      %{
        "v" => 2,
        "framework" => "rspec",
        "install" => [],
        "prepare" => [],
        "test_prepare" => [],
        "env" => %{},
        "test" => sh("true"),
        "report" => %{"format" => "rspec_json", "argv" => ["cat", "--", @report]},
        "install_timeout_s" => 600,
        "test_timeout_s" => 600,
        "change_set" => change_set(),
        "change_set_digest" => digest(change_set()),
        "red_paths" => [@red_path],
        "red_digest" => digest(red),
        "policy_version" => "2026-11-v4"
      },
      overrides
    )
  end

  defp platform(context, plan, answers) do
    test = self()
    Req.Test.stub(Oidc, &Req.Test.json(&1, %{value: "e30.e30.sig"}))

    images =
      Map.new([
        {@red_path, Base.encode64(@red)} | for({p, b} <- @fixed, do: {p, Base.encode64(b)})
      ])

    defaults = %{
      "touched-paths" => {200, %{paths: Enum.map(change_set(), & &1["path"]), work_attempt: 1}},
      "base-facts" =>
        {200,
         %{
           status: "accepted",
           reasons: [],
           flags: [],
           change_set_digest: plan["change_set_digest"],
           red_digest: plan["red_digest"],
           policy_version: plan["policy_version"]
         }},
      "verify-plan" => {200, plan},
      "post-images" => {200, %{files: images}},
      "verification" => {200, %{verification: "green", reasons: []}}
    }

    answers = Map.merge(defaults, answers)

    Req.Test.stub(Platform, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/api/v1/runs/token"} ->
          send(test, {:event, {:platform, "token"}})
          Req.Test.json(conn, Map.put(token(), :base_sha, context.base))

        {method, "/api/v1/runs/" <> @run_id <> "/issues/7/" <> name} ->
          answer(conn, method, name, answers[name], test)
      end
    end)
  end

  defp answer(conn, method, name, {status, json}, test) do
    {body, conn} = if method == "POST", do: body(conn), else: {nil, conn}
    send(test, {:event, {:platform, name}})
    send(test, {:request, name, method, body})
    conn |> Plug.Conn.put_status(status) |> Req.Test.json(json)
  end

  # Every exec is real, except what `overrides` answers first. Each docker
  # run is told to the test, so requests can be ordered against sandboxes.
  defp real(overrides) do
    test = self()

    FakeExec.script(
      overrides ++
        [
          {fn _call -> true end,
           fn {exe, args, opts} ->
             if match?({"docker", ["run" | _]}, {exe, args}),
               do: send(test, {:event, :docker_run})

             Exec.run(exe, args, opts)
           end}
        ]
    )
  end

  defp verify(context, plan, opts \\ []) do
    platform(context, plan, Keyword.get(opts, :answers, %{}))
    real(Keyword.get(opts, :exec, []))
    {:ok, io} = StringIO.open("")
    result = Verify.run(%{issue: 7}, context.env, [io: io] ++ Keyword.get(opts, :deps, []))
    {:ok, {_in, out}} = StringIO.close(io)
    %{result: result, body: posted(), out: out}
  end

  defp posted do
    receive do
      {:request, "verification", "POST", body} -> body
    after
      0 -> nil
    end
  end

  defp report(body, side), do: Base.decode64!(body[side]["report"])

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp tree_sha(dir) do
    for path <- Path.wildcard(Path.join(dir, "**"), match_dot: true), File.regular?(path) do
      {Path.relative_to(path, dir), sha256(File.read!(path))}
    end
    |> Enum.sort()
  end

  defp rsolv_dirs(context), do: File.ls!(Path.join(context.env["RUNNER_TEMP"], "rsolv"))

  defp containers(context) do
    {out, 0} =
      System.cmd("docker", [
        "ps",
        "-a",
        "--filter",
        "label=rsolv.run=#{context.run}",
        "--format",
        "{{.Names}}"
      ])

    String.split(out, "\n", trim: true)
  end

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

      events = collect_events()
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

  defp collect_events(acc \\ []) do
    receive do
      {:event, event} -> collect_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
