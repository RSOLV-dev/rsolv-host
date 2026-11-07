defmodule RsolvHost.PlatformTest do
  use ExUnit.Case, async: true

  alias RsolvHost.Platform

  @token "rsolv_rt_testAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  @run "0b0e5f7c-7d3c-4d8e-9a55-3f6f1b0c2a11"

  defp req do
    {:ok, req} = Platform.req(%{})
    req
  end

  defp body(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    JSON.decode!(body)
  end

  defp stub(fun), do: Req.Test.stub(Platform, fun)

  describe "req/1" do
    test "defaults to api.rsolv.ai as an absolute name, verifying TLS for the bare name" do
      {:ok, req} = Platform.req(%{})

      assert req.options.base_url == "https://api.rsolv.ai."
      assert req.options.connect_options[:hostname] == "api.rsolv.ai"
      assert req.options.connect_options[:transport_opts][:cacerts] == :public_key.cacerts_get()
    end

    test "accepts api.rsolv.dev and api.rsolv-staging.com as absolute names" do
      for {url, host} <- [
            {"https://api.rsolv.dev.", "api.rsolv.dev"},
            {"https://api.rsolv-staging.com.", "api.rsolv-staging.com"}
          ] do
        assert {:ok, req} = Platform.req(%{"RSOLV_API_URL" => url})
        assert req.options.base_url == url
        assert req.options.connect_options[:hostname] == host
      end
    end

    test "refuses any other URL, including the right hosts without the trailing dot" do
      for url <- [
            "https://evil.example.",
            "https://api.rsolv.ai",
            "https://api.rsolv.dev",
            "http://api.rsolv.ai.",
            "https://api.rsolv.ai./x"
          ] do
        assert Platform.req(%{"RSOLV_API_URL" => url}) == {:error, :api_url_not_allowed}, url
      end
    end

    test "neither decompresses nor decodes response bodies itself" do
      {:ok, req} = Platform.req(%{})

      assert req.options.raw == true
      refute req.options[:compressed]
    end
  end

  describe "exchange/3" do
    test "posts the OIDC token, issue and protocol version, and returns the bound run token" do
      stub(fn conn ->
        assert {conn.method, conn.request_path} == {"POST", "/api/v1/runs/token"}
        assert body(conn) == %{"oidc_token" => "jwt", "issue" => 7, "protocol_version" => 1}

        Req.Test.json(conn, %{
          token: @token,
          role: "work",
          issue: 7,
          expires_at: "2026-11-06T12:00:00Z",
          protocol_version: 1,
          pipeline_run_id: @run,
          base_sha: String.duplicate("a", 40),
          target_branch: "main"
        })
      end)

      assert {:ok, token} = Platform.exchange(req(), "jwt", 7)
      assert token.raw == @token
      assert token.expires_at == ~U[2026-11-06 12:00:00Z]

      assert token.binding == %{
               "pipeline_run_id" => @run,
               "base_sha" => String.duplicate("a", 40),
               "target_branch" => "main"
             }
    end

    test "a scan token is run-wide and carries no binding" do
      stub(fn conn ->
        assert %{"issue" => nil} = body(conn)

        Req.Test.json(conn, %{
          token: @token,
          role: "scan",
          issue: nil,
          expires_at: "2026-11-06T12:00:00Z",
          protocol_version: 1
        })
      end)

      assert {:ok, %{binding: binding}} = Platform.exchange(req(), "jwt", nil)
      assert binding == %{}
    end

    test "when the platform speaks another protocol version, refuses the token" do
      stub(fn conn ->
        Req.Test.json(conn, %{
          token: @token,
          expires_at: "2026-11-06T12:00:00Z",
          protocol_version: 2
        })
      end)

      assert Platform.exchange(req(), "jwt", 7) == {:error, {:protocol_version, 2}}
    end

    test "when the response is malformed, refuses it" do
      stub(&Req.Test.json(&1, %{token: "not-a-run-token", expires_at: "x", protocol_version: 1}))

      assert Platform.exchange(req(), "jwt", 7) == {:error, :malformed_response}
    end

    test "refuses a run token that isn't rsolv_rt_ and 43 base64url characters" do
      valid = "rsolv_rt_" <> String.duplicate("A", 43)

      for raw <- [
            "rsolv_rt_x\n::error::injected-command",
            "rsolv_rt_" <> String.duplicate("A", 42) <> "\r",
            "rsolv_rt_" <> String.duplicate("A", 42) <> "%",
            "rsolv_rt_" <> String.duplicate("A", 42),
            valid <> "A",
            "rsolv_rt_" <> String.duplicate("A", 42) <> "=",
            String.replace(valid, "rsolv_rt_", "rsolv_xx_")
          ] do
        stub(
          &Req.Test.json(&1, %{
            token: raw,
            expires_at: "2099-01-01T00:00:00Z",
            protocol_version: 1
          })
        )

        assert Platform.exchange(req(), "jwt", nil) == {:error, :malformed_response}, inspect(raw)
      end

      stub(
        &Req.Test.json(&1, %{
          token: valid,
          expires_at: "2099-01-01T00:00:00Z",
          protocol_version: 1
        })
      )

      assert {:ok, %{raw: ^valid}} = Platform.exchange(req(), "jwt", nil)
    end

    test "a refusal is the status and the platform's error code" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(409)
        |> Req.Test.json(%{error: "already_exchanged", message: "x"})
      end)

      assert Platform.exchange(req(), "jwt", 7) == {:error, {:platform, 409, "already_exchanged"}}
    end

    test "an error code that isn't a plain identifier is dropped" do
      stub(fn conn ->
        conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{error: "</script>::add-mask::x"})
      end)

      assert Platform.exchange(req(), "jwt", 7) == {:error, {:platform, 403, nil}}
    end

    test "a connection failure is a transport error" do
      stub(&Req.Test.transport_error(&1, :econnrefused))

      assert Platform.exchange(req(), "jwt", 7) == {:error, {:transport, :econnrefused}}
    end
  end

  describe "refresh/3" do
    test "sends the old token as bearer with a fresh OIDC token and the protocol version" do
      stub(fn conn ->
        assert {conn.method, conn.request_path} == {"POST", "/api/v1/runs/token/refresh"}
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{@token}"]
        assert body(conn) == %{"oidc_token" => "jwt2", "protocol_version" => 1}

        Req.Test.json(conn, %{
          token: "rsolv_rt_newAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
          expires_at: "2026-11-06T13:00:00Z",
          protocol_version: 1
        })
      end)

      assert {:ok, %{raw: "rsolv_rt_newAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}} =
               Platform.refresh(req(), @token, "jwt2")
    end
  end

  describe "the authenticated calls" do
    setup do
      %{bearer: ["Bearer #{@token}"]}
    end

    test "register/3 posts the findings and scan data", %{bearer: bearer} do
      stub(fn conn ->
        assert {conn.method, conn.request_path} == {"POST", "/api/v1/runs/register"}
        assert Plug.Conn.get_req_header(conn, "authorization") == bearer
        assert body(conn) == %{"issues" => [%{"number" => 7}], "files_scanned" => 3}
        Req.Test.json(conn, %{pipeline_run_id: @run, issues: [7]})
      end)

      assert {:ok, %{"pipeline_run_id" => @run}} =
               Platform.register(req(), @token, %{issues: [%{number: 7}], files_scanned: 3})
    end

    test "start_session/4 returns the session, or a cached result" do
      stub(fn conn ->
        assert {conn.method, conn.request_path} == {"POST", "/api/v1/validation/start"}
        assert body(conn) == %{"pipeline_run_id" => @run, "issue_number" => 7}
        Req.Test.json(conn, %{session_id: "s1", stream_url: "/api/v1/validation/stream/s1"})
      end)

      assert {:ok, %{"session_id" => "s1"}} =
               Platform.start_session(req(), @token, :validation, %{
                 pipeline_run_id: @run,
                 issue_number: 7
               })

      stub(&Req.Test.json(&1, %{cached: true, result: %{is_false_positive: true}}))

      assert {:cached, %{"is_false_positive" => true}} =
               Platform.start_session(req(), @token, :validation, %{})
    end

    test "tool_response/5 posts the wire response", %{bearer: bearer} do
      stub(fn conn ->
        assert {conn.method, conn.request_path} == {"POST", "/api/v1/mitigation/tool_response/s1"}
        assert Plug.Conn.get_req_header(conn, "authorization") == bearer
        assert %{"request_id" => "r1", "protocol_version" => 1} = body(conn)
        Req.Test.json(conn, %{success: true})
      end)

      wire = %{"request_id" => "r1", "result" => %{}, "error" => nil, "protocol_version" => 1}
      assert Platform.tool_response(req(), @token, :mitigation, "s1", wire) == :ok
    end

    test "session_status/4 reads the status" do
      stub(fn conn ->
        assert {conn.method, conn.request_path} == {"GET", "/api/v1/validation/status/s1"}
        Req.Test.json(conn, %{status: "streaming"})
      end)

      assert {:ok, %{"status" => "streaming"}} =
               Platform.session_status(req(), @token, :validation, "s1")
    end

    test "upload_result/5 posts the patch base64-encoded" do
      stub(fn conn ->
        assert {conn.method, conn.request_path} ==
                 {"POST", "/api/v1/runs/#{@run}/issues/7/results"}

        assert body(conn) == %{"issue_number" => 7, "patch" => Base.encode64(<<0, 1, 2>>)}
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{patch_bytes: 3})
      end)

      assert Platform.upload_result(req(), @token, @run, 7, <<0, 1, 2>>) == :ok
    end

    test "the scan calls reach their routes" do
      stub(fn conn ->
        Req.Test.json(conn, %{route: "#{conn.method} #{conn.request_path}?#{conn.query_string}"})
      end)

      assert {:ok, %{"route" => "GET /api/v1/patterns?language=ruby&format=enhanced"}} =
               Platform.patterns(req(), @token, "ruby")

      assert {:ok, %{"route" => "GET /api/v1/vulnerability-types/severity-tiers?"}} =
               Platform.severity_tiers(req(), @token)

      assert {:ok, %{"route" => "POST /api/v1/vulnerabilities/validate?"}} =
               Platform.validate(req(), @token, %{})

      assert {:ok, %{"route" => "POST /api/v1/scan/plan?"}} =
               Platform.scan_plan(req(), @token, %{})
    end

    test "the publish calls reach their routes, and the decision comes back as raw bytes" do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/v1/runs/" <> _ = path} ->
            if String.ends_with?(path, "/decision"),
              do: Plug.Conn.send_resp(conn, 200, ~s({"decision":{}})),
              else: Req.Test.json(conn, %{files: %{"a" => "eA=="}})

          {"POST", "/api/v1/runs/" <> _} ->
            assert %{"decision_id" => "d1"} = body(conn)
            Req.Test.json(conn, %{})
        end
      end)

      assert Platform.decision(req(), @token, @run, 7) == {:ok, ~s({"decision":{}})}
      assert {:ok, %{"files" => %{"a" => "eA=="}}} = Platform.post_images(req(), @token, @run, 7)
      assert Platform.published(req(), @token, @run, 7, %{decision_id: "d1"}) == :ok
    end

    test "a response body over the cap is refused" do
      stub(
        &Plug.Conn.send_resp(
          &1,
          200,
          ~s({"x":") <> String.duplicate("a", 17 * 1024 * 1024) <> ~s("})
        )
      )

      assert Platform.severity_tiers(req(), @token) == {:error, {:transport, :response_too_large}}
    end
  end

  describe "retries" do
    # Answers each request with the next of `answers` (:closed is a connection
    # that closes after the platform acted), recording every attempt.
    defp answer(answers) do
      test = self()
      counter = :counters.new(1, [])

      stub(fn conn ->
        :counters.add(counter, 1, 1)
        send(test, {:attempt, conn.method, conn.request_path})

        case Enum.at(answers, :counters.get(counter, 1) - 1, List.last(answers)) do
          :closed -> Req.Test.transport_error(conn, :closed)
          status when is_integer(status) -> Plug.Conn.send_resp(conn, status, "{}")
        end
      end)
    end

    defp attempts(path), do: attempts(path, 0)

    defp attempts(path, n) do
      receive do
        {:attempt, _method, ^path} -> attempts(path, n + 1)
      after
        0 -> n
      end
    end

    test "a request that may have been carried out is never repeated" do
      answer([:closed, 200])

      calls = [
        {"/api/v1/runs/token", fn -> Platform.exchange(req(), "jwt", 7) end},
        {"/api/v1/runs/token/refresh", fn -> Platform.refresh(req(), @token, "jwt") end},
        {"/api/v1/runs/register", fn -> Platform.register(req(), @token, %{issues: []}) end},
        {"/api/v1/runs/#{@run}/issues/7/published",
         fn -> Platform.published(req(), @token, @run, 7, %{}) end},
        {"/api/v1/validation/start",
         fn -> Platform.start_session(req(), @token, :validation, %{}) end}
      ]

      for {path, call} <- calls do
        answer([:closed, 200])

        assert call.() == {:error, {:transport, :closed}}, path
        assert attempts(path) == 1, path
      end
    end

    test "a read, a tool response or a result upload is repeated after a transient failure" do
      for {path, call} <- [
            {"/api/v1/validation/status/s1",
             fn -> Platform.session_status(req(), @token, :validation, "s1") end},
            {"/api/v1/validation/tool_response/s1",
             fn -> Platform.tool_response(req(), @token, :validation, "s1", %{}) end},
            {"/api/v1/runs/#{@run}/issues/7/results",
             fn -> Platform.upload_result(req(), @token, @run, 7, "x") end}
          ] do
        answer([503, 200])

        assert {:ok, _} =
                 then(call.(), fn
                   :ok -> {:ok, :ok}
                   other -> other
                 end)

        assert attempts(path) == 2, path
      end
    end

    test "never follows a redirect" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://exfil.example/collect")
        |> Plug.Conn.send_resp(307, "")
      end)

      assert Platform.exchange(req(), "jwt", 7) == {:error, {:platform, 307, nil}}
    end
  end
end
