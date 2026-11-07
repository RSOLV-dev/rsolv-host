defmodule RsolvHost.ReleaseTest do
  use ExUnit.Case, async: true

  alias RsolvHost.Release

  @moduletag :tmp_dir

  defp setup_erts(tmp_dir, lock_hashes) do
    tarballs =
      for {name, bytes} <- [linux_x86_64: "x86 erts", linux_aarch64: "arm erts"], into: %{} do
        path = Path.join(tmp_dir, "#{name}.tar.gz")
        File.write!(path, bytes)
        {name, path}
      end

    hashes = %{
      linux_x86_64: sha256("x86 erts"),
      linux_aarch64: sha256("arm erts")
    }

    lock = %{
      "otp" => "29.0.4",
      "targets" => %{
        "linux_x86_64" => %{
          "cpu" => "x86_64",
          "sha256" => lock_hashes[:linux_x86_64] || hashes.linux_x86_64
        },
        "linux_aarch64" => %{
          "cpu" => "aarch64",
          "sha256" => lock_hashes[:linux_aarch64] || hashes.linux_aarch64
        }
      }
    }

    lock_path = Path.join(tmp_dir, "erts.lock")
    File.write!(lock_path, JSON.encode!(lock))
    {tarballs, lock_path}
  end

  defp release(tarballs) do
    targets =
      for {name, path} <- tarballs,
          do: {name, [os: :linux, cpu: :x86_64, custom_erts: path]}

    struct(Mix.Release, name: :rsolv_host, options: [burrito: [targets: targets]])
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  describe "verify_erts/2" do
    test "when every target's tarball matches the lock, returns the release unchanged",
         %{tmp_dir: tmp_dir} do
      {tarballs, lock} = setup_erts(tmp_dir, %{})
      release = release(tarballs)

      assert Release.verify_erts(release, lock: lock, env: %{}) == release
    end

    test "when a tarball's hash differs from the lock, raises naming the target",
         %{tmp_dir: tmp_dir} do
      {tarballs, lock} = setup_erts(tmp_dir, %{linux_aarch64: String.duplicate("0", 64)})

      assert_raise Mix.Error, ~r/linux_aarch64.*SHA-256/, fn ->
        Release.verify_erts(release(tarballs), lock: lock, env: %{})
      end
    end

    test "when a tarball is missing, raises naming the target", %{tmp_dir: tmp_dir} do
      {tarballs, lock} = setup_erts(tmp_dir, %{})
      File.rm!(tarballs.linux_x86_64)

      assert_raise Mix.Error, ~r/linux_x86_64/, fn ->
        Release.verify_erts(release(tarballs), lock: lock, env: %{})
      end
    end

    test "when a target's lock hash is empty, raises naming the target", %{tmp_dir: tmp_dir} do
      {tarballs, lock} = setup_erts(tmp_dir, %{linux_aarch64: ""})

      assert_raise Mix.Error, ~r/linux_aarch64/, fn ->
        Release.verify_erts(release(tarballs), lock: lock, env: %{})
      end
    end

    test "when BURRITO_TARGET picks one target, only that one is checked", %{tmp_dir: tmp_dir} do
      {tarballs, lock} = setup_erts(tmp_dir, %{linux_aarch64: ""})
      release = release(tarballs)

      assert Release.verify_erts(release, lock: lock, env: %{"BURRITO_TARGET" => "linux_x86_64"}) ==
               release
    end

    test "when BURRITO_TARGET picks a target whose hash differs, raises", %{tmp_dir: tmp_dir} do
      {tarballs, lock} = setup_erts(tmp_dir, %{linux_x86_64: String.duplicate("0", 64)})
      env = %{"BURRITO_TARGET" => "linux_x86_64"}

      assert_raise Mix.Error, ~r/linux_x86_64/, fn ->
        Release.verify_erts(release(tarballs), lock: lock, env: env)
      end
    end

    test "when a target has no custom_erts (Burrito's downloaded musl ERTS), raises",
         %{tmp_dir: tmp_dir} do
      {_tarballs, lock} = setup_erts(tmp_dir, %{})

      release =
        struct(Mix.Release,
          name: :rsolv_host,
          options: [burrito: [targets: [linux_x86_64: [os: :linux, cpu: :x86_64]]]]
        )

      assert_raise Mix.Error, ~r/linux_x86_64.*custom_erts/, fn ->
        Release.verify_erts(release, lock: lock, env: %{})
      end
    end

    test "when a target's custom_erts is a URL, raises", %{tmp_dir: tmp_dir} do
      {_tarballs, lock} = setup_erts(tmp_dir, %{})
      url = "https://example.invalid/linux_x86_64.tar.gz"

      release =
        struct(Mix.Release,
          name: :rsolv_host,
          options: [
            burrito: [targets: [linux_x86_64: [os: :linux, cpu: :x86_64, custom_erts: url]]]
          ]
        )

      assert_raise Mix.Error, ~r/linux_x86_64/, fn ->
        Release.verify_erts(release, lock: lock, env: %{})
      end
    end

    test "when a target isn't in the lock, raises", %{tmp_dir: tmp_dir} do
      {tarballs, lock} = setup_erts(tmp_dir, %{})
      release = release(Map.put(tarballs, :linux_riscv64, tarballs.linux_x86_64))

      assert_raise Mix.Error, ~r/linux_riscv64/, fn ->
        Release.verify_erts(release, lock: lock, env: %{})
      end
    end
  end

  describe "NoMuslLoader.execute/1" do
    defp context(tmp_dir, extra_build_env) do
      File.mkdir_p!(Path.join(tmp_dir, "src"))

      struct(Burrito.Builder.Context,
        self_dir: tmp_dir,
        extra_build_env: extra_build_env,
        halted: false
      )
    end

    test "when no musl loader path is set, writes an empty musl-runtime.so for the wrapper build",
         %{tmp_dir: tmp_dir} do
      context = context(tmp_dir, [{"__BURRITO_RELEASE_NAME", "rsolv_host"}])

      assert Release.NoMuslLoader.execute(context) == context
      assert File.read!(Path.join([tmp_dir, "src", "musl-runtime.so"])) == ""
    end

    test "when Burrito asks for a musl loader in /tmp, raises", %{tmp_dir: tmp_dir} do
      context = context(tmp_dir, [{"__BURRITO_MUSL_RUNTIME_PATH", "/tmp/libc-musl-x.so"}])

      assert_raise Mix.Error, ~r/musl/, fn -> Release.NoMuslLoader.execute(context) end
      refute File.exists?(Path.join([tmp_dir, "src", "musl-runtime.so"]))
    end
  end

  describe "PatchLauncher.execute/1" do
    @patched_sha "2d0e8aa845e8ae2d4f2e5e935ef5ba01ae851e0c17edd0cc9801dd22db2eb070"

    # Burrito 1.6.0's own launcher, in a copy of its src/ under tmp_dir.
    defp burrito_copy(tmp_dir) do
      src = Path.join(tmp_dir, "src")
      File.mkdir_p!(src)
      launcher = Path.join(src, "erlang_launcher.zig")
      File.cp!(Path.join(Mix.Project.deps_paths()[:burrito], "src/erlang_launcher.zig"), launcher)

      if File.read!(launcher) =~ "rsolvhostScrubEnv" do
        patch = Path.expand("../../patches/burrito-launcher-env.patch", __DIR__)
        {_out, 0} = System.cmd("patch", ["--batch", "-R", "-p1", "-d", tmp_dir, "-i", patch])
      end

      {struct(Burrito.Builder.Context, self_dir: tmp_dir, extra_build_env: [], halted: false),
       launcher}
    end

    defp sha256_of(path), do: path |> File.read!() |> sha256()

    test "when the launcher is Burrito 1.6.0's, patches it to scrub the VM's environment",
         %{tmp_dir: tmp_dir} do
      {context, launcher} = burrito_copy(tmp_dir)

      assert Release.PatchLauncher.execute(context) == context
      assert sha256_of(launcher) == @patched_sha
      assert File.read!(launcher) =~ "rsolvhostScrubEnv(env_map);"
    end

    test "when the launcher is already patched, leaves it as it is", %{tmp_dir: tmp_dir} do
      {context, launcher} = burrito_copy(tmp_dir)
      Release.PatchLauncher.execute(context)

      assert Release.PatchLauncher.execute(context) == context
      assert sha256_of(launcher) == @patched_sha
    end

    test "when the launcher is neither (another Burrito), raises and leaves it",
         %{tmp_dir: tmp_dir} do
      {context, launcher} = burrito_copy(tmp_dir)
      File.write!(launcher, "pub fn launch() void {}\n")

      assert_raise Mix.Error, ~r/erlang_launcher.zig/, fn ->
        Release.PatchLauncher.execute(context)
      end

      assert File.read!(launcher) == "pub fn launch() void {}\n"
    end
  end
end
