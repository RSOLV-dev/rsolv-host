defmodule RsolvHost.Roles.VerifyDockerTest do
  # Containment of the verify role's copies, on a real Docker (RFC-150
  # acceptance 5a, 5b). The shell scripts stand in for hostile test code
  # inside the sandbox; trusted code never runs one.
  use ExUnit.Case, async: false

  alias RsolvCore.ChangeSet.Entry
  alias RsolvHost.{BaseFactsReader, Copies, Exec, Sandbox, Workspace}

  @moduletag :docker
  @moduletag :tmp_dir
  @moduletag timeout: 600_000
  @image "buildpack-deps:bookworm-curl@sha256:f5c5d07ea24ee91272739fe451c280aa4b7fa5120b9278815db5fcd713d83772"

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
    checkout = Path.join(dir, "checkout")
    File.mkdir_p!(Path.join(checkout, "src"))
    File.write!(Path.join(checkout, "src/a.js"), "base\n")
    git(checkout, ["init", "-q"])
    git(checkout, ["add", "-A"])
    git(checkout, ["commit", "-q", "-m", "base"])

    red = Path.join([dir, "rsolv", "verify-red"])
    green = Path.join([dir, "rsolv", "verify-green"])
    :ok = Workspace.copy(checkout, red, exec: Exec)
    :ok = Workspace.copy(checkout, green, exec: Exec)

    %{
      dir: dir,
      checkout: checkout,
      red: red,
      green: green,
      base: git(checkout, ["rev-parse", "HEAD"])
    }
  end

  # Runs `script` as the RED step's hostile test, in a sandbox on `copy`,
  # with `args` as its positional parameters ("$1"…).
  defp hostile(dir, copy, script, args \\ []) do
    name = "rsolv-test-#{System.unique_integer([:positive])}"

    {:ok, sbx} =
      Sandbox.start(
        name: name,
        network: name <> "-net",
        copy_dir: copy,
        runner_temp: dir,
        egress: :none,
        image: @image,
        exec: Exec
      )

    try do
      {:ok, result} =
        Sandbox.exec(sbx, ["sh", "-c", script, "hostile" | args], timeout_ms: 60_000)

      result
    after
      Sandbox.stop(sbx)
    end
  end

  defp add(path),
    do: %Entry{
      path: path,
      op: :add,
      base_mode: nil,
      base_blob_sha: nil,
      mode: "100644",
      new_blob_sha: "x"
    }

  describe "a RED sandbox (acceptance 5b)" do
    test "can't reach the GREEN copy or the checkout", context do
      %{status: 0} =
        hostile(
          context.dir,
          context.red,
          """
          echo pwned > /work/src/a.js
          for target in "$1/src/a.js" "$2/src/a.js" /work/../verify-green/src/a.js; do
            echo pwned > "$target" 2>/dev/null || true
          done
          ln -s "$1" /work/escape
          ln -s / /work/root
          """,
          [context.green, context.checkout]
        )

      assert File.read!(Path.join(context.red, "src/a.js")) == "pwned\n"
      assert File.read!(Path.join(context.green, "src/a.js")) == "base\n"
      assert File.read!(Path.join(context.checkout, "src/a.js")) == "base\n"
    end

    test "can't make a later host write follow a symlink it planted", context do
      %{status: 0} =
        hostile(context.dir, context.red, ~s(ln -s "$1" /work/escape), [context.green])

      assert Copies.write_images(context.red, [add("escape/src/b.js")], %{
               "escape/src/b.js" => "pwned"
             }) == {:error, {:unsafe_path, "escape/src/b.js"}}

      refute File.exists?(Path.join(context.green, "src/b.js"))
    end
  end

  describe "a sandbox that plants a hostile .git (acceptance 5a)" do
    test "causes nothing on the host, even if git read its tree", context do
      # A path the planted config can name unquoted, outside every mount.
      marker = Path.join(System.tmp_dir!(), "rsolv-5a-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(marker) end)

      hostile(context.dir, context.red, """
      printf '[core]\\n\\tfsmonitor = touch #{marker}\\n\\thooksPath = /work/.git/hooks\\n' >> /work/.git/config
      mkdir -p /work/.git/hooks
      printf '#!/bin/sh\\ntouch #{marker}\\n' > /work/.git/hooks/post-checkout
      chmod +x /work/.git/hooks/post-checkout
      ln -s /proc/self/environ /work/env
      """)

      assert {:ok, %{paths: %{"env" => %{type: :missing}}}} =
               BaseFactsReader.read(context.red, context.base, ["src/a.js", "env"], exec: Exec)

      refute File.exists?(marker)

      # The control: a plain git in that tree does run what the sandbox planted.
      System.cmd("git", ["status"],
        cd: context.red,
        env: [{"GIT_CONFIG_GLOBAL", "/dev/null"}],
        stderr_to_stdout: true
      )

      assert File.exists?(marker)
    end
  end

  describe "a job the runner stops with SIGTERM" do
    # The reviewer's killed.exs, as a test: a separate VM, stopped mid-step.
    test "removes this attempt's sandbox, proxy and network, and nothing else", context do
      id = System.unique_integer([:positive])
      label = "#{id}/1"
      name = "rsolv-test-killed-#{id}"
      bystander = "rsolv-test-bystander-#{id}"

      {_, 0} =
        System.cmd("docker", ["network", "create", "--label", "rsolv.run=#{id}9/1", bystander])

      on_exit(fn ->
        Sandbox.remove_labelled(&(&1 == label), Exec)
        System.cmd("docker", ["network", "rm", bystander], stderr_to_stdout: true)
      end)

      script = """
      Application.put_env(:rsolv_host, :proxy_image, #{inspect(Application.fetch_env!(:rsolv_host, :proxy_image))})

      {:ok, sbx} =
        RsolvHost.Sandbox.start(
          name: #{inspect(name)},
          network: #{inspect(name <> "-net")},
          copy_dir: #{inspect(context.red)},
          runner_temp: #{inspect(context.dir)},
          image: #{inspect(@image)},
          label: #{inspect(label)},
          exec: RsolvHost.Exec
        )

      {:ok, _id} = RsolvHost.Sandbox.trap_sigterm(#{inspect(label)}, RsolvHost.Exec)
      IO.puts("ready " <> System.pid())

      try do
        RsolvHost.Sandbox.exec(sbx, ["sleep", "300"], timeout_ms: 300_000)
      after
        IO.puts("after ran")
      end
      """

      ebin =
        for dir <- Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin")),
            arg <- ["-pa", dir],
            do: arg

      port =
        Port.open({:spawn_executable, System.find_executable("elixir")}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: ebin ++ ["-e", script]
        ])

      pid = ready(port, "")
      {_, 0} = System.cmd("kill", ["-TERM", pid])

      assert {status, output} = exited(port, "")
      assert status == 4
      refute output =~ "after ran"

      for list <- [["ps", "-a"], ["network", "ls"]] do
        {listed, 0} =
          System.cmd("docker", list ++ ["-q", "--filter", "label=rsolv.run=" <> label])

        assert listed == "", inspect(list)
      end

      assert {_, 0} =
               System.cmd("docker", ["network", "inspect", bystander], stderr_to_stdout: true)
    end
  end

  defp ready(port, acc) do
    receive do
      {^port, {:data, data}} ->
        case Regex.run(~r/ready (\d+)/, acc <> data) do
          [_, pid] -> pid
          nil -> ready(port, acc <> data)
        end

      {^port, {:exit_status, status}} ->
        flunk("the VM exited #{status} before it was ready: #{acc}")
    after
      300_000 -> flunk("the VM never became ready: #{acc}")
    end
  end

  defp exited(port, acc) do
    receive do
      {^port, {:data, data}} -> exited(port, acc <> data)
      {^port, {:exit_status, status}} -> {status, acc}
    after
      120_000 -> flunk("the VM didn't stop after SIGTERM: #{acc}")
    end
  end
end
