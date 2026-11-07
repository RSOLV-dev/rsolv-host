defmodule RsolvHost.GitHubTest do
  use ExUnit.Case, async: true

  alias RsolvHost.GitHub

  @env %{"GITHUB_TOKEN" => "ghs_test", "GITHUB_REPOSITORY" => "acme/app"}

  defp gh do
    {:ok, gh} = GitHub.new(@env)
    gh
  end

  describe "new/1" do
    test "addresses the job's repository with its token and the REST API version" do
      Req.Test.stub(GitHub, fn conn ->
        assert conn.request_path == "/repos/acme/app/issues"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer ghs_test"]
        assert Plug.Conn.get_req_header(conn, "x-github-api-version") == ["2022-11-28"]
        assert Plug.Conn.get_req_header(conn, "accept") == ["application/vnd.github+json"]
        Req.Test.json(conn, [])
      end)

      assert {:ok, []} = GitHub.list_issues(gh(), ["rsolv:detected"], 1)
    end

    test "when the token or repository is missing or malformed, names the variable" do
      assert GitHub.new(Map.delete(@env, "GITHUB_TOKEN")) ==
               {:error, {:missing_env, "GITHUB_TOKEN"}}

      assert GitHub.new(%{@env | "GITHUB_REPOSITORY" => "acme/../x/y"}) ==
               {:error, {:missing_env, "GITHUB_REPOSITORY"}}
    end
  end

  describe "the calls" do
    test "list_issues/3 asks for one page of open issues with the labels" do
      Req.Test.stub(GitHub, fn conn ->
        assert URI.decode_query(conn.query_string) ==
                 %{"state" => "open", "per_page" => "100", "labels" => "a,b", "page" => "2"}

        Req.Test.json(conn, [%{number: 1}])
      end)

      assert {:ok, [%{"number" => 1}]} = GitHub.list_issues(gh(), ["a", "b"], 2)
    end

    test "create_label/2 treats an existing label as success" do
      Req.Test.stub(GitHub, fn conn ->
        assert {conn.method, conn.request_path} == {"POST", "/repos/acme/app/labels"}
        conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{message: "already_exists"})
      end)

      assert GitHub.create_label(gh(), %{
               "name" => "security",
               "color" => "d73a4a",
               "description" => ""
             }) == :ok
    end

    test "create_issue/2 returns the new issue" do
      Req.Test.stub(GitHub, fn conn ->
        assert {conn.method, conn.request_path} == {"POST", "/repos/acme/app/issues"}

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{number: 9, html_url: "https://github.com/acme/app/issues/9"})
      end)

      assert {:ok, %{"number" => 9}} =
               GitHub.create_issue(gh(), %{"title" => "t", "body" => "b", "labels" => []})
    end

    test "a refusal is the status and a fixed code, never GitHub's text" do
      Req.Test.stub(GitHub, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{message: "Resource not accessible by integration"})
      end)

      assert GitHub.create_issue(gh(), %{}) == {:error, {:github, 403, :forbidden}}
    end
  end

  describe "retries" do
    defp answer(answers) do
      test = self()
      counter = :counters.new(1, [])

      Req.Test.stub(GitHub, fn conn ->
        :counters.add(counter, 1, 1)
        send(test, {:attempt, conn.method, conn.request_path})

        case Enum.at(answers, :counters.get(counter, 1) - 1, List.last(answers)) do
          :closed -> Req.Test.transport_error(conn, :closed)
          {status, json} -> conn |> Plug.Conn.put_status(status) |> Req.Test.json(json)
        end
      end)
    end

    defp attempts do
      receive do
        {:attempt, _method, _path} -> 1 + attempts()
      after
        0 -> 0
      end
    end

    @sha String.duplicate("a", 40)

    test "an issue, comment, label, pull request, commit or ref write that may have happened isn't repeated" do
      for call <- [
            fn -> GitHub.create_issue(gh(), %{title: "t"}) end,
            fn -> GitHub.comment(gh(), 7, "b") end,
            fn -> GitHub.add_labels(gh(), 7, ["l"]) end,
            fn -> GitHub.create_label(gh(), %{name: "l"}) end,
            fn -> GitHub.create_pull(gh(), %{title: "t"}) end,
            fn -> GitHub.create_commit(gh(), "m", @sha, [@sha]) end,
            fn -> GitHub.create_ref(gh(), "b", @sha) end
          ] do
        answer([:closed, {201, %{sha: @sha, number: 1}}])

        assert call.() == {:error, {:transport, :closed}}
        assert attempts() == 1
      end
    end

    test "a read, or a content-addressed blob or tree, is repeated after a transient failure" do
      for call <- [
            fn -> GitHub.get_commit(gh(), @sha) end,
            fn -> GitHub.create_blob(gh(), "x") end,
            fn -> GitHub.create_tree(gh(), @sha, []) end
          ] do
        answer([:closed, {200, %{sha: @sha}}])

        assert {:ok, _} = call.()
        assert attempts() == 2
      end
    end

    test "past the deadline, sends nothing and answers the deadline's reason" do
      answer([{201, %{number: 1}}])
      gh = gh()

      gh = %{
        gh
        | req: RsolvHost.Http.deadline(gh.req, System.monotonic_time(:millisecond), :expired)
      }

      assert GitHub.comment(gh, 7, "b") == {:error, :expired}
      assert attempts() == 0
    end

    test "a server's Retry-After is cut to the deadline, and the retry is then refused" do
      Req.Test.stub(GitHub, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "60")
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{})
      end)

      gh = gh()
      deadline = System.monotonic_time(:millisecond) + 200
      gh = %{gh | req: RsolvHost.Http.deadline(gh.req, deadline, :expired)}

      assert GitHub.get_commit(gh, @sha) == {:error, :expired}
      assert System.monotonic_time(:millisecond) - deadline < 500
    end

    test "never follows a redirect" do
      Req.Test.stub(GitHub, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://exfil.example/repos/acme/app/issues")
        |> Plug.Conn.send_resp(307, "")
      end)

      assert GitHub.create_issue(gh(), %{title: "t"}) == {:error, {:github, 307, :refused}}
    end
  end
end
