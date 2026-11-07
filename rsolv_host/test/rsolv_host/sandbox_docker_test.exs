defmodule RsolvHost.SandboxDockerTest do
  # The host's own environment is changed, so this module runs alone.
  use ExUnit.Case, async: false

  alias RsolvHost.{Exec, Sandbox}

  @moduletag :docker
  @moduletag :tmp_dir
  @moduletag timeout: 600_000
  @probe_image "buildpack-deps:bookworm-curl@sha256:f5c5d07ea24ee91272739fe451c280aa4b7fa5120b9278815db5fcd713d83772"
  @runner_secrets %{
    "GITHUB_TOKEN" => "ghs_fake",
    "ACTIONS_RUNTIME_TOKEN" => "fake",
    "RSOLV_API_URL" => "x"
  }

  setup %{tmp_dir: dir} do
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
        image: @probe_image,
        exec: Exec
      )

    on_exit(fn -> Sandbox.stop(sbx) end)
    %{sbx: sbx}
  end

  defp run(sbx, argv) do
    {:ok, result} = Sandbox.exec(sbx, argv, timeout_ms: 30_000)
    result
  end

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

    test "has no network at all once disconnected", %{sbx: sbx} do
      assert Sandbox.disconnect(sbx) == :ok
      assert run(sbx, ["curl", "-sS", "-m", "5", "https://api.github.com/zen"]).status != 0
    end
  end
end
