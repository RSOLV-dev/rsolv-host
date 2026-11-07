defmodule RsolvHost.Release do
  @moduledoc """
  The release step that runs before Burrito wraps the binary (ADR-077; Burrito
  spike condition 2). Every Burrito target must name a local `custom_erts`
  tarball whose SHA-256 matches `erts.lock`; otherwise the build stops. Burrito
  then never downloads its unhashed musl ERTS, and never embeds the musl loader
  it writes to `/tmp`.
  """

  defmodule NoMuslLoader do
    @moduledoc """
    A Burrito `build` pre-step. With a glibc `custom_erts`, Burrito 1.6.0 sets
    no musl loader path, but its wrapper still `@embedFile`s
    `src/musl-runtime.so` (in a branch that never runs when the path is empty),
    so the file must exist. This writes it empty, after checking that neither
    Burrito nor the environment asks the wrapper to write a loader to `/tmp`.
    """

    @behaviour Burrito.Builder.Step

    @var "__BURRITO_MUSL_RUNTIME_PATH"

    @impl true
    @doc "Writes an empty `src/musl-runtime.so`; raises `Mix.Error` if a musl loader path is set."
    @spec execute(Burrito.Builder.Context.t()) :: Burrito.Builder.Context.t()
    def execute(%Burrito.Builder.Context{self_dir: dir, extra_build_env: env} = context) do
      if List.keymember?(env, @var, 0) or System.get_env(@var) not in [nil, ""],
        do: Mix.raise("Burrito would write a musl loader to /tmp (#{@var} is set)")

      File.write!(Path.join([dir, "src", "musl-runtime.so"]), "")
      context
    end
  end

  defmodule PatchLauncher do
    @moduledoc """
    A Burrito `build` pre-step: applies `patches/burrito-launcher-env.patch` to
    Burrito 1.6.0's `src/erlang_launcher.zig` before the wrapper is built. The
    patched launcher refuses `ERL_*FLAGS`, `ERL_LIBS` and `ERL_COMPILER_OPTIONS`
    (exit 2) and removes every `LD_*` variable and `EMU` before it starts
    `erlexec`. The launcher must hash to Burrito 1.6.0's (then it's patched) or
    to the patched result; anything else stops the build.
    """

    @behaviour Burrito.Builder.Step

    @patch Path.expand("../../patches/burrito-launcher-env.patch", __DIR__)
    @external_resource @patch
    @upstream "22ad426844e788dada6f8e4be250af1dba98e7c43363a71c461971bed5770f01"
    @patched "2d0e8aa845e8ae2d4f2e5e935ef5ba01ae851e0c17edd0cc9801dd22db2eb070"

    @impl true
    @doc "Patches the launcher in Burrito's `self_dir`; raises `Mix.Error` unless it ends patched."
    @spec execute(Burrito.Builder.Context.t()) :: Burrito.Builder.Context.t()
    def execute(%Burrito.Builder.Context{self_dir: dir} = context) do
      launcher = Path.join([dir, "src", "erlang_launcher.zig"])

      case RsolvHost.Release.sha256_file(launcher) do
        @patched -> :ok
        @upstream -> patch(dir, launcher)
        _other -> Mix.raise("#{launcher} is not Burrito 1.6.0's launcher; refusing to patch it")
      end

      context
    end

    defp patch(dir, launcher) do
      {out, status} =
        System.cmd("patch", ["--batch", "--forward", "-p1", "-d", dir, "-i", @patch])

      unless status == 0 and RsolvHost.Release.sha256_file(launcher) == @patched,
        do: Mix.raise("patching #{launcher} failed: #{out}")
    end
  end

  @doc """
  Checks the ERTS tarball of every target being built (all of them, or only
  `BURRITO_TARGET` when that's set) and returns `release` with each one's
  `custom_erts` pointing at the checked bytes: the tarball is copied into a new
  private (0700) directory, and that copy must match `erts.lock`. Burrito
  unpacks the copy, so changing the source after this step changes nothing.
  Raises `Mix.Error` naming the target otherwise.

  Options: `:lock` (default `"erts.lock"`), `:env` (default
  `System.get_env/0`) and `:stage_root` (default `System.tmp_dir!/0`).
  """
  @spec verify_erts(Mix.Release.t(), keyword()) :: Mix.Release.t()
  def verify_erts(%Mix.Release{options: options} = release, opts \\ []) do
    lock = opts |> Keyword.get(:lock, "erts.lock") |> File.read!() |> JSON.decode!()
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
    stage = opts |> Keyword.get_lazy(:stage_root, &System.tmp_dir!/0) |> private_dir()

    targets =
      for {name, target} <- options |> Keyword.fetch!(:burrito) |> Keyword.fetch!(:targets) do
        if building?(name, env) do
          staged =
            stage_target(Atom.to_string(name), target[:custom_erts], lock["targets"], stage)

          {name, Keyword.put(target, :custom_erts, staged)}
        else
          {name, target}
        end
      end

    %{release | options: put_in(options, [:burrito, :targets], targets)}
  end

  # A new directory only this user can enter; File.mkdir! fails if it exists.
  defp private_dir(root) do
    dir =
      Path.join(
        root,
        "rsolv-host-erts-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      )

    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    dir
  end

  defp building?(name, %{"BURRITO_TARGET" => only}), do: Atom.to_string(name) == only
  defp building?(_name, _env), do: true

  defp stage_target(name, nil, _locked, _stage),
    do: Mix.raise("ERTS #{name}: no custom_erts, so Burrito would download its musl ERTS")

  defp stage_target(name, path, locked, stage) do
    staged = Path.join(stage, "#{name}.tar.gz")

    with %{"sha256" => "" <> want} when want != "" <- locked[name],
         true <- String.ends_with?(path, ".tar.gz") and File.regular?(path),
         :ok <- File.cp(path, staged),
         ^want <- sha256_file(staged) do
      staged
    else
      nil ->
        Mix.raise("ERTS #{name}: not in erts.lock")

      %{} ->
        Mix.raise("ERTS #{name}: erts.lock has no SHA-256")

      false ->
        Mix.raise("ERTS #{name}: #{path} is not a local .tar.gz file")

      {:error, reason} ->
        Mix.raise("ERTS #{name}: can't stage #{path}: #{:file.format_error(reason)}")

      _other ->
        Mix.raise("ERTS #{name}: #{path} doesn't match its erts.lock SHA-256")
    end
  end

  @doc false
  @spec sha256_file(Path.t()) :: String.t()
  def sha256_file(path) do
    path
    |> File.stream!(64 * 1024)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
