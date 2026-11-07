defmodule RsolvHost.ApplicationTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias RsolvHost.{CLI, Oidc, Platform, PlatformStub, TokenKeeper}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Req.Test.stub(Oidc, &Req.Test.json(&1, %{value: "e30.e30.sig"}))

    env = %{
      "RUNNER_TEMP" => dir,
      "RSOLV_HOST_INSTALL_DIR" => Path.join(dir, "rsolv-host"),
      "ACTIONS_ID_TOKEN_REQUEST_URL" => "https://token.actions.example/id?v=1",
      "ACTIONS_ID_TOKEN_REQUEST_TOKEN" => "t"
    }

    %{env: env, root: Path.join([dir, "rsolv-host", ".burrito", "r"])}
  end

  # The release entry point, with `role` as the work command and halting recorded.
  defp run(context, role) do
    test = self()
    commands = %{"work" => {role, [issue: :integer], [:issue]}}

    main = fn ->
      CLI.main(["work", "--issue", "7"], context.env, context.root, commands: commands)
    end

    out = capture_io(fn -> RsolvHost.Application.run_cli(main, &send(test, {:halt, &1})) end)
    assert_received {:halt, code}
    {code, out}
  end

  describe "run_cli/2" do
    test "halts with the command's exit code", context do
      assert {0, _out} = run(context, fn _opts, _env -> :ok end)
      assert {3, _out} = run(context, fn _opts, _env -> {:error, :stream_exhausted} end)
    end

    test "when a linked process takes the command down, still halts, with 1", context do
      role = fn _opts, _env ->
        spawn_link(fn -> exit({:secret, "detail"}) end)
        Process.sleep(:infinity)
      end

      {code, out} = run(context, role)

      assert code == 1
      assert out =~ "::error title=RSOLV host client bug::"
      refute out =~ "detail"
    end

    test "when the token keeper dies, the role fails transient and the release halts", context do
      Req.Test.stub(Platform, &Req.Test.json(&1, PlatformStub.token()))

      role = fn _opts, env ->
        {:ok, keeper} =
          TokenKeeper.start(role: :work, issue: 7, env: env, io: StringIO.open("") |> elem(1))

        Process.exit(keeper, :kill)
        result = TokenKeeper.token(keeper)
        TokenKeeper.stop(keeper)
        result
      end

      assert {3, out} = run(context, role)
      assert out =~ "::error title=RSOLV transient failure::"
    end

    test "a slow token refresh doesn't stall the role", context do
      Req.Test.stub(Platform, fn conn ->
        case conn.request_path do
          "/api/v1/runs/token" ->
            Req.Test.json(conn, PlatformStub.token())

          "/api/v1/runs/token/refresh" ->
            # The role runs in the release's CLI process, one of this request's callers.
            for caller <- Process.get(:"$callers"), do: send(caller, {:refreshing, self()})
            Process.sleep(:infinity)
        end
      end)

      role = fn _opts, env ->
        {:ok, io} = StringIO.open("")

        {:ok, keeper} =
          TokenKeeper.start(role: :work, issue: 7, env: env, io: io, refresh_margin_s: 3_599)

        assert_receive {:refreshing, _refresher}, 2_000

        results = for _ <- 1..3, do: TokenKeeper.token(keeper)
        TokenKeeper.stop(keeper)
        if Enum.all?(results, &match?({:ok, _}, &1)), do: :ok, else: {:error, :token_expired}
      end

      assert {0, _out} = run(context, role)
    end
  end
end
