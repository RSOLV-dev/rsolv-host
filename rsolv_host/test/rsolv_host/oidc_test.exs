defmodule RsolvHost.OidcTest do
  use ExUnit.Case, async: true

  alias RsolvHost.Oidc

  @env %{
    "ACTIONS_ID_TOKEN_REQUEST_URL" => "https://token.actions.example/id?api-version=2.0",
    "ACTIONS_ID_TOKEN_REQUEST_TOKEN" => "request-token"
  }

  defp io do
    {:ok, io} = StringIO.open("")
    io
  end

  defp output(io), do: io |> StringIO.contents() |> elem(1)

  describe "fetch/2" do
    test "requests a token for the fixed audience with the request token, and masks it" do
      Req.Test.stub(Oidc, fn conn ->
        assert conn.request_path == "/id"

        assert URI.decode_query(conn.query_string) == %{
                 "api-version" => "2.0",
                 "audience" => "https://api.rsolv.dev"
               }

        assert Plug.Conn.get_req_header(conn, "authorization") == ["bearer request-token"]
        Req.Test.json(conn, %{value: "header.payload.sig"})
      end)

      io = io()

      assert Oidc.fetch(@env, io: io) == {:ok, "header.payload.sig"}
      assert output(io) == "::add-mask::header.payload.sig\n"
    end

    test "never derives the audience from the platform URL" do
      Req.Test.stub(Oidc, fn conn ->
        assert %{"audience" => "https://api.rsolv.dev"} = URI.decode_query(conn.query_string)
        Req.Test.json(conn, %{value: "jwt"})
      end)

      for url <- [
            "https://api.rsolv.ai.",
            "https://api.rsolv.dev.",
            "https://api.rsolv-staging.com."
          ] do
        assert {:ok, "jwt"} = Oidc.fetch(Map.put(@env, "RSOLV_API_URL", url), io: io())
      end
    end

    test "when the job lacks id-token: write, says so" do
      assert Oidc.fetch(%{}, io: io()) == {:error, :oidc_unavailable}

      assert Oidc.fetch(Map.delete(@env, "ACTIONS_ID_TOKEN_REQUEST_TOKEN"), io: io()) ==
               {:error, :oidc_unavailable}
    end

    test "a refusal is its HTTP status" do
      Req.Test.stub(Oidc, &Plug.Conn.send_resp(&1, 403, "no"))

      assert Oidc.fetch(@env, io: io()) == {:error, {:oidc_http, 403}}
    end

    test "a response without a token is refused" do
      Req.Test.stub(Oidc, &Req.Test.json(&1, %{value: 1}))

      assert Oidc.fetch(@env, io: io()) == {:error, :oidc_unavailable}
    end
  end

  describe "claims/1" do
    test "decodes the payload without verifying it" do
      payload = Base.url_encode64(~s({"check_run_id":42,"run_id":"9"}), padding: false)

      assert Oidc.claims("e30." <> payload <> ".sig") ==
               {:ok, %{"check_run_id" => 42, "run_id" => "9"}}
    end

    test "refuses anything that isn't three segments with a JSON object payload" do
      assert Oidc.claims("nope") == {:error, :malformed_jwt}
      assert Oidc.claims("a.!!.c") == {:error, :malformed_jwt}
    end
  end
end
