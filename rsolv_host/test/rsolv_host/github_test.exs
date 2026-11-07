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
end
