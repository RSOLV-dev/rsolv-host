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
end
