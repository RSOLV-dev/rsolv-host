defmodule RsolvHost.Roles.WorkDockerTest do
  # The work role on a real Docker, stopped by the runner mid-session.
  use ExUnit.Case, async: false

  alias RsolvHost.KilledVm

  @moduletag :docker
  @moduletag :tmp_dir
  @moduletag timeout: 600_000
  @image "buildpack-deps:bookworm-curl@sha256:f5c5d07ea24ee91272739fe451c280aa4b7fa5120b9278815db5fcd713d83772"

  describe "a job the runner stops with SIGTERM" do
    test "removes the sandbox, proxy and network the role made, and nothing it didn't",
         %{tmp_dir: dir} do
      run = "#{System.unique_integer([:positive])}"
      names = ["rsolv-#{run}-7-work", "rsolv-#{run}-7-work-proxy", "rsolv-#{run}-7-net"]
      mine = %{repo: "acme/app", run: run, issue: "7", attempt: "1"}
      twin = KilledVm.bystander(mine, @image)
      sibling = KilledVm.bystander(%{mine | issue: "8"}, @image)
      other_repo = KilledVm.bystander(%{mine | repo: "other/app"}, @image)

      on_exit(fn ->
        for kind <- [[], ["network"]],
            do: System.cmd("docker", kind ++ ["rm", "-f" | names], stderr_to_stdout: true)
      end)

      checkout = Path.join(dir, "checkout")
      File.mkdir_p!(checkout)
      File.write!(Path.join(checkout, "a.rb"), "base\n")

      env = %{
        "RUNNER_TEMP" => dir,
        "GITHUB_WORKSPACE" => checkout,
        "GITHUB_RUN_ID" => run,
        "GITHUB_RUN_ATTEMPT" => "1",
        "GITHUB_REPOSITORY" => "acme/app",
        "RSOLV_API_URL" => "https://api.rsolv.ai.",
        "ACTIONS_ID_TOKEN_REQUEST_URL" => "https://token.actions.example/id?v=1",
        "ACTIONS_ID_TOKEN_REQUEST_TOKEN" => "t"
      }

      # The platform answers the exchange and then holds VALIDATE open: the
      # runner stops the job mid-session.
      script = """
      {:ok, _} = Application.ensure_all_started(:req)

      for {key, value} <- [
            exec: RsolvHost.Exec,
            proxy_image: #{inspect(Application.fetch_env!(:rsolv_host, :proxy_image))},
            sandbox_image: #{inspect(@image)},
            oidc_audience: "https://api.rsolv.dev",
            "Elixir.RsolvHost.Oidc": [
              req_options: [plug: &Req.Test.json(&1, %{value: "e30.e30.sig"}), retry: false]
            ],
            "Elixir.RsolvHost.Platform": [
              req_options: [
                plug: fn conn ->
                  case conn.request_path do
                    "/api/v1/runs/token" ->
                      Req.Test.json(conn, RsolvHost.PlatformStub.token())

                    "/api/v1/validation/start" ->
                      IO.puts("ready " <> System.pid())
                      Process.sleep(:infinity)
                  end
                end
              ]
            ]
          ],
          do: Application.put_env(:rsolv_host, key, value)

      try do
        RsolvHost.Roles.Work.run(%{issue: 7}, #{inspect(env)}, io: :stderr)
      after
        IO.puts("after ran")
      end
      """

      port = KilledVm.start(script)
      pid = KilledVm.ready(port)
      for made <- names, do: assert(KilledVm.alive?(made), made)
      {_, 0} = System.cmd("kill", ["-TERM", pid])

      assert {status, output} = KilledVm.exited(port)
      assert status == 4
      refute output =~ "after ran"

      for made <- names, do: refute(KilledVm.alive?(made), made)
      assert Enum.all?([twin, sibling, other_repo], &KilledVm.alive?/1)
    end

    test "while it removes what an earlier attempt left, still ends with exit 4",
         %{tmp_dir: dir} do
      checkout = Path.join(dir, "checkout")
      File.mkdir_p!(checkout)

      env = %{
        "RUNNER_TEMP" => dir,
        "GITHUB_WORKSPACE" => checkout,
        "GITHUB_RUN_ID" => "#{System.unique_integer([:positive])}",
        "GITHUB_RUN_ATTEMPT" => "2",
        "GITHUB_REPOSITORY" => "acme/app",
        "RSOLV_API_URL" => "https://api.rsolv.ai.",
        "ACTIONS_ID_TOKEN_REQUEST_URL" => "https://token.actions.example/id?v=1",
        "ACTIONS_ID_TOKEN_REQUEST_TOKEN" => "t"
      }

      # The role's first `docker ps` (stale cleanup) hangs; any other docker
      # call, the trap's included, is real.
      script = """
      {:ok, _} = Application.ensure_all_started(:req)

      defmodule StaleCleanupHangs do
        def run("docker", ["ps" | _] = args, opts) do
          if Process.whereis(:hung) do
            RsolvHost.Exec.run("docker", args, opts)
          else
            Process.register(self(), :hung)
            IO.puts("ready " <> System.pid())
            Process.sleep(:infinity)
          end
        end

        def run(executable, args, opts), do: RsolvHost.Exec.run(executable, args, opts)
        def open(executable, args, opts), do: RsolvHost.Exec.open(executable, args, opts)
        def command(port, data, deadline), do: RsolvHost.Exec.command(port, data, deadline)
      end

      for {key, value} <- [
            exec: StaleCleanupHangs,
            oidc_audience: "https://api.rsolv.dev",
            "Elixir.RsolvHost.Oidc": [
              req_options: [plug: &Req.Test.json(&1, %{value: "e30.e30.sig"}), retry: false]
            ],
            "Elixir.RsolvHost.Platform": [
              req_options: [plug: &Req.Test.json(&1, RsolvHost.PlatformStub.token())]
            ]
          ],
          do: Application.put_env(:rsolv_host, key, value)

      try do
        RsolvHost.Roles.Work.run(%{issue: 7}, #{inspect(env)}, io: :stderr)
      after
        IO.puts("after ran")
      end
      """

      port = KilledVm.start(script)
      pid = KilledVm.ready(port)
      {_, 0} = System.cmd("kill", ["-TERM", pid])

      assert {status, output} = KilledVm.exited(port)
      assert status == 4
      refute output =~ "after ran"
    end
  end
end
