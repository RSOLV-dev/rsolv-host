defmodule RsolvHost.Workspace do
  @moduledoc """
  The copies of the checkout that sandboxes mount. Every copy is made before the
  first sandbox starts, with `cp -a`, so the BEAM never reads file contents and
  symlinks stay symlinks. After a sandbox starts the host never opens a path in a
  mounted tree (RFC-150 acceptance 5a).
  """

  @copy_timeout_ms 600_000

  @doc "Copies the tree at `src` into a new directory `dest`. Option: `:exec`."
  @spec copy(Path.t(), Path.t(), keyword()) ::
          :ok | {:error, :exists | {:sandbox_setup, :copy} | {:sandbox, :enoent}}
  def copy(src, dest, opts \\ []) do
    exec = Keyword.get_lazy(opts, :exec, &RsolvHost.exec/0)

    if File.exists?(dest) do
      {:error, :exists}
    else
      File.mkdir_p!(dest)

      case exec.run("cp", ["-a", "--", src <> "/.", dest], timeout_ms: @copy_timeout_ms) do
        {:ok, %{status: 0}} -> :ok
        {:error, :enoent} -> {:error, {:sandbox, :enoent}}
        _failed -> {:error, {:sandbox_setup, :copy}}
      end
    end
  end
end
