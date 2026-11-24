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
  network at all. With `read_only: true` (verify's TEST phase) its root
  filesystem is read-only: it can write only its copy, its HOME, the `/tmp`
  tmpfs and a 64 MiB `/dev/shm`. Setup fails closed: if any step fails,
  everything is removed and nothing runs unfiltered.
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
    :home,
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
          home: Path.t() | nil,
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
  # Docker keeps no log of a container's stdout: the host reads only exec
  # output, under its caps, and a json-file log (which a sandbox can write
  # through /proc/1/fd/1) is on the runner's disk, unrotated and unmeasured.
  @no_log ["--log-driver", "none"]
  @shm "64m"
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
  optionally `:egress`, `:labels` (label => value) and `:read_only`.
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
      @no_log ++
      [
        "--user",
        "#{opts.uid}:#{opts.gid}",
        "--cap-drop",
        "ALL",
        "--security-opt",
        "no-new-privileges"
      ] ++
      ["--pids-limit", "4096", "--tmpfs", @tmp] ++
      read_only(Map.get(opts, :read_only, false)) ++
      @limits ++
      ["-e", "LANG=C.UTF-8", "-e", "CI=true", "-e", "HOME=/opt/home"] ++
      proxy_env(egress, opts.proxy_ip) ++
      ["-v", opts.copy_dir <> ":/work", "-v", opts.home_dir <> ":/opt/home", "-w", "/work"] ++
      ["--entrypoint", "sleep", opts.image, "86400"]
  end

  defp labels(labels),
    do: for({key, value} <- Enum.sort(labels), arg <- ["--label", key <> "=" <> value], do: arg)

  defp read_only(true), do: ["--read-only", "--shm-size", @shm]
  defp read_only(false), do: []

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
  ID as it's made), `:deadline` (monotonic milliseconds: no setup step
  runs past it, and one it stops is `:session_timeout`), `:home_dir` (a HOME
  from `make_home/2` to mount, which the sandbox then neither makes nor
  removes; by default it makes its own), `:read_only` (`run_args/1`) and
  `:confirm` (a failed setup is `{:sandbox, :teardown}` unless Docker then
  confirms nothing by the sandbox's or proxy's name is left). It removes
  them by those IDs, never by name.
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
    name = Keyword.fetch!(opts, :name)

    with :ok <- pinned(image),
         {:ok, home, owned} <- start_home(opts) do
      sbx = %__MODULE__{
        dirs: owned ++ [Path.join(rsolv, "proxy-" <> name)],
        home: home,
        container: name,
        copy_dir: Keyword.fetch!(opts, :copy_dir),
        network: if(egress == :proxy, do: Keyword.fetch!(opts, :network)),
        proxy: if(egress == :proxy, do: name <> "-proxy"),
        exec: Keyword.get_lazy(opts, :exec, &RsolvHost.exec/0),
        labels: Keyword.get(opts, :labels, %{}),
        created: Keyword.get(opts, :created),
        deadline: Keyword.get(opts, :deadline),
        egress: egress
      }

      start(sbx, image, opts)
    end
  end

  defp start(sbx, image, opts) do
    case user(Keyword.get(opts, :stat, &File.stat!/1).(sbx.copy_dir), File.stat!(sbx.home)) do
      {:ok, uid, gid} ->
        run(sbx, image, opts, uid, gid)

      {:error, reason} ->
        failed(sbx, reason, opts)
    end
  end

  defp run(sbx, image, opts, uid, gid) do
    run = fn sbx ->
      create(
        sbx,
        :sandbox,
        :sandbox_run,
        run_args(%{
          name: sbx.container,
          network: sbx.network,
          copy_dir: sbx.copy_dir,
          home_dir: sbx.home,
          uid: uid,
          gid: gid,
          proxy_ip: sbx.proxy_ip,
          image: image,
          egress: sbx.egress,
          labels: sbx.labels,
          read_only: Keyword.get(opts, :read_only, false)
        }),
        @pull_timeout_ms
      )
    end

    case setup(sbx, proxy_steps(sbx, opts) ++ [run]) do
      {:ok, sbx} -> {:ok, sbx}
      {:error, reason, sbx} -> failed(sbx, reason, opts)
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

  # What a failed setup made is removed by ID. With `confirm: true`, Docker
  # must then say no container by the sandbox's or proxy's name is left (one
  # it made before its ID was recorded has that name), or the answer is
  # `{:sandbox, :teardown}`: something may still run with the copy mounted.
  defp failed(sbx, reason, opts) do
    stop(sbx)

    names = [sbx.container | List.wrap(sbx.proxy)]

    if Keyword.get(opts, :confirm, false) and
         not Enum.all?(names, &gone?(sbx.exec, &1, @setup_timeout_ms)),
       do: {:error, {:sandbox, :teardown}},
       else: {:error, reason}
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

  # A HOME it was given is mounted, never removed; otherwise it makes one,
  # which `stop/2` removes. One already there is a setup failure, and stays.
  defp start_home(opts) do
    case Keyword.fetch(opts, :home_dir) do
      {:ok, home} ->
        {:ok, home, []}

      :error ->
        case make_home(Keyword.fetch!(opts, :runner_temp), Keyword.fetch!(opts, :name)) do
          {:ok, home} -> {:ok, home, [home]}
          {:error, :exists} -> {:error, {:sandbox_setup, :home}}
        end
    end
  end

  @doc """
  Makes the sandbox user's HOME (caches, toolchains), `RUNNER_TEMP/rsolv/home-<name>`:
  a new 0700 directory, made by the host, so it's owned by the copy's owner
  whatever the image, and on disk rather than in a tmpfs. One already there
  is `{:error, :exists}`, and is left as it is. The host never reads it.
  """
  @spec make_home(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, :exists}
  def make_home(runner_temp, name) do
    home = Path.join([runner_temp, "rsolv", "home-" <> name])
    File.mkdir_p!(Path.dirname(home))

    case File.mkdir(home) do
      :ok ->
        File.chmod!(home, 0o700)
        {:ok, home}

      {:error, :eexist} ->
        {:error, :exists}
    end
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
          @no_log ++
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
  deadline 30 s later. Takes `run/3`'s `:input` and `:max_bytes`, and `:env`
  (name => value), each set with `-e`.
  """
  @spec exec(t(), [String.t()], keyword()) :: RsolvHost.Exec.result()
  def exec(sbx, argv, opts) do
    {env, opts} = Keyword.pop(opts, :env, %{})
    timeout_ms = Keyword.get(opts, :timeout_ms, 60_000)
    seconds = timeout_ms |> div(1_000) |> max(1) |> Integer.to_string()
    env = for {name, value} <- Enum.sort(env), arg <- ["-e", name <> "=" <> value], do: arg

    sbx.exec.run(
      "docker",
      ["exec", "-i" | env] ++ [sbx.container, "timeout", "-k", @kill_after_s, seconds | argv],
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

  Alongside it, `df -B1 --output=used,iused` gives the used bytes and inodes
  of the filesystem the copy is on (under `RUNNER_TEMP`): du can't see a file
  unlinked while still open, nor count inodes. Answers `%{du:, fs:, inodes:}`.

  A file or directory the project removed mid-walk (du 9.4 reports it and
  exits 1) isn't a failed read: what's gone holds no bytes. One renamed
  mid-walk can be missed for that measure; `df` still counts its bytes, as it
  does a file unlinked while open.
  """
  @spec disk_used(t()) ::
          {:ok, %{du: non_neg_integer(), fs: non_neg_integer(), inodes: non_neg_integer()}}
          | :error
  def disk_used(sbx) do
    args = ["-s", "-c", "-x", "-P", "-B1", "--", sbx.copy_dir, sbx.home]
    # The C locale: `only_vanished?/1` reads du's messages.
    opts = [timeout_ms: @du_timeout_ms, max_bytes: 1024 * 1024, env: [{"LC_ALL", "C"}]]

    t0 = System.monotonic_time(:millisecond)
    du_res = sbx.exec.run("du", args, opts)
    if path = System.get_env("RSOLV_DU_TRACE") do
      File.write!(path, inspect({System.os_time(:millisecond), sbx.container, System.monotonic_time(:millisecond) - t0, (case du_res do {:ok, %{status: st, output: o}} -> {st, o |> String.split("\n") |> Enum.reject(&(&1 =~ ~r/^\d+\t\//)) |> Enum.take(20)}; other -> other end)}, limit: :infinity, printable_limit: :infinity) <> "\n", [:append])
    end
    with {:ok, %{status: status, output: output}} when status in [0, 1] <- du_res,
         true <- status == 0 or only_vanished?(output),
         [_, total] <- Regex.run(~r/^(\d+)\ttotal$/m, output),
         {:ok, %{status: 0, output: df}} <-
           sbx.exec.run("df", ["-B1", "--output=used,iused", "--", sbx.copy_dir], opts),
         [_, fs, inodes] <- Regex.run(~r/^\s*(\d+)\s+(\d+)\s*$/m, df) do
      if path = System.get_env("RSOLV_DU_TRACE"), do: File.write!(path, "  df fs=#{fs} inodes=#{inodes}\n", [:append])
      {:ok,
       %{
         du: String.to_integer(total),
         fs: String.to_integer(fs),
         inodes: String.to_integer(inodes)
       }}
    else
      _no_total -> :error
    end
  end

  # du 9.4 exits 1 for an entry removed between its listing and its stat or
  # open, as installs do all the time; what's gone holds no bytes du missed.
  # Its messages are the C locale's (`disk_used/1` runs it with LC_ALL=C).
  defp only_vanished?(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reject(&(&1 =~ ~r/\A\d+\t/))
    |> Enum.all?(
      &(&1 =~ ~r/\Adu: cannot (access|read directory) .*: No such file or directory\z/)
    )
  end

  @doc """
  Runs `fun` (the sandbox's steps) while a watchdog measures `disk_used/1`
  every `poll_ms`: past any of `limits` (`%{du:, fs:, inodes:}`), or with no
  measure, it kills the
  sandbox, and the answer is `{:error, :disk_limit}` whatever `fun` returned.
  When `fun` returns, the watchdog finishes the measure in flight and takes
  one more; either over budget, or no answer within 35 s (du's 30 s and a
  margin), is `{:error, :disk_limit}` too. The bind mounts have no portable
  quota, so this is the bound.

  ponytail: a burst between two polls overshoots by whatever it writes in
  `poll_ms` (plus du's own time); a hard bound needs a quota (xfs project
  quotas, btrfs subvolumes) or a size-limited loop device per copy.
  """
  @spec watched(t(), map(), pos_integer(), (-> result)) ::
          result | {:error, :disk_limit}
        when result: term()
  def watched(sbx, limits, poll_ms, fun) do
    ref = make_ref()
    role = self()
    {:ok, watchdog} = Task.start_link(fn -> watch(sbx, limits, poll_ms, {role, ref}) end)

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
        if path = System.get_env("RSOLV_DU_TRACE"), do: File.write!(path, "  STOP-WAIT TIMEOUT\n", [:append])
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
  defp watch(sbx, limits, poll_ms, {role, ref} = tell) do
    receive do
      {:stop, ^ref} ->
        send(role, {ref, verdict(disk_used(sbx), limits)})
    after
      poll_ms ->
        case verdict(disk_used(sbx), limits) do
          :within ->
            watch(sbx, limits, poll_ms, tell)

          :disk_limit ->
            send(role, {ref, :disk_limit})
            sbx.exec.run("docker", ["kill", sbx.ids.sandbox], timeout_ms: @setup_timeout_ms)
        end
    end
  end

  defp verdict({:ok, used}, limits) do
    v = if Enum.all?(limits, fn {key, max} -> Map.fetch!(used, key) <= max end),
      do: :within,
      else: :disk_limit
    if path = System.get_env("RSOLV_DU_TRACE"), do: File.write!(path, "  VERDICT #{v} used=#{inspect(used)} limits=#{inspect(limits)}\n", [:append])
    v
  end

  defp verdict(:error, _limits) do
    if path = System.get_env("RSOLV_DU_TRACE"), do: File.write!(path, "  VERDICT disk_limit NO-MEASURE\n", [:append])
    :disk_limit
  end

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

  @doc """
  `stop/2`, confirmed (RFC-150 §5, B2 and B7): `docker rm -f` of the sandbox
  and its proxy must exit 0, and then `docker inspect` of each must answer
  that there's no such container. Only then does it remove the network and
  the directories the sandbox made, and answer `:ok`. A failure, a timeout,
  any other answer, or a sandbox whose container ID was never recorded, is
  `:error`, and every directory stays: something may still be running in
  it. With a `deadline` (monotonic milliseconds), each call gets at most
  what's left before it, and one with nothing left is `:error`.
  """
  @spec stop_confirmed(t() | nil, IO.device(), integer() | nil) :: :ok | :error
  def stop_confirmed(sbx, io \\ :stdio, deadline \\ nil)
  def stop_confirmed(nil, _io, _deadline), do: :ok

  def stop_confirmed(%__MODULE__{ids: %{sandbox: _}} = sbx, io, deadline) do
    ids = Enum.flat_map([:sandbox, :proxy], &List.wrap(sbx.ids[&1]))
    # 60 s per call, or what's left before the deadline.
    limit = fn -> @setup_timeout_ms |> within(deadline) |> elem(0) end

    with :ok <- remove(sbx.exec, ["rm", "-f"], ids, limit.()),
         true <- Enum.all?(ids, &gone?(sbx.exec, &1, limit.())) do
      remove(sbx.exec, ["network", "rm"], List.wrap(sbx.ids[:network]), limit.())
      Enum.each(sbx.dirs, &remove_dir(&1, io))
    else
      _not_confirmed -> :error
    end
  end

  def stop_confirmed(_unrecorded, _io, _deadline), do: :error

  defp gone?(_exec, _id, 0), do: false

  defp gone?(exec, id, limit_ms) do
    case exec.run("docker", ["inspect", "--type", "container", "--format", "{{.Id}}", id],
           timeout_ms: limit_ms
         ) do
      {:ok, %{status: status, output: output}} when status != 0 ->
        String.trim(output) =~
          ~r/\A(?:Error response from daemon|Error|error): No such (?:container|object): #{Regex.escape(id)}\z/i

      _found_or_unanswered ->
        false
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

  defp remove(exec, command, ids, limit_ms \\ @setup_timeout_ms)
  defp remove(_exec, _command, [], _limit_ms), do: :ok
  defp remove(_exec, _command, _ids, 0), do: :error

  defp remove(exec, command, ids, limit_ms) do
    case exec.run("docker", command ++ ids, timeout_ms: limit_ms) do
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
