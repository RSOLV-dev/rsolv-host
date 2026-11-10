defmodule RsolvHost.Sandbox do
  @moduledoc """
  The sandbox container's lifecycle, through argv-only `docker` calls (RFC-150
  §2.1, §9, ADR-076). It mirrors the step-1 spike's `sandbox.sh` with every
  `sh -c` replaced by argv.

  The sandbox runs as the copy's owner, which must be the host's own user and
  isn't root (UID and GID 0 are refused), with no capabilities, no new privileges,
  no runner variables (every `-e` sets an explicit value) and only the copy
  mounted. With `egress: :proxy` (the default) its only network is an internal
  one whose sole other member is a squid proxy; with `egress: :none` it has no
  network at all. Setup fails closed: if any step fails, everything is removed
  and nothing runs unfiltered.
  """

  alias RsolvHost.{ActionsLog, Egress, Frame, Workspace}

  defstruct [
    :container,
    :network,
    :proxy,
    :proxy_ip,
    :exec,
    :deadline,
    :created,
    :copy_dir,
    labels: %{},
    ids: %{},
    dirs: [],
    egress: :proxy
  ]

  @type t :: %__MODULE__{
          container: String.t(),
          network: String.t() | nil,
          proxy: String.t() | nil,
          proxy_ip: String.t() | nil,
          exec: module(),
          deadline: integer() | nil,
          created: pid() | nil,
          copy_dir: Path.t() | nil,
          labels: %{String.t() => String.t()},
          ids: %{optional(:sandbox | :proxy | :network) => String.t()},
          dirs: [Path.t()],
          egress: :proxy | :none
        }

  # ponytail: sized for a GitHub-hosted runner (7 GB RAM, 2 to 4 CPUs),
  # leaving room for the host's VM and the proxy: 4 GiB of memory and no swap,
  # 2 CPUs, a 1 GiB /tmp. Raise with evidence from a self-hosted runner. The
  # bind-mounted copy and HOME have no portable disk quota.
  @limits ["--memory", "4g", "--memory-swap", "4g", "--cpus", "2"]
  @tmp "/tmp:exec,size=1g"
  @setup_timeout_ms 60_000
  @du_timeout_ms 30_000
  @stop_wait_ms 35_000
  # An image pull can be slow; the sandbox image carries every toolchain.
  @pull_timeout_ms 900_000
  @kill_after_s "10"
  @host_grace_ms 30_000
  # owner/name, as GitHub allows them: label values never carry more.
  @repository ~r/\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}\/[A-Za-z0-9_.][A-Za-z0-9_.-]{0,99}\z/

  @doc """
  The `docker run` argv for the sandbox. `opts` has `:name`, `:network`,
  `:copy_dir`, `:home_dir`, `:uid`, `:gid`, `:proxy_ip`, `:image` and
  optionally `:egress` and `:labels` (label => value).
  """
  @spec run_args(map()) :: [String.t()]
  def run_args(opts) do
    egress = Map.get(opts, :egress, :proxy)

    [
      "run",
      "-d",
      "--name",
      opts.name,
      "--network",
      network(egress, opts.network),
      "--dns",
      "127.0.0.1"
    ] ++
      labels(Map.get(opts, :labels, %{})) ++
      [
        "--user",
        "#{opts.uid}:#{opts.gid}",
        "--cap-drop",
        "ALL",
        "--security-opt",
        "no-new-privileges"
      ] ++
      ["--pids-limit", "4096", "--tmpfs", @tmp] ++
      @limits ++
      ["-e", "LANG=C.UTF-8", "-e", "CI=true", "-e", "HOME=/opt/home"] ++
      proxy_env(egress, opts.proxy_ip) ++
      ["-v", opts.copy_dir <> ":/work", "-v", opts.home_dir <> ":/opt/home", "-w", "/work"] ++
      ["--entrypoint", "sleep", opts.image, "86400"]
  end

  defp labels(labels),
    do: for({key, value} <- Enum.sort(labels), arg <- ["--label", key <> "=" <> value], do: arg)

  defp network(:proxy, network), do: network
  defp network(:none, _network), do: "none"

  # Only the sandbox's own loopback skips the proxy. An empty NO_PROXY makes
  # Mix/Hex bypass the proxy entirely, and with no direct egress it then fails.
  @no_proxy "localhost,127.0.0.1"

  defp proxy_env(:none, _ip), do: []

  defp proxy_env(:proxy, ip) do
    url = "http://#{ip}:3128"

    ["-e", "HTTP_PROXY=" <> url, "-e", "HTTPS_PROXY=" <> url] ++
      ["-e", "http_proxy=" <> url, "-e", "https_proxy=" <> url] ++
      ["-e", "NO_PROXY=" <> @no_proxy, "-e", "no_proxy=" <> @no_proxy]
  end

  @doc """
  Starts the sandbox. Options: `:name` (the container), `:network`, `:copy_dir`
  (the copy to mount; its owner, the host's own non-root user, becomes the
  sandbox user), `:runner_temp`,
  `:egress` (`:proxy` or `:none`), `:image` (default: the pinned sandbox
  image), `:probe` (the proxy readiness check, `fn ip -> :ok | :error end`),
  `:stat` (how the copy is stat'ed, default `File.stat!/1`), `:exec`,
  `:labels` (on its containers and network, for `remove_stale/2`),
  `:created` (a `trap_sigterm/2` registry, told every container and network
  ID as it's made) and `:deadline` (monotonic milliseconds: no setup step
  runs past it, and one it stops is `:session_timeout`). It removes them by
  those IDs, never by name.
  """
  @spec start(keyword()) ::
          {:ok, t()}
          | {:error,
             {:sandbox_setup, atom()}
             | {:sandbox, :enoent}
             | :sandbox_image_unpinned
             | :session_timeout}
  def start(opts) do
    image =
      Keyword.get_lazy(opts, :image, fn -> Application.fetch_env!(:rsolv_host, :sandbox_image) end)

    egress = Keyword.get(opts, :egress, :proxy)

    rsolv = Path.join(Keyword.fetch!(opts, :runner_temp), "rsolv")

    sbx = %__MODULE__{
      dirs: Enum.map(["home-", "proxy-"], &Path.join(rsolv, &1 <> Keyword.fetch!(opts, :name))),
      container: Keyword.fetch!(opts, :name),
      copy_dir: Keyword.fetch!(opts, :copy_dir),
      network: if(egress == :proxy, do: Keyword.fetch!(opts, :network)),
      proxy: if(egress == :proxy, do: Keyword.fetch!(opts, :name) <> "-proxy"),
      exec: Keyword.get_lazy(opts, :exec, &RsolvHost.exec/0),
      labels: Keyword.get(opts, :labels, %{}),
      created: Keyword.get(opts, :created),
      deadline: Keyword.get(opts, :deadline),
      egress: egress
    }

    with :ok <- pinned(image),
         home_dir = home(opts),
         {:ok, uid, gid} <-
           user(
             Keyword.get(opts, :stat, &File.stat!/1).(Keyword.fetch!(opts, :copy_dir)),
             File.stat!(home_dir)
           ) do
      run = fn sbx ->
        create(
          sbx,
          :sandbox,
          :sandbox_run,
          run_args(%{
            name: sbx.container,
            network: sbx.network,
            copy_dir: Keyword.fetch!(opts, :copy_dir),
            home_dir: home_dir,
            uid: uid,
            gid: gid,
            proxy_ip: sbx.proxy_ip,
            image: image,
            egress: egress,
            labels: sbx.labels
          }),
          @pull_timeout_ms
        )
      end

      sbx |> setup(proxy_steps(sbx, opts) ++ [run]) |> started()
    else
      {:error, {:sandbox_setup, _step}} = error ->
        stop(sbx)
        error

      error ->
        error
    end
  end

  # Each step answers {:ok, sbx}; the sandbox made so far is removed on the first error.
  defp setup(sbx, steps) do
    Enum.reduce_while(steps, {:ok, sbx}, fn step, {:ok, sbx} ->
      case step.(sbx) do
        {:ok, sbx} -> {:cont, {:ok, sbx}}
        {:error, reason} -> {:halt, {:error, reason, sbx}}
      end
    end)
  end

  defp started({:ok, sbx}), do: {:ok, sbx}

  defp started({:error, reason, sbx}) do
    stop(sbx)
    {:error, reason}
  end

  # The sandbox user is the copy's owner, which must be the host's own user (the
  # owner of the HOME directory it just made) and never root, user or group.
  # A fixed UID would need the copy chowned, which a non-root runner can't do.
  defp user(%{uid: uid, gid: gid}, _host) when uid == 0 or gid == 0,
    do: {:error, {:sandbox_setup, :root_user}}

  defp user(%{uid: uid, gid: gid}, %{uid: uid}), do: {:ok, uid, gid}
  defp user(_copy, _host), do: {:error, {:sandbox_setup, :copy_owner}}

  defp pinned(image) do
    case String.split(image, "@sha256:") do
      [_name, digest] when byte_size(digest) == 64 ->
        if digest =~ ~r/\A[0-9a-f]{64}\z/ and digest != String.duplicate("0", 64),
          do: :ok,
          else: {:error, :sandbox_image_unpinned}

      _unpinned ->
        {:error, :sandbox_image_unpinned}
    end
  end

  # The sandbox user's HOME (caches, toolchains): made by the host, so it's owned
  # by the copy's owner whatever the image, and on disk rather than in a tmpfs.
  # The host never reads it.
  defp home(opts) do
    home =
      Path.join([
        Keyword.fetch!(opts, :runner_temp),
        "rsolv",
        "home-" <> Keyword.fetch!(opts, :name)
      ])

    File.mkdir_p!(Path.dirname(home))
    :ok = File.mkdir(home)
    File.chmod!(home, 0o700)
    home
  end

  defp proxy_steps(%{egress: :none}, _opts), do: []

  defp proxy_steps(sbx, opts) do
    dir = Path.join([Keyword.fetch!(opts, :runner_temp), "rsolv", "proxy-" <> sbx.container])
    conf = Path.join(dir, "squid.conf")
    allowlist = Path.join(dir, "allowlist.txt")
    File.mkdir_p!(dir)
    File.write!(conf, Egress.squid_conf())
    File.write!(allowlist, Egress.allowlist())
    proxy_image = Application.fetch_env!(:rsolv_host, :proxy_image)

    [
      &create(
        &1,
        :network,
        :network_create,
        ["network", "create", "--internal" | labels(&1.labels)] ++ [&1.network]
      ),
      &create(
        &1,
        :proxy,
        :proxy_run,
        ["run", "-d", "--name", &1.proxy | labels(&1.labels)] ++
          ["-v", conf <> ":/etc/squid/squid.conf:ro"] ++
          ["-v", allowlist <> ":/etc/squid/allowlist.txt:ro", proxy_image],
        @pull_timeout_ms
      ),
      &with(
        :ok <- step(&1, :proxy_connect, ["network", "connect", &1.network, &1.proxy]),
        do: {:ok, &1}
      ),
      fn sbx ->
        with {:ok, proxy_ip} <- ip(sbx, sbx.network),
             {:ok, bridge_ip} <- ip(sbx, "bridge"),
             :ok <- ready(Keyword.get(opts, :probe, &probe/1), bridge_ip),
             do: {:ok, %{sbx | proxy_ip: proxy_ip}}
      end
    ]
  end

  # `docker run -d` and `docker network create` print the new ID last (after
  # any pull progress); it's recorded before anything else can fail.
  defp create(sbx, kind, name, args, timeout_ms \\ @setup_timeout_ms) do
    with {:ok, output} <- docker(sbx, name, args, timeout_ms),
         [id | _] when byte_size(id) == 64 <-
           output |> String.split("\n", trim: true) |> Enum.reverse(),
         true <- id =~ ~r/\A[0-9a-f]{64}\z/ do
      if sbx.created, do: Agent.update(sbx.created, &[{kind, id} | &1])
      {:ok, %{sbx | ids: Map.put(sbx.ids, kind, id)}}
    else
      {:error, _reason} = error -> error
      _no_id -> {:error, {:sandbox_setup, name}}
    end
  end

  defp ip(sbx, network) do
    template = "{{(index .NetworkSettings.Networks \"" <> network <> "\").IPAddress}}"
    args = ["inspect", "-f", template, sbx.proxy]

    with {:ok, output} <- docker(sbx, :proxy_inspect, args, @setup_timeout_ms),
         ip = String.trim(output),
         {:ok, _address} <- :inet.parse_strict_address(String.to_charlist(ip)) do
      {:ok, ip}
    else
      {:error, :session_timeout} = late -> late
      _not_an_address -> {:error, {:sandbox_setup, :proxy_inspect}}
    end
  end

  defp ready(probe, ip) do
    case probe.(ip) do
      :ok -> :ok
      _not_ready -> {:error, {:sandbox_setup, :proxy_ready}}
    end
  end

  # 30 attempts, one second apart, as in the spike.
  defp probe(ip), do: probe(String.to_charlist(ip), 30)

  defp probe(_ip, 0), do: :error

  defp probe(ip, tries) do
    case :gen_tcp.connect(ip, 3128, [], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)

      {:error, _reason} ->
        Process.sleep(1_000)
        probe(ip, tries - 1)
    end
  end

  defp step(sbx, name, args, timeout_ms \\ @setup_timeout_ms) do
    with {:ok, _output} <- docker(sbx, name, args, timeout_ms), do: :ok
  end

  # A step the deadline cut short (its time left was at most its own limit)
  # and that then timed out is `:session_timeout`, not the step failing.
  defp docker(sbx, name, args, timeout_ms) do
    {limit, cut} = within(timeout_ms, sbx.deadline)

    case sbx.exec.run("docker", args, timeout_ms: limit) do
      {:ok, %{status: 0, output: output}} -> {:ok, output}
      {:error, :enoent} -> {:error, {:sandbox, :enoent}}
      {:error, :timeout} when cut == :deadline -> {:error, :session_timeout}
      _failed -> {:error, {:sandbox_setup, name}}
    end
  end

  defp within(timeout_ms, nil), do: {timeout_ms, :step}

  defp within(timeout_ms, deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      left when left <= timeout_ms -> {max(left, 0), :deadline}
      _room -> {timeout_ms, :step}
    end
  end

  @doc """
  Runs `argv` in the sandbox as `docker exec -i <container> timeout -k 10 <s>
  <argv…>`, where `s` is `:timeout_ms` in whole seconds (at least 1), with a host
  deadline 30 s later. Takes `run/3`'s `:input` and `:max_bytes`.
  """
  @spec exec(t(), [String.t()], keyword()) :: RsolvHost.Exec.result()
  def exec(sbx, argv, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 60_000)
    seconds = timeout_ms |> div(1_000) |> max(1) |> Integer.to_string()

    sbx.exec.run(
      "docker",
      ["exec", "-i", sbx.container, "timeout", "-k", @kill_after_s, seconds | argv],
      Keyword.merge(opts, timeout_ms: timeout_ms + @host_grace_ms)
    )
  end

  @doc """
  Starts `argv` in the sandbox as `exec/3` does, returning the open channel.
  Its stdout and stderr arrive merged (`RsolvHost.Exec.open/3`), so a program
  that frames its output must keep stderr empty (see `RsolvHost.ScanRelay`).
  """
  @spec open(t(), [String.t()], pos_integer()) :: {:ok, port() | pid()} | {:error, :enoent}
  def open(sbx, argv, timeout_ms) do
    seconds = timeout_ms |> div(1_000) |> max(1) |> Integer.to_string()

    sbx.exec.open(
      "docker",
      ["exec", "-i", sbx.container, "timeout", "-k", @kill_after_s, seconds | argv],
      []
    )
  end

  @doc """
  The input for `rsolv-sandbox bootstrap`, from `RSOLV_EXACT_RUNTIME_VERSIONS`:
  exactly `"true"` makes a Python version with no build attestations fail
  rather than fall back to another patch (3d decision).
  """
  @spec bootstrap_input(String.t() | nil) :: binary()
  def bootstrap_input("true"), do: Frame.encode(%{"exact_runtime_versions" => true})
  def bootstrap_input(_unset), do: "0\n"

  @doc """
  The bytes the sandbox's writable mounts (its copy and HOME) use on disk:
  `du -s -c -x -P -B1`, which follows no symlink, stays on one filesystem,
  reads no file content and counts a hardlinked file once. Anything but a
  total from a du that read everything within 30 s is `:error`: a directory
  the sandbox made unreadable would hide what's beneath it.

  ponytail: a file the project removes mid-walk also fails du, so a churning
  install can be stopped as over budget; retry the measure if that shows up.
  """
  @spec disk_used(t()) :: {:ok, non_neg_integer()} | :error
  def disk_used(%__MODULE__{dirs: [home | _]} = sbx) do
    args = ["-s", "-c", "-x", "-P", "-B1", "--", sbx.copy_dir, home]

    with {:ok, %{status: 0, output: output}} <-
           sbx.exec.run("du", args, timeout_ms: @du_timeout_ms, max_bytes: 1024 * 1024),
         [_, total] <- Regex.run(~r/^(\d+)\ttotal$/m, output) do
      {:ok, String.to_integer(total)}
    else
      _no_total -> :error
    end
  end

  @doc """
  Runs `fun` (the sandbox's steps) while a watchdog measures `disk_used/1`
  every `poll_ms`: past `max_bytes`, or with no measure, it kills the
  sandbox, and the answer is `{:error, :disk_limit}` whatever `fun` returned.
  When `fun` returns, the watchdog finishes the measure in flight and takes
  one more; either over budget, or no answer within 35 s (du's 30 s and a
  margin), is `{:error, :disk_limit}` too. The bind mounts have no portable
  quota, so this is the bound.

  ponytail: a burst between two polls overshoots by whatever it writes in
  `poll_ms` (plus du's own time); a hard bound needs a quota (xfs project
  quotas, btrfs subvolumes) or a size-limited loop device per copy.
  """
  @spec watched(t(), non_neg_integer(), pos_integer(), (-> result)) ::
          result | {:error, :disk_limit}
        when result: term()
  def watched(sbx, max_bytes, poll_ms, fun) do
    ref = make_ref()
    role = self()
    {:ok, watchdog} = Task.start_link(fn -> watch(sbx, max_bytes, poll_ms, {role, ref}) end)

    result =
      try do
        fun.()
      catch
        kind, reason ->
          stop_watchdog(watchdog)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    send(watchdog, {:stop, ref})

    receive do
      {^ref, :within} -> result
      {^ref, :disk_limit} -> {:error, :disk_limit}
    after
      @stop_wait_ms ->
        stop_watchdog(watchdog)
        {:error, :disk_limit}
    end
  end

  defp stop_watchdog(watchdog) do
    Process.unlink(watchdog)
    Process.exit(watchdog, :kill)
  end

  # Tells the role {ref, :disk_limit} as soon as a measure fails, or, once
  # asked to stop, the verdict of one last measure.
  defp watch(sbx, max_bytes, poll_ms, {role, ref} = tell) do
    receive do
      {:stop, ^ref} ->
        send(role, {ref, verdict(disk_used(sbx), max_bytes)})
    after
      poll_ms ->
        case verdict(disk_used(sbx), max_bytes) do
          :within ->
            watch(sbx, max_bytes, poll_ms, tell)

          :disk_limit ->
            send(role, {ref, :disk_limit})
            sbx.exec.run("docker", ["kill", sbx.ids.sandbox], timeout_ms: @setup_timeout_ms)
        end
    end
  end

  defp verdict({:ok, used}, max_bytes) when used <= max_bytes, do: :within
  defp verdict(_over_or_unmeasured, _max_bytes), do: :disk_limit

  @doc "Takes the sandbox off the proxy's network: from here on it has no network."
  @spec disconnect(t()) :: :ok | {:error, term()}
  def disconnect(%__MODULE__{egress: :none}), do: :ok

  def disconnect(sbx),
    do: step(sbx, :network_disconnect, ["network", "disconnect", sbx.network, sbx.container])

  @doc """
  Removes the sandbox, its proxy and its network, by the IDs Docker gave
  them, then, once Docker has removed the containers (`:ok`), the HOME and
  proxy directories it made (`RsolvHost.Workspace.remove/1`; one it can't
  remove is a `::warning::` on `io`). Always safe to call.
  """
  @spec stop(t() | nil, IO.device()) :: :ok | :error
  def stop(sbx, io \\ :stdio)
  def stop(nil, _io), do: :ok

  def stop(sbx, io) do
    removed =
      remove(sbx.exec, ["rm", "-f"], Enum.flat_map([:sandbox, :proxy], &List.wrap(sbx.ids[&1])))

    remove(sbx.exec, ["network", "rm"], List.wrap(sbx.ids[:network]))

    case removed do
      :ok -> Enum.each(sbx.dirs, &remove_dir(&1, io))
      :error -> :error
    end
  end

  @doc "Removes `dir` (`RsolvHost.Workspace.remove/1`), or writes a `::warning::` naming what's left."
  @spec remove_dir(Path.t(), IO.device()) :: :ok
  def remove_dir(dir, io \\ :stdio) do
    case Workspace.remove(dir) do
      :ok ->
        :ok

      {:error, path} ->
        ActionsLog.warning("RSOLV", "Couldn't remove #{path}; remove it from this runner.", io)
    end
  end

  defp remove(_exec, _command, []), do: :ok

  defp remove(exec, command, ids) do
    case exec.run("docker", command ++ ids, timeout_ms: @setup_timeout_ms) do
      {:ok, %{status: 0}} -> :ok
      _failed -> :error
    end
  end

  @doc """
  Traps SIGTERM, which the runner sends when it stops a job (cancelled, or
  past its `timeout-minutes`): the VM would then stop without running any
  `after`, leaving the sandboxes running. Answers `{:ok, %{id: id, created:
  registry}}`; pass `created: registry` to `start/1`, which tells it every
  container and network ID it makes. On SIGTERM the trap suspends the
  calling process, so it can't act on a sandbox vanishing (post a verify
  error), removes those IDs, then the containers and networks that carry all
  of `labels` (`labels/2`'s, whose `rsolv.instance` only this VM's carry):
  Docker may have made one whose ID the VM hadn't yet recorded. It halts with
  exit code 4. Undo it with `untrap_sigterm/1`.
  """
  @spec trap_sigterm(%{String.t() => String.t()}, module()) ::
          {:ok, %{id: term(), created: pid()}} | {:error, term()}
  def trap_sigterm(labels, exec \\ RsolvHost.exec()) do
    caller = self()
    {:ok, created} = Agent.start_link(fn -> [] end)
    filters = filters(labels, ~w(rsolv.repo rsolv.run rsolv.issue rsolv.attempt rsolv.instance))

    trapped =
      System.trap_signal(:sigterm, fn ->
        suspend(caller)
        ids = Agent.get(created, & &1)
        remove(exec, ["rm", "-f"], for({kind, id} <- ids, kind != :network, do: id))
        remove(exec, ["network", "rm"], for({:network, id} <- ids, do: id))
        remove_listed(exec, filters, &ids/1)
        System.halt(4)
      end)

    case trapped do
      {:ok, id} ->
        {:ok, %{id: id, created: created}}

      error ->
        Agent.stop(created)
        error
    end
  end

  @doc "Undoes `trap_sigterm/2`."
  @spec untrap_sigterm({:ok, %{id: term(), created: pid()}} | {:error, term()}) :: :ok
  def untrap_sigterm({:ok, %{id: id, created: created}}) do
    System.untrap_signal(:sigterm, id)
    Agent.stop(created)
  end

  def untrap_sigterm({:error, _not_trapped}), do: :ok

  defp suspend(pid) do
    :erlang.suspend_process(pid)
  rescue
    ArgumentError -> false
  end

  @doc """
  The labels a role's containers and networks carry (`start/1`,
  `remove_stale/2`, `trap_sigterm/2`): the job's repository, run and attempt,
  from `env`, `issue`, and `rsolv.instance`, random for each call, which tells
  this VM's apart from another job's with the same labels. A missing or
  malformed variable is `{:error, {:missing_env, name}}`.
  """
  @spec labels(map(), pos_integer()) ::
          {:ok, %{String.t() => String.t()}} | {:error, {:missing_env, String.t()}}
  def labels(env, issue) do
    with {:ok, run} <- env_value(env, "GITHUB_RUN_ID", ~r/\A[0-9]{1,20}\z/),
         {:ok, attempt} <- env_value(env, "GITHUB_RUN_ATTEMPT", ~r/\A[0-9]{1,5}\z/),
         {:ok, repository} <- env_value(env, "GITHUB_REPOSITORY", @repository) do
      {:ok,
       %{
         "rsolv.repo" => repository,
         "rsolv.run" => run,
         "rsolv.issue" => Integer.to_string(issue),
         "rsolv.attempt" => attempt,
         "rsolv.instance" => 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
       }}
    end
  end

  defp env_value(env, name, format) do
    case env[name] do
      value when is_binary(value) ->
        if value =~ format, do: {:ok, value}, else: {:error, {:missing_env, name}}

      nil ->
        {:error, {:missing_env, name}}
    end
  end

  @doc """
  Removes, by ID, the containers and then the networks an earlier attempt of
  the same job left: those whose `rsolv.repo`, `rsolv.run` and `rsolv.issue`
  labels equal `labels`' and whose `rsolv.attempt` is lower. A sibling job (another
  issue of the run, or another repository's run with the same ID) is never
  touched. Best effort.
  """
  @spec remove_stale(%{String.t() => String.t()}, module()) :: :ok
  def remove_stale(%{"rsolv.attempt" => attempt} = labels, exec \\ RsolvHost.exec()) do
    attempt = String.to_integer(attempt)

    remove_listed(
      exec,
      filters(labels, ~w(rsolv.repo rsolv.run rsolv.issue)),
      &earlier(&1, attempt)
    )
  end

  defp filters(labels, keys),
    do: for(key <- keys, arg <- ["--filter", "label=#{key}=#{Map.fetch!(labels, key)}"], do: arg)

  # Lists the containers, then the networks, matching `filters`, and removes
  # the IDs `select` picks from the listing. Best effort.
  defp remove_listed(exec, filters, select) do
    format = "{{.ID}}\t{{.Label \"rsolv.attempt\"}}"

    for {list, command} <- [{["ps", "-a"], ["rm", "-f"]}, {["network", "ls"], ["network", "rm"]}],
        {:ok, %{status: 0, output: output}} <-
          [
            exec.run("docker", list ++ filters ++ ["--format", format],
              timeout_ms: @setup_timeout_ms
            )
          ],
        do: remove(exec, command, select.(output))

    :ok
  end

  defp ids(output),
    do:
      for(line <- String.split(output, "\n", trim: true), do: line |> String.split("\t") |> hd())

  defp earlier(output, attempt) do
    for line <- String.split(output, "\n", trim: true),
        [id, theirs] <- [String.split(line, "\t")],
        {theirs, ""} <- [Integer.parse(theirs)],
        theirs < attempt,
        do: id
  end
end
