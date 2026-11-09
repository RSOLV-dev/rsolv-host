defmodule RsolvHost.SandboxDockerTest do
  # The host's own environment is changed, so this module runs alone.
  use ExUnit.Case, async: false

  alias RsolvHost.{Exec, Sandbox}

  @moduletag :docker
  @moduletag :tmp_dir
  @moduletag timeout: 600_000
  @probe_image "buildpack-deps:bookworm-curl@sha256:f5c5d07ea24ee91272739fe451c280aa4b7fa5120b9278815db5fcd713d83772"
  @elixir_image "elixir:1.19@sha256:7e27df3e4a684163e4a18e618eede53badb70e97e0c92a1845ab22e2e1d96da2"
  @composer_image "composer:2.11.1@sha256:8de2184c6de224f4689e8f80ed5f5edaf0030b6b8b7839a22a2bcb6722ac87d0"
  @runner_secrets %{
    "GITHUB_TOKEN" => "ghs_fake",
    "ACTIONS_RUNTIME_TOKEN" => "fake",
    "RSOLV_API_URL" => "x"
  }

  setup %{tmp_dir: dir} = context do
    System.put_env(@runner_secrets)
    on_exit(fn -> Enum.each(Map.keys(@runner_secrets), &System.delete_env/1) end)

    copy = Path.join(dir, "work")
    File.mkdir_p!(copy)
    name = "rsolv-test-#{System.unique_integer([:positive])}"

    {:ok, sbx} =
      Sandbox.start(
        name: name,
        network: name <> "-net",
        copy_dir: copy,
        runner_temp: dir,
        image: Map.get(context, :image, @probe_image),
        exec: Exec
      )

    on_exit(fn -> Sandbox.stop(sbx) end)

    %{
      sbx: sbx,
      copy: copy,
      allowlist: Path.join([dir, "rsolv", "proxy-" <> name, "allowlist.txt"])
    }
  end

  defp run(sbx, argv, timeout_ms \\ 30_000) do
    {:ok, result} = Sandbox.exec(sbx, argv, timeout_ms: timeout_ms)
    result
  end

  @loopback_listener ~S"""
  perl -MIO::Socket::INET -e '
    $s = IO::Socket::INET->new(LocalAddr => "127.0.0.1", LocalPort => 8080, Listen => 5, ReuseAddr => 1) or die;
    while ($c = $s->accept) { print $c "HTTP/1.0 200 OK\r\n\r\nloopback"; close $c }
  ' >/dev/null 2>&1 &
  sleep 1
  """

  describe "a started sandbox" do
    test "holds none of the runner's secrets", %{sbx: sbx} do
      names =
        for line <- String.split(run(sbx, ["env"]).output, "\n"),
            [name | _] = String.split(line, "="),
            do: name

      refute Enum.any?(names, &String.starts_with?(&1, ["GITHUB_TOKEN", "ACTIONS_", "RSOLV_"]))
    end

    test "runs as the copy's owner, without the Docker socket", %{sbx: sbx} do
      refute run(sbx, ["id", "-u"]).output == "0\n"
      assert %{status: status} = run(sbx, ["test", "-e", "/var/run/docker.sock"])
      assert status != 0
    end

    test "can't reach the internet or resolve names directly", %{sbx: sbx} do
      assert run(sbx, ["curl", "-sS", "-m", "5", "--noproxy", "*", "https://example.com"]).status !=
               0

      assert run(sbx, ["curl", "-sS", "-m", "5", "--noproxy", "*", "https://1.1.1.1"]).status != 0
      assert run(sbx, ["getent", "hosts", "example.com"]).status != 0
    end

    test "reaches allowlisted hosts through the proxy, and nothing else", %{sbx: sbx} do
      code = ["curl", "-s", "-m", "20", "-o", "/dev/null", "-w"]

      assert run(sbx, code ++ ["%{http_code}", "https://api.github.com/zen"]).output == "200"
      assert run(sbx, code ++ ["%{http_connect}", "https://example.com"]).output == "403"
      assert run(sbx, code ++ ["%{http_connect}", "https://1.1.1.1"]).output == "403"
    end

    test "can't use an allowlisted host's other ports, by plain HTTP or CONNECT", %{sbx: sbx} do
      code = ["curl", "-s", "-m", "20", "-o", "/dev/null", "-w"]

      assert run(sbx, code ++ ["%{http_code}", "http://github.com/"]).output == "403"
      assert run(sbx, code ++ ["%{http_code}", "http://github.com:8080/"]).output == "403"
      assert run(sbx, code ++ ["%{http_connect}", "https://github.com:8443/"]).output == "403"
    end

    test "reaches its own loopback directly, and everything else only through the proxy", %{
      sbx: sbx
    } do
      code = "curl -s -m 10 -o /dev/null -w '%{http_code} '"

      script =
        @loopback_listener <>
          Enum.map_join(
            ~w(http://127.0.0.1:8080/ http://localhost:8080/ http://example.com/ http://1.1.1.1/),
            "\n",
            &"#{code} #{&1}"
          )

      # 200 = direct to loopback; 403 = squid answered, so the request went
      # through the proxy rather than straight out.
      assert run(sbx, ["sh", "-c", script]).output == "200 200 403 403 "
    end

    test "can't fill its /tmp past 1 GiB, nor use more than 4 GiB of memory and 2 CPUs", %{
      sbx: sbx
    } do
      %{output: output} =
        run(sbx, ["sh", "-c", "head -c 2G /dev/zero > /tmp/fill; du -m /tmp/fill"], 120_000)

      assert output =~ "No space left on device"
      assert [_, megabytes] = Regex.run(~r/^(\d+)\s+\/tmp\/fill$/m, output)
      assert String.to_integer(megabytes) <= 1024

      {limits, 0} =
        System.cmd("docker", [
          "inspect",
          "-f",
          "{{.HostConfig.Memory}} {{.HostConfig.MemorySwap}} {{.HostConfig.NanoCpus}}",
          sbx.container
        ])

      assert limits == "4294967296 4294967296 2000000000\n"
    end

    test "is killed once its copy and home pass their disk budget, which ends the step as disk_limit",
         %{sbx: sbx} do
      {:ok, used} = Sandbox.disk_used(sbx)
      started = System.monotonic_time(:millisecond)

      result =
        Sandbox.watched(sbx, used + 50 * 1024 * 1024, 500, fn ->
          Sandbox.exec(
            sbx,
            [
              "sh",
              "-c",
              "head -c 300M /dev/zero > /work/big; head -c 300M /dev/zero > /opt/home/big; sleep 60"
            ],
            timeout_ms: 90_000
          )
        end)

      assert result == {:error, :disk_limit}
      assert System.monotonic_time(:millisecond) - started < 30_000

      {running, 0} =
        System.cmd("docker", ["inspect", "-f", "{{.State.Running}}", sbx.ids.sandbox])

      assert running == "false\n"
    end

    test "has no network at all once disconnected", %{sbx: sbx} do
      assert Sandbox.disconnect(sbx) == :ok
      assert run(sbx, ["curl", "-sS", "-m", "5", "https://api.github.com/zen"]).status != 0
    end
  end

  describe "a sandbox with Elixir" do
    @describetag image: @elixir_image

    test "installs a Hex dependency through the proxy", %{sbx: sbx, copy: copy} do
      File.write!(Path.join(copy, "mix.exs"), """
      defmodule Probe.MixProject do
        use Mix.Project
        def project, do: [app: :probe, version: "0.1.0", deps: [{:jason, "1.4.4"}]]
      end
      """)

      assert %{status: 0} = run(sbx, ["mix", "local.hex", "--force"], 120_000)
      assert %{status: 0} = run(sbx, ["mix", "deps.get"], 120_000)
      assert File.exists?(Path.join([copy, "deps", "jason", "mix.exs"]))
    end
  end

  describe "a sandbox with PHP and Composer" do
    @describetag image: @composer_image

    setup %{copy: copy} do
      File.write!(Path.join(copy, "composer.json"), ~s({"require": {"psr/log": "3.0.2"}}))
      :ok
    end

    test "installs a Packagist dependency through the proxy", %{sbx: sbx, copy: copy} do
      assert %{status: 0} = run(sbx, ["composer", "install", "--no-interaction"], 120_000)
      assert File.exists?(Path.join([copy, "vendor", "psr", "log", "src", "LoggerInterface.php"]))
    end

    test "gets 403 for Packagist's metadata once repo.packagist.org leaves the allowlist", %{
      sbx: sbx,
      copy: copy,
      allowlist: allowlist
    } do
      without_metadata =
        allowlist |> File.read!() |> String.replace("repo.packagist.org\n", "")

      File.write!(allowlist, without_metadata)

      {_out, 0} =
        System.cmd("docker", ["exec", sbx.proxy, "squid", "-k", "reconfigure"],
          stderr_to_stdout: true
        )

      assert eventually_denied(sbx, "https://repo.packagist.org/packages.json")

      assert %{status: status, output: output} =
               run(sbx, ["composer", "install", "--no-interaction"], 120_000)

      assert status != 0
      assert output =~ "403"
      refute File.exists?(Path.join(copy, "vendor"))
    end
  end

  defp eventually_denied(sbx, url, tries \\ 20)
  defp eventually_denied(_sbx, _url, 0), do: false

  defp eventually_denied(sbx, url, tries) do
    code = run(sbx, ["curl", "-s", "-m", "10", "-o", "/dev/null", "-w", "%{http_connect}", url])

    code.output == "403" or
      (Process.sleep(500) && eventually_denied(sbx, url, tries - 1))
  end
end
