defmodule RsolvHost.VerifyDocker do
  @moduledoc """
  The verify role end to end on a real Docker with the pinned sandbox image,
  for `:docker` tests; only the platform is stubbed (`RsolvHost.PlatformStub`).

  A fixture is a base tree, committed to a git checkout, and a change:
  `[{path, base_bytes | nil, new_bytes}]`, where `nil` makes an add. The
  base may carry `harness/0` as `vendor/bin/phpunit`: base code, and the one
  plan executable a tree can supply, so `sh/1` runs a shell step through an
  ordinary plan.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]
  import RsolvHost.PlatformStub

  alias RsolvCore.ChangeSet
  alias RsolvHost.{Exec, FakeExec, Oidc, Platform}
  alias RsolvHost.Roles.Verify

  @sandbox_image (fn ->
                    config = File.read!(Path.expand("../../config/config.exs", __DIR__))
                    [_, image] = Regex.run(~r/sandbox_image:\s*"([^"]+)"/, config)
                    image
                  end).()

  @run_id "0b0e5f7c-7d3c-4d8e-9a55-3f6f1b0c2a11"

  @doc "The shell harness: `vendor/bin/phpunit SCRIPT` runs SCRIPT with /bin/sh."
  @spec harness() :: binary()
  def harness,
    do:
      ~s(#!/bin/sh\n# Stands in for project tooling: runs its one argument.\nexec /bin/sh -c "$1"\n)

  @doc "A plan argv running `script` through the harness."
  @spec sh(String.t()) :: [String.t()]
  def sh(script), do: ["vendor/bin/phpunit", script]

  @doc """
  Commits `files` (path => bytes) to a new checkout under `dir`, and points
  the role at the pinned sandbox image until the test ends, when every
  container and network of the run is removed. Options: `:from` (a tree
  whose files, but not its `.git`, come first), `:executable` (paths made
  0755) and `:mtimes` (path => Unix seconds, set after the commit, as a
  checkout's would be).
  """
  @spec checkout(Path.t(), %{String.t() => binary()}, keyword()) :: map()
  def checkout(dir, files, opts \\ []) do
    previous = Application.get_env(:rsolv_host, :sandbox_image)
    Application.put_env(:rsolv_host, :sandbox_image, @sandbox_image)
    run = "#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Application.put_env(:rsolv_host, :sandbox_image, previous)
      remove_run(run)
    end)

    checkout = Path.join(dir, "checkout")
    File.mkdir_p!(checkout)

    if from = opts[:from] do
      {_out, 0} = System.cmd("cp", ["-a", "--", from <> "/.", checkout])
      File.rm_rf!(Path.join(checkout, ".git"))
    end

    for {path, bytes} <- files do
      File.mkdir_p!(Path.dirname(Path.join(checkout, path)))
      File.write!(Path.join(checkout, path), bytes)
    end

    for path <- Keyword.get(opts, :executable, []),
        do: File.chmod!(Path.join(checkout, path), 0o755)

    git(checkout, ["init", "-q"])
    git(checkout, ["add", "-A"])
    git(checkout, ["commit", "-q", "-m", "base"])

    for {path, at} <- Keyword.get(opts, :mtimes, []),
        do: File.touch!(Path.join(checkout, path), at)

    %{
      env: %{
        "RUNNER_TEMP" => dir,
        "GITHUB_WORKSPACE" => checkout,
        "GITHUB_RUN_ID" => run,
        "GITHUB_RUN_ATTEMPT" => "1",
        "GITHUB_REPOSITORY" => "acme/app",
        "ACTIONS_ID_TOKEN_REQUEST_URL" => "https://token.actions.example/id?v=1",
        "ACTIONS_ID_TOKEN_REQUEST_TOKEN" => "t"
      },
      checkout: checkout,
      base: git(checkout, ["rev-parse", "HEAD"]),
      run: run
    }
  end

  @doc "Runs git in `dir` with no user or system config."
  @spec git(Path.t(), [String.t()]) :: String.t()
  def git(dir, args) do
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

  # Whatever a test's role run left: its containers, then its networks.
  defp remove_run(run) do
    for {list, rm} <- [
          {["ps", "-aq"], ["rm", "-f"]},
          {["network", "ls", "-q"], ["network", "rm"]}
        ] do
      {ids, _status} = System.cmd("docker", list ++ ["--filter", "label=rsolv.run=#{run}"])
      ids = String.split(ids, "\n", trim: true)
      if ids != [], do: System.cmd("docker", rm ++ ids, stderr_to_stdout: true)
    end
  end

  @doc "`change`'s change set, as the platform sends it."
  @spec change_set([{String.t(), binary() | nil, binary()}]) :: [map()]
  def change_set(change) do
    change
    |> Enum.map(fn {path, base, new} ->
      %{
        "path" => path,
        "op" => if(base, do: "modify", else: "add"),
        "base_mode" => base && "100644",
        "base_blob_sha" => base && ChangeSet.blob_sha(base),
        "mode" => "100644",
        "new_blob_sha" => ChangeSet.blob_sha(new)
      }
    end)
    |> Enum.sort_by(& &1["path"])
  end

  defp digest(json), do: json |> ChangeSet.from_json() |> elem(1) |> ChangeSet.digest()

  @doc """
  A v2 plan for `change`, its RED snapshot the adds at `red_paths`, with
  empty steps, the report read from `/work/rsolv-report`, and `overrides`.
  """
  @spec plan([{String.t(), binary() | nil, binary()}], [String.t()], map()) :: map()
  def plan(change, red_paths, overrides) do
    entries = change_set(change)

    Map.merge(
      %{
        "v" => 2,
        "framework" => "rspec",
        "install" => [],
        "prepare" => [],
        "test_prepare" => [],
        "env" => %{},
        "test" => sh("true"),
        "report" => %{"format" => "rspec_json", "argv" => ["cat", "--", "/work/rsolv-report"]},
        "install_timeout_s" => 1_800,
        "test_timeout_s" => 600,
        "change_set" => entries,
        "change_set_digest" => digest(entries),
        "red_paths" => red_paths,
        "red_digest" => digest(Enum.filter(entries, &(&1["path"] in red_paths))),
        "policy_version" => "2026-11-v4"
      },
      overrides
    )
  end

  @doc """
  Runs the role on `context`'s checkout with `plan`, whose post-images come
  from `change`. Options: `:answers` (platform endpoint => `{status, json}`),
  `:exec` (FakeExec rules tried before the real exec) and `:deps`. Answers
  `%{result:, body:, out:}`, the body being the verification posted (or
  nil). Every platform request and docker run is sent to the test as
  `{:event, {:platform, name} | :docker_run}`.
  """
  @spec verify(map(), [{String.t(), binary() | nil, binary()}], map(), keyword()) :: map()
  def verify(context, change, plan, opts \\ []) do
    stub_platform(context, change, plan, Keyword.get(opts, :answers, %{}))
    real_exec(Keyword.get(opts, :exec, []))
    {:ok, io} = StringIO.open("")
    result = Verify.run(%{issue: 7}, context.env, [io: io] ++ Keyword.get(opts, :deps, []))
    {:ok, {_in, out}} = StringIO.close(io)
    %{result: result, body: posted(), out: out}
  end

  defp stub_platform(context, change, plan, answers) do
    test = self()
    Req.Test.stub(Oidc, &Req.Test.json(&1, %{value: "e30.e30.sig"}))

    defaults = %{
      "touched-paths" => {200, %{paths: Enum.map(change, &elem(&1, 0)), work_attempt: 1}},
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
      "post-images" =>
        {200, %{files: Map.new(change, fn {path, _base, new} -> {path, Base.encode64(new)} end)}},
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

  defp real_exec(overrides) do
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

  defp posted do
    receive do
      {:request, "verification", "POST", body} -> body
    after
      0 -> nil
    end
  end

  @doc "The events `verify/4` sent, oldest first."
  @spec events() :: [term()]
  def events, do: events([])

  defp events(acc) do
    receive do
      {:event, event} -> events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc "A side's report, decoded."
  @spec report(map(), String.t()) :: binary()
  def report(body, side), do: Base.decode64!(body[side]["report"])

  @doc "The hex SHA-256 of `bytes`."
  @spec sha256(binary()) :: String.t()
  def sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @doc "The names of the run's containers that are still there."
  @spec containers(map()) :: [String.t()]
  def containers(context) do
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
end
