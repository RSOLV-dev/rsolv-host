defmodule RsolvHost.SandboxTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias RsolvHost.{FakeExec, Sandbox}

  @moduletag :tmp_dir
  @image "ghcr.io/rsolv-dev/rsolv-sandbox@sha256:" <> String.duplicate("1", 64)

  defp ok(output), do: {:ok, %{status: 0, output: output}}

  defp docker_args, do: for({"docker", args, _opts} <- FakeExec.calls(), do: args)

  defp start_opts(dir, extra \\ []) do
    copy = Path.join(dir, "work")
    File.mkdir_p!(copy)

    [
      name: "rsolv-41-7-work",
      network: "rsolv-41-7-net",
      copy_dir: copy,
      runner_temp: dir,
      image: @image,
      probe: fn "172.17.0.5" -> :ok end
    ]
    |> Keyword.merge(extra)
  end

  defp script_inspect do
    FakeExec.script([
      {fn {"docker", ["inspect", "-f", template, "rsolv-41-7-work-proxy"], _} ->
         template =~ "rsolv-41-7-net"
       end, ok("172.18.0.2\n")},
      {fn {"docker", ["inspect", "-f", template, "rsolv-41-7-work-proxy"], _} ->
         template =~ "bridge"
       end, ok("172.17.0.5\n")}
    ])
  end

  defp inspect_rules do
    [
      {fn {"docker", ["inspect", "-f", template, "rsolv-41-7-work-proxy"], _} ->
         template =~ "rsolv-41-7-net"
       end, ok("172.18.0.2\n")},
      {fn {"docker", ["inspect", "-f", template, "rsolv-41-7-work-proxy"], _} ->
         template =~ "bridge"
       end, ok("172.17.0.5\n")}
    ]
  end

  describe "run_args/1" do
    test "is exactly the hardened sandbox, behind the proxy" do
      opts = %{
        name: "rsolv-41-7-work",
        network: "rsolv-41-7-net",
        copy_dir: "/rt/rsolv/work",
        home_dir: "/rt/rsolv/home-rsolv-41-7-work",
        uid: 1001,
        gid: 118,
        proxy_ip: "172.18.0.2",
        image: @image
      }

      assert Sandbox.run_args(opts) ==
               [
                 "run",
                 "-d",
                 "--name",
                 "rsolv-41-7-work",
                 "--network",
                 "rsolv-41-7-net",
                 "--dns",
                 "127.0.0.1"
               ] ++
                 ["--log-driver", "none"] ++
                 [
                   "--user",
                   "1001:118",
                   "--cap-drop",
                   "ALL",
                   "--security-opt",
                   "no-new-privileges"
                 ] ++
                 ["--pids-limit", "4096", "--tmpfs", "/tmp:exec,size=1g"] ++
                 ["--memory", "4g", "--memory-swap", "4g", "--cpus", "2"] ++
                 ["-e", "LANG=C.UTF-8", "-e", "CI=true", "-e", "HOME=/opt/home"] ++
                 [
                   "-e",
                   "HTTP_PROXY=http://172.18.0.2:3128",
                   "-e",
                   "HTTPS_PROXY=http://172.18.0.2:3128"
                 ] ++
                 [
                   "-e",
                   "http_proxy=http://172.18.0.2:3128",
                   "-e",
                   "https_proxy=http://172.18.0.2:3128"
                 ] ++
                 ["-e", "NO_PROXY=localhost,127.0.0.1", "-e", "no_proxy=localhost,127.0.0.1"] ++
                 ["-v", "/rt/rsolv/work:/work"] ++
                 ["-v", "/rt/rsolv/home-rsolv-41-7-work:/opt/home", "-w", "/work"] ++
                 ["--entrypoint", "sleep", @image, "86400"]
    end

    test "with no egress, has no network and no proxy variables" do
      args =
        Sandbox.run_args(%{
          name: "s",
          network: "n",
          copy_dir: "/c",
          home_dir: "/h",
          uid: 1,
          gid: 1,
          proxy_ip: nil,
          image: @image,
          egress: :none
        })

      assert ["--network", "none"] == Enum.slice(args, 4, 2)
      refute Enum.any?(args, &(&1 =~ "PROXY"))
    end

    property "every -e sets a value, and nothing exposes the host" do
      check all(
              egress <- member_of([:proxy, :none]),
              uid <- positive_integer(),
              gid <- positive_integer(),
              name <- string(:alphanumeric, min_length: 1),
              ip <- member_of(["172.18.0.2", "10.0.0.9"]),
              read_only <- boolean()
            ) do
        args =
          Sandbox.run_args(%{
            name: name,
            network: name <> "-net",
            copy_dir: "/c/" <> name,
            home_dir: "/h/" <> name,
            uid: uid,
            gid: gid,
            proxy_ip: ip,
            image: @image,
            egress: egress,
            read_only: read_only
          })

        for ["-e", value] <- Enum.chunk_every(args, 2, 1), do: assert(value =~ "=")

        # Docker keeps no log a sandbox can fill (review round 2: Astra).
        assert ["--log-driver", "none"] in Enum.chunk_every(args, 2, 1)
        refute "--log-opt" in args

        assert for(["-v", mount] <- Enum.chunk_every(args, 2, 1), do: mount) ==
                 ["/c/#{name}:/work", "/h/#{name}:/opt/home"]

        refute Enum.any?(args, &(&1 in ["--volume", "--mount", "--volumes-from", "--device"]))

        for flag <- ~w(--env-file --privileged --pid --ipc --cap-add --userns --add-host) do
          refute Enum.any?(args, &(&1 == flag or String.starts_with?(&1, flag <> "="))), flag
        end

        for forbidden <- ["docker.sock", "host-gateway", "host.docker.internal"] do
          refute Enum.any?(args, &String.contains?(&1, forbidden)), forbidden
        end

        refute "host" in args
      end
    end
  end

  describe "run_args/1 with :read_only (TEST)" do
    defp test_args(read_only) do
      %{
        name: "s",
        network: "n",
        copy_dir: "/c",
        home_dir: "/h",
        uid: 1,
        gid: 1,
        proxy_ip: nil,
        image: @image,
        egress: :none
      }
      |> Map.merge(if read_only == :unset, do: %{}, else: %{read_only: read_only})
      |> Sandbox.run_args()
    end

    test "makes the root filesystem read-only, pins /dev/shm at 64 MiB and keeps the /tmp tmpfs" do
      args = test_args(true)

      assert "--read-only" in args
      assert ["--shm-size", "64m"] in Enum.chunk_every(args, 2, 1)
      assert ["--tmpfs", "/tmp:exec,size=1g"] in Enum.chunk_every(args, 2, 1)
    end

    test "leaves BUILD's argv as it was" do
      assert test_args(false) == test_args(:unset)
      refute "--read-only" in test_args(false)
      refute "--shm-size" in test_args(false)
    end
  end

  describe "make_home/2" do
    test "makes a fresh 0700 directory the host's user owns, under RUNNER_TEMP/rsolv",
         %{tmp_dir: dir} do
      assert {:ok, home} = Sandbox.make_home(dir, "rsolv-41-7-verify-red-build")
      assert home == Path.join([dir, "rsolv", "home-rsolv-41-7-verify-red-build"])

      assert %{type: :directory, uid: uid, mode: mode} = File.stat!(home)
      assert uid == File.stat!(dir).uid
      assert Bitwise.band(mode, 0o777) == 0o700
    end

    test "refuses a directory that's already there, and leaves it alone", %{tmp_dir: dir} do
      home = Path.join([dir, "rsolv", "home-x"])
      File.mkdir_p!(home)
      File.chmod!(home, 0o755)

      assert Sandbox.make_home(dir, "x") == {:error, :exists}
      assert Bitwise.band(File.stat!(home).mode, 0o777) == 0o755
    end
  end

  describe "start/1 with :home_dir and :read_only" do
    test "mounts a HOME it was given, measures it, and never removes it", %{tmp_dir: dir} do
      FakeExec.script([gone()])
      {:ok, home} = Sandbox.make_home(dir, "given")

      assert {:ok, sbx} = Sandbox.start(start_opts(dir, egress: :none, home_dir: home))
      assert (home <> ":/opt/home") in List.last(docker_args())
      refute File.exists?(Path.join([dir, "rsolv", "home-rsolv-41-7-work"]))
      assert sbx.home == home

      assert Sandbox.stop_confirmed(sbx) == :ok
      assert File.dir?(home)
    end

    test "passes :read_only to the sandbox's run", %{tmp_dir: dir} do
      FakeExec.script([])

      {:ok, _sbx} = Sandbox.start(start_opts(dir, egress: :none, read_only: true))

      assert "--read-only" in List.last(docker_args())
    end
  end

  describe "start/1" do
    test "creates the internal network, the proxy, then the sandbox, in order", %{tmp_dir: dir} do
      script_inspect()
      opts = start_opts(dir)
      %{uid: uid, gid: gid} = File.stat!(opts[:copy_dir])

      assert {:ok, sbx} = Sandbox.start(opts)
      assert sbx.container == "rsolv-41-7-work"

      proxy_dir = Path.join([dir, "rsolv", "proxy-rsolv-41-7-work"])

      assert [
               ["network", "create", "--internal", "rsolv-41-7-net"],
               [
                 "run",
                 "-d",
                 "--name",
                 "rsolv-41-7-work-proxy",
                 "--log-driver",
                 "none",
                 "-v",
                 conf_mount,
                 "-v",
                 list_mount,
                 _proxy
               ],
               ["network", "connect", "rsolv-41-7-net", "rsolv-41-7-work-proxy"],
               ["inspect", "-f", _net_ip, "rsolv-41-7-work-proxy"],
               ["inspect", "-f", _bridge_ip, "rsolv-41-7-work-proxy"],
               ["run", "-d", "--name", "rsolv-41-7-work" | run_rest]
             ] = docker_args()

      assert conf_mount == Path.join(proxy_dir, "squid.conf") <> ":/etc/squid/squid.conf:ro"
      assert list_mount == Path.join(proxy_dir, "allowlist.txt") <> ":/etc/squid/allowlist.txt:ro"
      assert File.read!(Path.join(proxy_dir, "allowlist.txt")) == RsolvHost.Egress.allowlist()
      assert "#{uid}:#{gid}" in run_rest
      assert "HTTPS_PROXY=http://172.18.0.2:3128" in run_rest
    end

    test "refuses to run the sandbox as root, before any docker call", %{tmp_dir: dir} do
      FakeExec.script([])

      for {uid, gid} <- [{0, 0}, {0, 118}, {1001, 0}] do
        stat = fn _path -> %{uid: uid, gid: gid} end

        assert Sandbox.start(start_opts(dir, stat: stat, name: "r#{uid}-#{gid}")) ==
                 {:error, {:sandbox_setup, :root_user}}
      end

      assert docker_args() |> Enum.filter(&match?(["run" | _], &1)) == []
    end

    test "refuses a copy the host's own user doesn't own", %{tmp_dir: dir} do
      FakeExec.script([])
      %{uid: me, gid: gid} = File.stat!(dir)
      stat = fn _path -> %{uid: me + 1, gid: gid} end

      assert Sandbox.start(start_opts(dir, stat: stat)) == {:error, {:sandbox_setup, :copy_owner}}
      assert docker_args() |> Enum.filter(&match?(["run" | _], &1)) == []
    end

    test "with no egress, starts only the sandbox, with no network", %{tmp_dir: dir} do
      FakeExec.script([])

      assert {:ok, _sbx} = Sandbox.start(start_opts(dir, egress: :none))

      assert [["run", "-d", "--name", "rsolv-41-7-work", "--network", "none" | _]] = docker_args()
    end

    test "when a step fails, names it and removes, by ID, what it created", %{tmp_dir: dir} do
      FakeExec.script([
        {fn {"docker", ["network", "connect" | _], _} -> true end,
         {:ok, %{status: 1, output: "x"}}}
      ])

      assert Sandbox.start(start_opts(dir)) == {:error, {:sandbox_setup, :proxy_connect}}

      assert Enum.take(docker_args(), -2) == [
               ["rm", "-f", FakeExec.docker_id("rsolv-41-7-work-proxy")],
               ["network", "rm", FakeExec.docker_id("rsolv-41-7-net")]
             ]
    end

    test "a step the deadline stops is session_timeout, and removes what it created",
         %{tmp_dir: dir} do
      FakeExec.script([
        {fn {"docker", ["run", "-d", "--name", "rsolv-41-7-work-proxy" | _], opts} ->
           Process.sleep(opts[:timeout_ms])
           true
         end, {:error, :timeout}}
      ])

      deadline = System.monotonic_time(:millisecond) + 200

      assert Sandbox.start(start_opts(dir, deadline: deadline)) == {:error, :session_timeout}

      assert List.last(docker_args()) == ["network", "rm", FakeExec.docker_id("rsolv-41-7-net")]
    end

    test "a step stopped by its own limit, with the deadline still ahead, is the step's failure",
         %{tmp_dir: dir} do
      FakeExec.script([
        {fn {"docker", ["network", "create" | _], _} -> true end, {:error, :timeout}}
      ])

      deadline = System.monotonic_time(:millisecond) + 3_600_000

      assert Sandbox.start(start_opts(dir, deadline: deadline)) ==
               {:error, {:sandbox_setup, :network_create}}
    end

    test "refuses a container Docker gave no ID", %{tmp_dir: dir} do
      FakeExec.script([
        {fn {"docker", ["run", "-d", "--name", "rsolv-41-7-work" | _], _} -> true end,
         {:ok, %{status: 0, output: "Status: Downloaded newer image\n"}}}
      ])

      assert Sandbox.start(start_opts(dir) ++ [egress: :none]) ==
               {:error, {:sandbox_setup, :sandbox_run}}
    end

    test "when the proxy never answers, fails closed before any sandbox runs", %{tmp_dir: dir} do
      script_inspect()

      assert Sandbox.start(start_opts(dir, probe: fn _ip -> :error end)) ==
               {:error, {:sandbox_setup, :proxy_ready}}

      refute Enum.any?(docker_args(), &match?(["run", "-d", "--name", "rsolv-41-7-work" | _], &1))
    end

    test "when docker is missing, it's a sandbox failure", %{tmp_dir: dir} do
      FakeExec.script([{fn _ -> true end, {:error, :enoent}}])

      assert Sandbox.start(start_opts(dir)) == {:error, {:sandbox, :enoent}}
    end

    test "refuses an unpinned sandbox image", %{tmp_dir: dir} do
      FakeExec.script([])
      unpinned = "ghcr.io/rsolv-dev/rsolv-sandbox@sha256:" <> String.duplicate("0", 64)

      assert Sandbox.start(start_opts(dir, image: unpinned)) == {:error, :sandbox_image_unpinned}
      assert FakeExec.calls() == []
    end
  end

  describe "start/1 and the sandbox home" do
    test "is a fresh 0700 directory the copy's owner owns, outside the copy", %{tmp_dir: dir} do
      script_inspect()
      opts = start_opts(dir)

      {:ok, _sbx} = Sandbox.start(opts)
      home = Path.join([dir, "rsolv", "home-rsolv-41-7-work"])

      assert %{type: :directory, uid: uid, mode: mode} = File.stat!(home)
      assert uid == File.stat!(opts[:copy_dir]).uid
      assert Bitwise.band(mode, 0o777) == 0o700
      assert (home <> ":/opt/home") in List.last(docker_args())
    end
  end

  # `df -B1 --output=used,iused` for the copy's filesystem.
  defp df(bytes, inodes), do: ok("   Used  IUsed\n#{bytes} #{inodes}\n")
  defp df_rule(bytes, inodes), do: {fn {"df", _, _} -> true end, df(bytes, inodes)}

  describe "disk_used/1" do
    setup %{tmp_dir: dir} do
      %{
        sbx: %Sandbox{
          container: "s",
          copy_dir: Path.join(dir, "c"),
          home: Path.join(dir, "h"),
          exec: FakeExec
        }
      }
    end

    test "is du's total, and the used bytes and inodes of the copy's filesystem by df",
         %{sbx: sbx} do
      FakeExec.script([
        {fn {"du", _, _} -> true end, ok("10\t/c\n5\t/h\n15\ttotal\n")},
        df_rule(7_000, 42)
      ])

      assert Sandbox.disk_used(sbx) == {:ok, %{du: 15, fs: 7_000, inodes: 42}}

      assert {"df", ["-B1", "--output=used,iused", "--", copy], opts} =
               Enum.find(FakeExec.calls(), &match?({"df", _, _}, &1))

      assert copy == sbx.copy_dir and opts[:timeout_ms] <= 30_000
    end

    test "runs du and df in the C locale, whose messages it reads", %{sbx: sbx} do
      FakeExec.script([{fn {"du", _, _} -> true end, ok("15\ttotal\n")}, df_rule(1, 1)])

      Sandbox.disk_used(sbx)

      for {exe, _args, opts} <- FakeExec.calls(),
          exe in ["du", "df"],
          do: assert(opts[:env] == [{"LC_ALL", "C"}], exe)

      assert length(FakeExec.calls()) == 2
    end

    test "is no measure when du couldn't read everything, whatever total it printed", %{sbx: sbx} do
      FakeExec.script([
        {fn {"du", _, _} -> true end,
         {:ok,
          %{status: 1, output: "du: cannot read directory '/c/d': Permission denied\n15\ttotal\n"}}},
        df_rule(1, 1)
      ])

      assert Sandbox.disk_used(sbx) == :error
    end

    # What du 9.4 (Ubuntu 24.04, GitHub's runners) prints when an install
    # removes files and directories mid-walk: exit 1, though nothing it
    # couldn't read still exists (du 9.12 skips them silently). Seen as
    # intermittent disk_limit on Ruby installs in CI (runs 44539120019,
    # 44465085037, 44234905859).
    test "is du's total when what it couldn't read had only vanished mid-walk", %{sbx: sbx} do
      FakeExec.script([
        {fn {"du", _, _} -> true end,
         {:ok,
          %{
            status: 1,
            output:
              "du: cannot access '/h/.gem/tmp/f21': No such file or directory\n" <>
                "du: cannot read directory '/h/.gem/ext': No such file or directory\n" <>
                "10\t/c\n5\t/h\n15\ttotal\n"
          }}},
        df_rule(7_000, 42)
      ])

      assert Sandbox.disk_used(sbx) == {:ok, %{du: 15, fs: 7_000, inodes: 42}}
    end

    test "is no measure when anything else stopped du, alongside a vanished file", %{sbx: sbx} do
      FakeExec.script([
        {fn {"du", _, _} -> true end,
         {:ok,
          %{
            status: 1,
            output:
              "du: cannot access '/h/x': No such file or directory\n" <>
                "du: cannot read directory '/c/d': Permission denied\n15\ttotal\n"
          }}},
        df_rule(1, 1)
      ])

      assert Sandbox.disk_used(sbx) == :error
    end

    for {label, answer} <- [
          {"fails", {:ok, %{status: 1, output: "df: /c: No such file\n"}}},
          {"prints no numbers", {:ok, %{status: 0, output: "   Used  IUsed\n- -\n"}}}
        ] do
      test "is no measure when df #{label}", %{sbx: sbx} do
        FakeExec.script([
          {fn {"du", _, _} -> true end, ok("15\ttotal\n")},
          {fn {"df", _, _} -> true end, unquote(Macro.escape(answer))}
        ])

        assert Sandbox.disk_used(sbx) == :error
      end
    end
  end

  describe "watched/4" do
    setup %{tmp_dir: dir} do
      %{
        sbx: %Sandbox{
          container: "s",
          copy_dir: Path.join(dir, "c"),
          home: Path.join(dir, "h"),
          ids: %{sandbox: "i"},
          exec: FakeExec
        }
      }
    end

    @limits %{du: 100, fs: 1_000, inodes: 10}

    test "measures once more when the step ends, before any poll, and refuses a total over budget",
         %{sbx: sbx} do
      FakeExec.script([{fn {"du", _, _} -> true end, ok("101\ttotal\n")}, df_rule(0, 0)])

      assert Sandbox.watched(sbx, @limits, 60_000, fn -> :done end) == {:error, :disk_limit}
    end

    test "refuses the copy's filesystem past its bytes, though du is within: a file unlinked while open (review round 2: Kimi)",
         %{sbx: sbx} do
      FakeExec.script([{fn {"du", _, _} -> true end, ok("1\ttotal\n")}, df_rule(1_001, 0)])

      assert Sandbox.watched(sbx, @limits, 60_000, fn -> :done end) == {:error, :disk_limit}
    end

    test "refuses the copy's filesystem past its inodes (review round 2: Kimi)", %{sbx: sbx} do
      FakeExec.script([{fn {"du", _, _} -> true end, ok("1\ttotal\n")}, df_rule(0, 11)])

      assert Sandbox.watched(sbx, @limits, 60_000, fn -> :done end) == {:error, :disk_limit}
    end

    test "waits for a measure in flight when the step ends", %{sbx: sbx} do
      FakeExec.script([
        {fn {"du", _, _} -> true end,
         fn _call ->
           Process.sleep(300)
           ok("101\ttotal\n")
         end},
        df_rule(0, 0)
      ])

      assert Sandbox.watched(sbx, @limits, 10, fn -> Process.sleep(50) end) ==
               {:error, :disk_limit}
    end

    test "keeps the step's result within budget", %{sbx: sbx} do
      FakeExec.script([{fn {"du", _, _} -> true end, ok("100\ttotal\n")}, df_rule(1_000, 10)])

      assert Sandbox.watched(sbx, @limits, 60_000, fn -> :done end) == :done
    end
  end

  describe "exec/3" do
    test "runs the argv under coreutils timeout, with a host deadline beyond it", %{tmp_dir: dir} do
      script_inspect()
      {:ok, sbx} = Sandbox.start(start_opts(dir))

      Sandbox.exec(sbx, ["rsolv-sandbox", "tool"], input: "0\n", timeout_ms: 90_000, max_bytes: 8)

      assert {"docker",
              [
                "exec",
                "-i",
                "rsolv-41-7-work",
                "timeout",
                "-k",
                "10",
                "90",
                "rsolv-sandbox",
                "tool"
              ], opts} =
               List.last(FakeExec.calls())

      assert opts[:timeout_ms] == 120_000
      assert opts[:input] == "0\n"
      assert opts[:max_bytes] == 8
    end

    test "sets :env as -e values on the exec, before the container", %{tmp_dir: dir} do
      script_inspect()
      {:ok, sbx} = Sandbox.start(start_opts(dir))

      Sandbox.exec(sbx, ["true"],
        timeout_ms: 5_000,
        env: %{"RAILS_ENV" => "test", "MIX_ENV" => "test"}
      )

      assert {"docker",
              ["exec", "-i", "-e", "MIX_ENV=test", "-e", "RAILS_ENV=test", "rsolv-41-7-work" | _],
              opts} = List.last(FakeExec.calls())

      refute Keyword.has_key?(opts, :env)
    end

    test "never asks coreutils for a zero timeout, which would mean none", %{tmp_dir: dir} do
      script_inspect()
      {:ok, sbx} = Sandbox.start(start_opts(dir))

      Sandbox.exec(sbx, ["true"], timeout_ms: 500)

      assert {"docker", ["exec", "-i", _, "timeout", "-k", "10", "1", "true"], _} =
               List.last(FakeExec.calls())
    end
  end

  describe "disconnect/1 and stop/1" do
    test "disconnect removes the sandbox from the proxy's network", %{tmp_dir: dir} do
      script_inspect()
      {:ok, sbx} = Sandbox.start(start_opts(dir))

      Sandbox.disconnect(sbx)

      assert List.last(docker_args()) == [
               "network",
               "disconnect",
               "rsolv-41-7-net",
               "rsolv-41-7-work"
             ]
    end

    test "stop removes both containers, then the network, by the IDs Docker gave them",
         %{tmp_dir: dir} do
      script_inspect()
      {:ok, sbx} = Sandbox.start(start_opts(dir))

      assert Sandbox.stop(sbx) == :ok

      assert Enum.take(docker_args(), -2) == [
               [
                 "rm",
                 "-f",
                 FakeExec.docker_id("rsolv-41-7-work"),
                 FakeExec.docker_id("rsolv-41-7-work-proxy")
               ],
               ["network", "rm", FakeExec.docker_id("rsolv-41-7-net")]
             ]
    end

    test "stop is a no-op when nothing started" do
      assert Sandbox.stop(nil) == :ok
    end
  end

  # `docker inspect` answering that each container it's asked about is gone.
  defp gone do
    {fn {"docker", ["inspect", "--type", "container" | _], _} -> true end,
     fn {"docker", args, _} ->
       {:ok,
        %{
          status: 1,
          output: "Error response from daemon: No such container: #{List.last(args)}\n"
        }}
     end}
  end

  describe "start/1 with confirm: true, when setup fails" do
    test "answers the step once Docker says no container by either name is left", %{tmp_dir: dir} do
      FakeExec.script(
        [
          {fn {"docker", ["network", "connect" | _], _} -> true end,
           {:ok, %{status: 1, output: ""}}},
          gone()
        ] ++ inspect_rules()
      )

      assert Sandbox.start(start_opts(dir, confirm: true)) ==
               {:error, {:sandbox_setup, :proxy_connect}}

      assert ["rsolv-41-7-work", "rsolv-41-7-work-proxy"] ==
               for(["inspect", "--type", "container", _, _, name] <- docker_args(), do: name)
    end

    test "is a teardown error when a container by its name is still there", %{tmp_dir: dir} do
      FakeExec.script([
        {fn {"docker", ["run", "-d", "--name", "rsolv-41-7-work" | _], _} -> true end,
         {:error, :timeout}},
        {fn {"docker", ["inspect", "--type", "container" | _], _} -> true end,
         {:ok, %{status: 0, output: "abc\n"}}}
      ])

      assert Sandbox.start(start_opts(dir, egress: :none, confirm: true)) ==
               {:error, {:sandbox, :teardown}}
    end
  end

  describe "stop_confirmed/1" do
    defp owned(dir),
      do: Enum.map(["home-", "proxy-"], &Path.join([dir, "rsolv", &1 <> "rsolv-41-7-work"]))

    test "is :ok only once rm -f exits 0 and Docker says each container is gone, then removes its directories",
         %{tmp_dir: dir} do
      FakeExec.script([gone()] ++ inspect_rules())
      {:ok, sbx} = Sandbox.start(start_opts(dir))

      assert Sandbox.stop_confirmed(sbx) == :ok

      sandbox = FakeExec.docker_id("rsolv-41-7-work")
      proxy = FakeExec.docker_id("rsolv-41-7-work-proxy")

      assert Enum.take(docker_args(), -4) == [
               ["rm", "-f", sandbox, proxy],
               ["inspect", "--type", "container", "--format", "{{.Id}}", sandbox],
               ["inspect", "--type", "container", "--format", "{{.Id}}", proxy],
               ["network", "rm", FakeExec.docker_id("rsolv-41-7-net")]
             ]

      for owned <- owned(dir), do: refute(File.exists?(owned))
    end

    test "accepts docker's no-such-object answer", %{tmp_dir: dir} do
      FakeExec.script(
        [
          {fn {"docker", ["inspect", "--type", "container" | _], _} -> true end,
           fn {"docker", args, _} ->
             {:ok, %{status: 1, output: "error: no such object: #{List.last(args)}\n"}}
           end}
        ] ++ inspect_rules()
      )

      {:ok, sbx} = Sandbox.start(start_opts(dir, egress: :none))

      assert Sandbox.stop_confirmed(sbx) == :ok
    end

    for {label, rule} <- [
          {"rm -f exits 1",
           quote(
             do: {fn {"docker", ["rm", "-f" | _], _} -> true end, {:ok, %{status: 1, output: ""}}}
           )},
          {"rm -f times out",
           quote(do: {fn {"docker", ["rm", "-f" | _], _} -> true end, {:error, :timeout}})},
          {"inspect finds the container",
           quote(
             do:
               {fn {"docker", ["inspect", "--type", "container" | _], _} -> true end,
                {:ok, %{status: 0, output: "abc\n"}}}
           )},
          {"inspect exits 0, whatever it prints",
           quote(
             do:
               {fn {"docker", ["inspect", "--type", "container" | _], _} -> true end,
                fn {"docker", args, _} ->
                  {:ok,
                   %{
                     status: 0,
                     output: "Error response from daemon: No such container: #{List.last(args)}"
                   }}
                end}
           )},
          {"inspect times out",
           quote(
             do:
               {fn {"docker", ["inspect", "--type", "container" | _], _} -> true end,
                {:error, :timeout}}
           )},
          {"inspect fails some other way",
           quote(
             do:
               {fn {"docker", ["inspect", "--type", "container" | _], _} -> true end,
                {:ok,
                 %{status: 1, output: "Cannot connect to the Docker daemon. Is it running?\n"}}}
           )},
          {"inspect names another container",
           quote(
             do:
               {fn {"docker", ["inspect", "--type", "container" | _], _} -> true end,
                {:ok, %{status: 1, output: "Error response from daemon: No such container: x\n"}}}
           )}
        ] do
      test "is :error, and removes no directory, when #{label}", %{tmp_dir: dir} do
        FakeExec.script([unquote(rule), gone()] ++ inspect_rules())
        {:ok, sbx} = Sandbox.start(start_opts(dir))

        assert Sandbox.stop_confirmed(sbx) == :error
        for owned <- owned(dir), do: assert(File.dir?(owned))
      end
    end

    test "is :error, and removes no directory, for a sandbox whose container ID it never recorded",
         %{tmp_dir: dir} do
      home = Path.join(dir, "h")
      File.mkdir_p!(home)
      FakeExec.script([gone()])

      sbx = %Sandbox{container: "s", home: home, dirs: [home], ids: %{}, exec: FakeExec}

      assert Sandbox.stop_confirmed(sbx) == :error
      assert File.dir?(home)
    end

    test "gives each docker call at most what's left before its deadline, and none past it",
         %{tmp_dir: dir} do
      FakeExec.script([gone()] ++ inspect_rules())
      {:ok, sbx} = Sandbox.start(start_opts(dir))

      deadline = System.monotonic_time(:millisecond) + 5_000
      assert Sandbox.stop_confirmed(sbx, :stdio, deadline) == :ok

      limits =
        for {"docker", args, opts} <- FakeExec.calls(),
            match?(["rm" | _], args) or match?(["inspect", "--type" | _], args),
            do: opts[:timeout_ms]

      assert length(limits) == 3 and Enum.all?(limits, &(&1 <= 5_000))

      past = System.monotonic_time(:millisecond) - 1
      assert Sandbox.stop_confirmed(sbx, :stdio, past) == :error
    end

    test "never inspects past a failed rm", %{tmp_dir: dir} do
      FakeExec.script(
        [{fn {"docker", ["rm", "-f" | _], _} -> true end, {:ok, %{status: 1, output: ""}}}] ++
          inspect_rules()
      )

      {:ok, sbx} = Sandbox.start(start_opts(dir))
      Sandbox.stop_confirmed(sbx)

      refute Enum.any?(docker_args(), &match?(["inspect", "--type" | _], &1))
    end
  end

  describe "stop_confirmed/1 of nothing" do
    test "is :ok when nothing started" do
      assert Sandbox.stop_confirmed(nil) == :ok
    end
  end
end
