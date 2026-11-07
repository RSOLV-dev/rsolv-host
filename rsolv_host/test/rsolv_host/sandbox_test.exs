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
                 [
                   "--user",
                   "1001:118",
                   "--cap-drop",
                   "ALL",
                   "--security-opt",
                   "no-new-privileges"
                 ] ++
                 ["--pids-limit", "4096", "--tmpfs", "/tmp:exec"] ++
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
                 ["-e", "NO_PROXY=", "-v", "/rt/rsolv/work:/work"] ++
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
              ip <- member_of(["172.18.0.2", "10.0.0.9"])
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
            egress: egress
          })

        for ["-e", value] <- Enum.chunk_every(args, 2, 1), do: assert(value =~ "=")

        for forbidden <- ["--env-file", "--privileged", "/var/run/docker.sock", "host"] do
          refute Enum.any?(args, &String.contains?(&1, forbidden)), forbidden
        end
      end
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

    test "when a step fails, names it and removes what it created", %{tmp_dir: dir} do
      FakeExec.script([
        {fn {"docker", ["network", "connect" | _], _} -> true end,
         {:ok, %{status: 1, output: "x"}}}
      ])

      assert Sandbox.start(start_opts(dir)) == {:error, {:sandbox_setup, :proxy_connect}}

      assert Enum.take(docker_args(), -2) == [
               ["rm", "-f", "rsolv-41-7-work", "rsolv-41-7-work-proxy"],
               ["network", "rm", "rsolv-41-7-net"]
             ]
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

    test "stop removes both containers, then the network", %{tmp_dir: dir} do
      script_inspect()
      {:ok, sbx} = Sandbox.start(start_opts(dir))

      assert Sandbox.stop(sbx) == :ok

      assert Enum.take(docker_args(), -2) == [
               ["rm", "-f", "rsolv-41-7-work", "rsolv-41-7-work-proxy"],
               ["network", "rm", "rsolv-41-7-net"]
             ]
    end

    test "stop is a no-op when nothing started" do
      assert Sandbox.stop(nil) == :ok
    end
  end
end
