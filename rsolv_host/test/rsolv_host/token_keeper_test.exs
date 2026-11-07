defmodule RsolvHost.TokenKeeperTest do
  use ExUnit.Case, async: true

  alias RsolvHost.{Oidc, Platform, TokenKeeper}

  @moduletag :tmp_dir
  @run "0b0e5f7c-7d3c-4d8e-9a55-3f6f1b0c2a11"
  @base String.duplicate("b", 40)

  setup %{tmp_dir: dir} do
    {:ok, io} = StringIO.open("")

    env = %{
      "RUNNER_TEMP" => dir,
      "ACTIONS_ID_TOKEN_REQUEST_URL" => "https://token.actions.example/id?v=1",
      "ACTIONS_ID_TOKEN_REQUEST_TOKEN" => "request-token"
    }

    counter = :counters.new(1, [])

    Req.Test.stub(Oidc, fn conn ->
      :counters.add(counter, 1, 1)
      Req.Test.json(conn, %{value: "e30.e30.jwt-#{:counters.get(counter, 1)}"})
    end)

    %{env: env, io: io}
  end

  defp token_json(raw, expires_in_s) do
    %{
      token: raw,
      expires_at:
        DateTime.utc_now()
        |> DateTime.add(expires_in_s)
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601(),
      protocol_version: 1,
      pipeline_run_id: @run,
      base_sha: @base,
      target_branch: "main"
    }
  end

  defp start(context, opts \\ []) do
    TokenKeeper.start_link([role: :work, issue: 7, env: context.env, io: context.io] ++ opts)
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  describe "start_link/1" do
    test "exchanges once, masks the token, and serves it with its binding", context do
      Req.Test.stub(Platform, fn conn ->
        assert conn.request_path == "/api/v1/runs/token"

        Req.Test.json(
          conn,
          token_json("rsolv_rt_firstAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", 3_600)
        )
      end)

      assert {:ok, keeper} = start(context)

      assert {:ok,
              %{
                raw: "rsolv_rt_firstAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                binding: %{"pipeline_run_id" => @run, "base_sha" => @base}
              }} =
               TokenKeeper.token(keeper)

      assert {:ok, {_in, out}} = StringIO.close(context.io)
      assert out =~ "::add-mask::rsolv_rt_firstAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n"
    end

    test "hands the token to a retry in a file only the runner user can read", context do
      Req.Test.stub(
        Platform,
        &Req.Test.json(
          &1,
          token_json("rsolv_rt_firstAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", 3_600)
        )
      )

      {:ok, _keeper} = start(context)
      path = TokenKeeper.handoff_path(context.env, :work, 7)

      assert path == Path.join([context.tmp_dir, "rsolv", "run-token-work-7.json"])
      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600

      assert %{
               "raw" => "rsolv_rt_firstAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
               "binding" => %{"base_sha" => @base}
             } =
               path |> File.read!() |> JSON.decode!()
    end

    test "when the exchange was already used, fails with the platform's refusal", context do
      Req.Test.stub(Platform, fn conn ->
        conn |> Plug.Conn.put_status(409) |> Req.Test.json(%{error: "already_exchanged"})
      end)

      assert start(context) == {:error, {:platform, 409, "already_exchanged"}}
    end

    test "when OIDC is unavailable, fails before calling the platform", context do
      Req.Test.stub(Platform, fn _conn -> flunk("no exchange expected") end)

      assert start(%{context | env: Map.delete(context.env, "ACTIONS_ID_TOKEN_REQUEST_TOKEN")}) ==
               {:error, :oidc_unavailable}
    end
  end

  describe "refresh" do
    test "when due, refreshes with a fresh OIDC token and the old token as bearer", context do
      test = self()

      Req.Test.stub(Platform, fn conn ->
        case conn.request_path do
          "/api/v1/runs/token" ->
            Req.Test.json(
              conn,
              token_json("rsolv_rt_firstAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", 3_600)
            )

          "/api/v1/runs/token/refresh" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)

            send(
              test,
              {:refresh, Plug.Conn.get_req_header(conn, "authorization"), JSON.decode!(body)}
            )

            Req.Test.json(
              conn,
              token_json("rsolv_rt_secondAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", 3_600)
            )
        end
      end)

      {:ok, keeper} = start(context, refresh_margin_s: 3_599)

      assert_receive {:refresh, ["Bearer rsolv_rt_firstAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"],
                      %{"oidc_token" => "e30.e30.jwt-2"}},
                     2_000

      eventually(fn ->
        match?(
          {:ok, %{raw: "rsolv_rt_secondAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}},
          TokenKeeper.token(keeper)
        )
      end)
    end

    test "when refresh keeps failing, retries, then reports the token expired", context do
      test = self()

      Req.Test.stub(Platform, fn conn ->
        case conn.request_path do
          "/api/v1/runs/token" ->
            Req.Test.json(
              conn,
              token_json("rsolv_rt_firstAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", 1)
            )

          "/api/v1/runs/token/refresh" ->
            send(test, :refresh_attempt)
            Plug.Conn.send_resp(conn, 503, "")
        end
      end)

      {:ok, keeper} = start(context, retry_ms: 10)

      assert_receive :refresh_attempt, 1_000
      assert_receive :refresh_attempt, 1_000
      eventually(fn -> TokenKeeper.token(keeper) == {:error, :token_expired} end)
    end
  end

  describe "start_link/1 with resume" do
    test "refreshes the first attempt's token instead of exchanging", context do
      path = TokenKeeper.handoff_path(context.env, :work, 7)
      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        JSON.encode!(%{
          raw: "rsolv_rt_firstAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
          expires_at: "2026-11-06T12:00:00Z",
          binding: %{}
        })
      )

      Req.Test.stub(Platform, fn conn ->
        assert conn.request_path == "/api/v1/runs/token/refresh"

        assert Plug.Conn.get_req_header(conn, "authorization") == [
                 "Bearer rsolv_rt_firstAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
               ]

        Req.Test.json(
          conn,
          token_json("rsolv_rt_resumedAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", 3_600)
        )
      end)

      assert {:ok, keeper} = start(context, resume: true)

      assert {:ok,
              %{
                raw: "rsolv_rt_resumedAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                binding: %{"pipeline_run_id" => @run}
              }} =
               TokenKeeper.token(keeper)
    end

    test "refuses a malformed hand-off token without masking it", context do
      path = TokenKeeper.handoff_path(context.env, :work, 7)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, JSON.encode!(%{raw: "rsolv_rt_x\n::stop-commands::m", binding: %{}}))
      Req.Test.stub(Platform, fn _conn -> flunk("no refresh expected") end)

      assert start(context, resume: true) == {:error, :resume_unavailable}
      assert {:ok, {_in, ""}} = StringIO.close(context.io)
    end

    test "when there is no hand-off file, the resume is unavailable", context do
      assert start(context, resume: true) == {:error, :resume_unavailable}
    end
  end

  describe "discard/3" do
    test "deletes the hand-off file", context do
      Req.Test.stub(
        Platform,
        &Req.Test.json(
          &1,
          token_json("rsolv_rt_firstAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", 3_600)
        )
      )

      {:ok, _keeper} = start(context)

      assert TokenKeeper.discard(context.env, :work, 7) == :ok
      refute File.exists?(TokenKeeper.handoff_path(context.env, :work, 7))
    end
  end
end
