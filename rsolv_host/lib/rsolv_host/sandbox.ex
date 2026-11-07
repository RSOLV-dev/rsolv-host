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

  alias RsolvHost.Egress

  defstruct [:container, :network, :proxy, :exec, egress: :proxy]

  @type t :: %__MODULE__{
          container: String.t(),
          network: String.t() | nil,
          proxy: String.t() | nil,
          exec: module(),
          egress: :proxy | :none
        }

  @setup_timeout_ms 60_000
  # An image pull can be slow; the sandbox image carries every toolchain.
  @pull_timeout_ms 900_000
  @kill_after_s "10"
  @host_grace_ms 30_000

  @doc """
  The `docker run` argv for the sandbox. `opts` has `:name`, `:network`,
  `:copy_dir`, `:home_dir`, `:uid`, `:gid`, `:proxy_ip`, `:image` and
  optionally `:egress`.
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
      [
        "--user",
        "#{opts.uid}:#{opts.gid}",
        "--cap-drop",
        "ALL",
        "--security-opt",
        "no-new-privileges"
      ] ++
      ["--pids-limit", "4096", "--tmpfs", "/tmp:exec"] ++
      ["-e", "LANG=C.UTF-8", "-e", "CI=true", "-e", "HOME=/opt/home"] ++
      proxy_env(egress, opts.proxy_ip) ++
      ["-v", opts.copy_dir <> ":/work", "-v", opts.home_dir <> ":/opt/home", "-w", "/work"] ++
      ["--entrypoint", "sleep", opts.image, "86400"]
  end

  defp network(:proxy, network), do: network
  defp network(:none, _network), do: "none"

  defp proxy_env(:none, _ip), do: []

  defp proxy_env(:proxy, ip) do
    url = "http://#{ip}:3128"

    ["-e", "HTTP_PROXY=" <> url, "-e", "HTTPS_PROXY=" <> url] ++
      ["-e", "http_proxy=" <> url, "-e", "https_proxy=" <> url, "-e", "NO_PROXY="]
  end

  @doc """
  Starts the sandbox. Options: `:name` (the container), `:network`, `:copy_dir`
  (the copy to mount; its owner, the host's own non-root user, becomes the
  sandbox user), `:runner_temp`,
  `:egress` (`:proxy` or `:none`), `:image` (default: the pinned sandbox
  image), `:probe` (the proxy readiness check, `fn ip -> :ok | :error end`),
  `:stat` (how the copy is stat'ed, default `File.stat!/1`) and `:exec`.
  """
  @spec start(keyword()) ::
          {:ok, t()}
          | {:error, {:sandbox_setup, atom()} | {:sandbox, :enoent} | :sandbox_image_unpinned}
  def start(opts) do
    image =
      Keyword.get_lazy(opts, :image, fn -> Application.fetch_env!(:rsolv_host, :sandbox_image) end)

    egress = Keyword.get(opts, :egress, :proxy)

    sbx = %__MODULE__{
      container: Keyword.fetch!(opts, :name),
      network: if(egress == :proxy, do: Keyword.fetch!(opts, :network)),
      proxy: if(egress == :proxy, do: Keyword.fetch!(opts, :name) <> "-proxy"),
      exec: Keyword.get_lazy(opts, :exec, &RsolvHost.exec/0),
      egress: egress
    }

    with :ok <- pinned(image),
         home_dir = home(opts),
         {:ok, uid, gid} <-
           user(
             Keyword.get(opts, :stat, &File.stat!/1).(Keyword.fetch!(opts, :copy_dir)),
             File.stat!(home_dir)
           ),
         {:ok, proxy_ip} <- start_proxy(sbx, opts),
         :ok <-
           step(
             sbx,
             :sandbox_run,
             run_args(%{
               name: sbx.container,
               network: sbx.network,
               copy_dir: Keyword.fetch!(opts, :copy_dir),
               home_dir: home_dir,
               uid: uid,
               gid: gid,
               proxy_ip: proxy_ip,
               image: image,
               egress: egress
             }),
             @pull_timeout_ms
           ) do
      {:ok, sbx}
    else
      {:error, :sandbox_image_unpinned} = unpinned ->
        unpinned

      {:error, _reason} = error ->
        stop(sbx)
        error
    end
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

  defp start_proxy(%{egress: :none}, _opts), do: {:ok, nil}

  defp start_proxy(sbx, opts) do
    dir = Path.join([Keyword.fetch!(opts, :runner_temp), "rsolv", "proxy-" <> sbx.container])
    conf = Path.join(dir, "squid.conf")
    allowlist = Path.join(dir, "allowlist.txt")
    File.mkdir_p!(dir)
    File.write!(conf, Egress.squid_conf())
    File.write!(allowlist, Egress.allowlist())
    proxy_image = Application.fetch_env!(:rsolv_host, :proxy_image)

    with :ok <- step(sbx, :network_create, ["network", "create", "--internal", sbx.network]),
         :ok <-
           step(
             sbx,
             :proxy_run,
             ["run", "-d", "--name", sbx.proxy, "-v", conf <> ":/etc/squid/squid.conf:ro"] ++
               ["-v", allowlist <> ":/etc/squid/allowlist.txt:ro", proxy_image],
             @pull_timeout_ms
           ),
         :ok <- step(sbx, :proxy_connect, ["network", "connect", sbx.network, sbx.proxy]),
         {:ok, proxy_ip} <- ip(sbx, sbx.network),
         {:ok, bridge_ip} <- ip(sbx, "bridge"),
         :ok <- ready(Keyword.get(opts, :probe, &probe/1), bridge_ip) do
      {:ok, proxy_ip}
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

  defp docker(sbx, name, args, timeout_ms) do
    case sbx.exec.run("docker", args, timeout_ms: timeout_ms) do
      {:ok, %{status: 0, output: output}} -> {:ok, output}
      {:error, :enoent} -> {:error, {:sandbox, :enoent}}
      _failed -> {:error, {:sandbox_setup, name}}
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

  @doc "Takes the sandbox off the proxy's network: from here on it has no network."
  @spec disconnect(t()) :: :ok | {:error, term()}
  def disconnect(%__MODULE__{egress: :none}), do: :ok

  def disconnect(sbx),
    do: step(sbx, :network_disconnect, ["network", "disconnect", sbx.network, sbx.container])

  @doc "Removes the sandbox, its proxy and its network. Always safe to call."
  @spec stop(t() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(sbx) do
    _ =
      sbx.exec.run("docker", ["rm", "-f" | Enum.reject([sbx.container, sbx.proxy], &is_nil/1)],
        timeout_ms: @setup_timeout_ms
      )

    if sbx.network,
      do: sbx.exec.run("docker", ["network", "rm", sbx.network], timeout_ms: @setup_timeout_ms)

    :ok
  end
end
