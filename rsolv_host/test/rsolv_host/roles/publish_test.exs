defmodule RsolvHost.Roles.PublishTest do
  use ExUnit.Case, async: true

  alias RsolvCore.{ChangeSet, Decision}
  alias RsolvCore.ChangeSet.Entry
  alias RsolvHost.{FakeGithub, Oidc, Outcome, Platform}
  alias RsolvHost.Roles.Publish

  @moduletag :tmp_dir
  @run "0b0e5f7c-7d3c-4d8e-9a55-3f6f1b0c2a11"
  @branch "rsolv/fix-7"
  @base_files %{
    "gradlew" => {"100755", "#!/bin/sh\n"},
    "win.txt" => {"100644", "a\r\nb\r\n"},
    "docs/naïve.md" => {"100644", "old\n"},
    "empty" => {"100644", ""},
    "lib/app.rb" => {"100644", "query(params)\n"}
  }
  @post_images %{
    "docs/naïve.md" => "new\n",
    "lib/app.rb" => "query(sanitize(params))\n",
    "test/app_test.rb" => "assert_raises\n",
    "win.txt" => "a\r\nb\r\nc\r\n"
  }
  @pr_body "Fixes #7"
  @comment_body "Fixed in the linked pull request."

  setup %{tmp_dir: dir} do
    gh = FakeGithub.start()
    base = FakeGithub.seed(gh, @base_files)
    {public, secret} = :crypto.generate_key(:eddsa, :ed25519)

    keys =
      JSON.encode!([
        %{
          kid: "k1",
          public_key: Base.url_encode64(public, padding: false),
          not_after: "2099-01-01"
        }
      ])

    claims = Base.url_encode64(~s({"check_run_id":"9001","run_id":"41"}), padding: false)
    Req.Test.stub(Oidc, &Req.Test.json(&1, %{value: "e30." <> claims <> ".sig"}))
    {:ok, io} = StringIO.open("")

    env = %{
      "RUNNER_TEMP" => dir,
      "GITHUB_RUN_ID" => "41",
      "GITHUB_REPOSITORY_ID" => "555",
      "GITHUB_RUN_ATTEMPT" => "1",
      "GITHUB_REPOSITORY" => "acme/app",
      "GITHUB_TOKEN" => "ghs_test",
      "RSOLV_DECISION_KEYS" => keys,
      "ACTIONS_ID_TOKEN_REQUEST_URL" => "https://token.actions.example/id?v=1",
      "ACTIONS_ID_TOKEN_REQUEST_TOKEN" => "t"
    }

    %{gh: gh, base: base, secret: secret, env: env, io: io}
  end

  defp blob(bytes), do: ChangeSet.blob_sha(bytes)

  defp change_set do
    [
      %Entry{
        path: "docs/naïve.md",
        op: :modify,
        base_mode: "100644",
        base_blob_sha: blob("old\n"),
        mode: "100644",
        new_blob_sha: blob("new\n")
      },
      %Entry{
        path: "empty",
        op: :delete,
        base_mode: "100644",
        base_blob_sha: blob(""),
        mode: nil,
        new_blob_sha: nil
      },
      %Entry{
        path: "lib/app.rb",
        op: :modify,
        base_mode: "100644",
        base_blob_sha: blob("query(params)\n"),
        mode: "100644",
        new_blob_sha: blob("query(sanitize(params))\n")
      },
      %Entry{
        path: "test/app_test.rb",
        op: :add,
        base_mode: nil,
        base_blob_sha: nil,
        mode: "100644",
        new_blob_sha: blob("assert_raises\n")
      },
      %Entry{
        path: "win.txt",
        op: :modify,
        base_mode: "100644",
        base_blob_sha: blob("a\r\nb\r\n"),
        mode: "100644",
        new_blob_sha: blob("a\r\nb\r\nc\r\n")
      }
    ]
  end

  defp decision(context, overrides \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    entries = change_set()

    Map.merge(
      %{
        "v" => 1,
        "kid" => "k1",
        "decision_id" => "d_1",
        "run_id" => 41,
        "repository_id" => 555,
        "issue" => 7,
        "work_attempt" => 1,
        "verify_attempt" => 1,
        "publish_attempt" => 1,
        "check_run_id_work" => 9000,
        "check_run_id_verify" => 9000,
        "check_run_id_publish" => 9001,
        "base_sha" => context.base,
        "target_branch" => "main",
        "branch" => @branch,
        "change_set" => ChangeSet.to_json(entries),
        "change_set_digest" => ChangeSet.digest(entries),
        "red_paths" => ["test/app_test.rb"],
        "policy_version" => "p1",
        "verify_mode" => "job",
        "effects" => %{
          "pr_title" => "Fix SQL injection in lib/app.rb",
          "pr_body_sha256" => sha256(@pr_body),
          "labels" => ["rsolv:mitigated"],
          "comments" => [%{"issue" => 7, "body_sha256" => sha256(@comment_body)}],
          "red_commit_message" => "test: prove the SQL injection (RED)",
          "fix_commit_message" => "fix: sanitize the query"
        },
        "issued_at" => now |> DateTime.add(-60) |> DateTime.to_iso8601(),
        "expires_at" => now |> DateTime.add(600) |> DateTime.to_iso8601()
      },
      overrides
    )
  end

  defp sha256(text), do: :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower)

  # The platform's publish side: the signed decision with `bodies`, the
  # post-images, and the `published` report (answered with `published`).
  defp platform(context, opts \\ []) do
    test = self()

    envelope =
      Decision.sign(
        Keyword.get_lazy(opts, :decision, fn -> decision(context) end),
        context.secret
      )

    envelope = Keyword.get(opts, :tamper, & &1).(envelope)

    bodies =
      Keyword.get(opts, :bodies, %{
        "pr_body" => @pr_body,
        "comments" => [%{"issue" => 7, "body" => @comment_body}]
      })

    images = Keyword.get(opts, :images, @post_images)
    rotated = :atomics.new(1, [])
    first = "rsolv_rt_" <> String.duplicate("A", 43)
    second = "rsolv_rt_" <> String.duplicate("B", 43)

    Req.Test.stub(Platform, fn conn ->
      bearer = Plug.Conn.get_req_header(conn, "authorization")
      rotated? = :atomics.get(rotated, 1) == 1

      case {conn.method, conn.request_path} do
        {"POST", "/api/v1/runs/token"} ->
          ttl_s = Keyword.get(opts, :token_ttl_s, 3_600)

          json =
            RsolvHost.PlatformStub.token(first)
            |> Map.put(
              :expires_at,
              DateTime.utc_now() |> DateTime.add(ttl_s) |> DateTime.to_iso8601()
            )

          Req.Test.json(conn, json)

        {"POST", "/api/v1/runs/token/refresh"} ->
          :atomics.put(rotated, 1, 1)
          Req.Test.json(conn, RsolvHost.PlatformStub.token(second))

        {_method, _path} when bearer == ["Bearer " <> first] and rotated? ->
          conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{error: "invalid_token"})

        _route ->
          platform_route(conn, test, opts, envelope, bodies, images)
      end
    end)
  end

  defp platform_route(conn, test, opts, envelope, bodies, images) do
    case {conn.method, conn.request_path} do
      {"GET", "/api/v1/runs/" <> @run <> "/issues/7/decision"} ->
        Keyword.get(opts, :decision_response, fn conn ->
          Plug.Conn.send_resp(conn, 200, JSON.encode!(Map.put(envelope, "bodies", bodies)))
        end).(conn)

      {"GET", "/api/v1/runs/" <> @run <> "/issues/7/post-images"} ->
        Process.sleep(Keyword.get(opts, :images_delay_ms, 0))

        Req.Test.json(conn, %{
          files: Map.new(images, fn {path, bytes} -> {path, Base.encode64(bytes)} end)
        })

      {"POST", "/api/v1/runs/" <> @run <> "/issues/7/published"} ->
        {body, conn} = RsolvHost.PlatformStub.body(conn)
        send(test, {:published, body})
        {status, json} = Keyword.get(opts, :published, {200, %{}})
        conn |> Plug.Conn.put_status(status) |> Req.Test.json(json)
    end
  end

  defp run(context), do: Publish.run(%{issue: 7}, context.env, io: context.io)

  defp posts(gh), do: for({"POST", path} <- FakeGithub.requests(gh), do: path)

  defp head(context) do
    {:ok, gh} = RsolvHost.GitHub.new(context.env)
    {:ok, sha} = RsolvHost.GitHub.get_ref(gh, @branch)
    sha
  end

  describe "run/3" do
    test "writes the RED commit, then the fix, and opens the signed pull request", context do
      platform(context)

      assert run(context) == :ok

      fix = head(context)

      %{parents: [red], message: "fix: sanitize the query"} =
        FakeGithub.commit_info(context.gh, fix)

      %{parents: [base], message: "test: prove the SQL injection (RED)"} =
        FakeGithub.commit_info(context.gh, red)

      assert base == context.base

      assert FakeGithub.files(context.gh, red) ==
               Map.put(@base_files, "test/app_test.rb", {"100644", "assert_raises\n"})

      expected =
        @base_files
        |> Map.delete("empty")
        |> Map.merge(Map.new(@post_images, fn {path, bytes} -> {path, {"100644", bytes}} end))

      assert FakeGithub.files(context.gh, fix) == expected
      assert {"100755", _} = FakeGithub.files(context.gh, fix)["gradlew"]

      %{pulls: [pull], labels: labels, comments: comments} = FakeGithub.writes(context.gh)

      assert pull == %{
               "title" => "Fix SQL injection in lib/app.rb",
               "body" => @pr_body,
               "head" => @branch,
               "base" => "main"
             }

      assert labels == [{100, %{"labels" => ["rsolv:mitigated"]}}]
      assert comments == [{7, %{"body" => @comment_body}}]

      assert_received {:published,
                       %{
                         "decision_id" => "d_1",
                         "pr_number" => 100,
                         "pr_url" => "https://github.com/acme/app/pull/100",
                         "branch" => @branch,
                         "red_commit_sha" => ^red,
                         "fix_commit_sha" => ^fix
                       }}
    end

    test "when the target branch moved on from the base, opens the PR with only signed effects",
         context do
      platform(context)
      FakeGithub.compare(context.gh, "behind")

      assert run(context) == :ok

      %{pulls: [_pull], comments: comments} = FakeGithub.writes(context.gh)
      assert comments == [{7, %{"body" => @comment_body}}]
    end
  end

  describe "run/3 refusals before any GitHub write (acceptance 12)" do
    defp refused(context, expected) do
      result = run(context)

      assert result == {:error, expected}
      assert Outcome.exit_code(result) == 2
      assert posts(context.gh) == []
    end

    test "a decision signed by another key", context do
      platform(context, tamper: &put_in(&1, ["decision", "branch"], "rsolv/elsewhere"))
      refused(context, :bad_signature)
    end

    test "a decision bound to another run", context do
      platform(context, decision: decision(context, %{"run_id" => 42}))
      refused(context, {:binding_mismatch, "run_id"})
    end

    test "a decision bound to another check run", context do
      platform(context, decision: decision(context, %{"check_run_id_publish" => 1}))
      refused(context, {:binding_mismatch, "check_run_id_publish"})
    end

    test "a post-image whose blob differs from the change set", context do
      platform(context, images: %{@post_images | "lib/app.rb" => "evil\n"})
      refused(context, :digest_mismatch)
    end

    test "a post-image set with an extra file", context do
      platform(context, images: Map.put(@post_images, "extra.rb", "x"))
      refused(context, :digest_mismatch)
    end

    test "a post-image set missing a file", context do
      platform(context, images: Map.delete(@post_images, "lib/app.rb"))
      refused(context, :digest_mismatch)
    end

    test "a pull request body whose digest differs", context do
      platform(context,
        bodies: %{"pr_body" => "evil", "comments" => [%{"issue" => 7, "body" => @comment_body}]}
      )

      refused(context, :digest_mismatch)
    end

    test "a comment whose digest differs", context do
      platform(context,
        bodies: %{"pr_body" => @pr_body, "comments" => [%{"issue" => 7, "body" => "evil"}]}
      )

      refused(context, :digest_mismatch)
    end

    test "a base that no longer matches the change set", context do
      gh = FakeGithub.start()
      base = FakeGithub.seed(gh, %{@base_files | "lib/app.rb" => {"100644", "changed\n"}})
      context = %{context | gh: gh, base: base}
      platform(context)

      refused(context, {:base_mismatch, "lib/app.rb"})
    end

    test "no decision keys, or unparseable ones", context do
      platform(context)

      for keys <- ["", "[]", "not json"] do
        assert Publish.run(%{issue: 7}, %{context.env | "RSOLV_DECISION_KEYS" => keys},
                 io: context.io
               ) ==
                 {:error, :decision_keys_invalid}
      end

      assert posts(context.gh) == []
    end

    test "a target branch that no longer contains the base (compare says ahead or diverged)",
         context do
      for status <- ["ahead", "diverged"] do
        platform(context)
        FakeGithub.compare(context.gh, status)

        refused(context, :base_not_on_target)
      end
    end

    test "a target branch GitHub can't compare with the base", context do
      platform(context)
      FakeGithub.compare(context.gh, :not_found)

      refused(context, {:github, 404, :not_found})
    end

    test "a change set that touches .github/, whatever its case", context do
      for path <- [".github/workflows/ci.yml", ".GitHub/workflows/ci.yml", ".github/CODEOWNERS"] do
        entries = [
          %Entry{
            path: path,
            op: :add,
            base_mode: nil,
            base_blob_sha: nil,
            mode: "100644",
            new_blob_sha: blob("on: push\n")
          }
          | change_set()
        ]

        entries = Enum.sort_by(entries, & &1.path)

        decision =
          decision(context, %{
            "change_set" => ChangeSet.to_json(entries),
            "change_set_digest" => ChangeSet.digest(entries)
          })

        platform(context, decision: decision, images: Map.put(@post_images, path, "on: push\n"))

        refused(context, :workflow_path)
      end
    end

    test "a platform that doesn't serve decisions yet", context do
      platform(context,
        decision_response: &Plug.Conn.send_resp(&1, 404, ~s({"error":"not_found"}))
      )

      refused(context, :publish_unavailable)
    end
  end

  describe "run/3 and the decision's expiry" do
    # A decision valid for 1 to 2 more seconds, and how long to wait past it.
    defp short_lived(context) do
      expires = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(2)
      wait_ms = DateTime.diff(expires, DateTime.utc_now(), :millisecond) + 200
      {decision(context, %{"expires_at" => DateTime.to_iso8601(expires)}), wait_ms}
    end

    test "when the post-images arrive after it, writes nothing", context do
      {decision, wait_ms} = short_lived(context)
      platform(context, decision: decision, images_delay_ms: wait_ms)

      result = run(context)

      assert result == {:error, :expired}
      assert Outcome.exit_code(result) == 2
      assert posts(context.gh) == []
      refute_received {:published, _}
    end

    test "when a GitHub write returns after it, starts no other write", context do
      {decision, wait_ms} = short_lived(context)
      platform(context, decision: decision)
      FakeGithub.delay(context.gh, "POST", "/git/refs", wait_ms)

      assert run(context) == {:error, :expired}
      assert %{pulls: [], labels: [], comments: []} = FakeGithub.writes(context.gh)
      refute_received {:published, _}
    end

    test "when the PR lookup returns after it, opens no pull request", context do
      {decision, wait_ms} = short_lived(context)
      platform(context, decision: decision)
      FakeGithub.delay(context.gh, "GET", "/pulls", wait_ms)

      assert run(context) == {:error, :expired}
      refute "/pulls" in posts(context.gh)
      refute_received {:published, _}
    end

    test "when retries of a failing PR lookup outlast it, opens no pull request", context do
      {decision, wait_ms} = short_lived(context)
      platform(context, decision: decision)
      FakeGithub.fail(context.gh, "GET", "/pulls", 3)
      FakeGithub.delay(context.gh, "GET", "/pulls", div(wait_ms, 3) + 1)

      assert run(context) == {:error, :expired}
      refute "/pulls" in posts(context.gh)
    end

    test "when the PR is opened after it, adds no label and posts no comment", context do
      {decision, wait_ms} = short_lived(context)
      platform(context, decision: decision)
      FakeGithub.delay(context.gh, "POST", "/pulls", wait_ms)

      assert run(context) == {:error, :expired}
      assert %{pulls: [_opened], labels: [], comments: []} = FakeGithub.writes(context.gh)
    end

    test "when the comment scan returns after it, posts no comment", context do
      {decision, wait_ms} = short_lived(context)
      platform(context, decision: decision)
      FakeGithub.delay(context.gh, "GET", "/issues/7/comments", wait_ms)

      assert run(context) == {:error, :expired}
      assert FakeGithub.writes(context.gh).comments == []
    end
  end

  describe "run/3 while the run token is refreshed" do
    test "reports with the current token, not the one the refresh rotated away", context do
      # Refresh is due 300 s before expiry: here, about a second in.
      platform(context, token_ttl_s: 301, images_delay_ms: 1_500)

      assert run(context) == :ok
      assert_received {:published, %{"decision_id" => "d_1"}}
    end
  end

  describe "run/3 re-run after an earlier attempt (resume)" do
    # The branch's real chain: [fix, red] from the ref down.
    defp chain(context) do
      fix = head(context)
      %{parents: [red]} = FakeGithub.commit_info(context.gh, fix)
      {red, fix}
    end

    test "after a complete run, reuses the branch and PR and writes nothing twice", context do
      platform(context)
      :ok = run(context)
      assert_received {:published, _first}
      {red, fix} = chain(context)

      assert run(context) == :ok

      assert %{pulls: [_one], comments: [{7, _one_comment}]} = FakeGithub.writes(context.gh)
      assert length(FakeGithub.writes(context.gh).labels) == 1
      assert Enum.count(FakeGithub.requests(context.gh), &(&1 == {"POST", "/pulls"})) == 1

      assert_received {:published,
                       %{"pr_number" => 100, "red_commit_sha" => ^red, "fix_commit_sha" => ^fix}}
    end

    test "after the report failed, finishes and reports the commits the branch holds", context do
      platform(context, published: {503, %{}})
      assert run(context) == {:error, {:platform, 503, nil}}
      {red, fix} = chain(context)

      platform(context)
      assert run(context) == :ok

      assert %{pulls: [_one], comments: [_one_comment]} = FakeGithub.writes(context.gh)
      assert_received {:published, %{"red_commit_sha" => ^red, "fix_commit_sha" => ^fix}}
    end

    test "after GitHub opened the PR but the answer was lost, doesn't open another", context do
      platform(context)
      FakeGithub.drop_response(context.gh, "POST", "/pulls")
      first = run(context)

      assert {:error, {:transport, :closed}} = first
      assert Outcome.exit_code(first) == 3

      assert run(context) == :ok
      assert %{pulls: [_one], comments: [_one_comment]} = FakeGithub.writes(context.gh)
    end

    test "after a comment was posted but the answer was lost, doesn't post it again", context do
      platform(context)
      FakeGithub.drop_response(context.gh, "POST", "/issues/7/comments")
      assert {:error, {:transport, :closed}} = run(context)

      assert run(context) == :ok
      assert FakeGithub.writes(context.gh).comments == [{7, %{"body" => @comment_body}}]
    end

    test "counts only the host's own comments: an identical one by someone else isn't it",
         context do
      platform(context)
      FakeGithub.put_comment(context.gh, 7, @comment_body, "mallory")

      assert run(context) == :ok
      assert FakeGithub.writes(context.gh).comments == [{7, %{"body" => @comment_body}}]
    end

    test "with a GITHUB_TOKEN (GraphQL `github-actions`, REST `github-actions[bot]`), posts nothing new",
         context do
      platform(context)
      :ok = run(context)

      assert run(context) == :ok
      assert FakeGithub.writes(context.gh).comments == [{7, %{"body" => @comment_body}}]
    end

    test "when GraphQL gives no database id, matches the login with `[bot]` stripped", context do
      platform(context)
      FakeGithub.viewer(context.gh, %{"login" => "github-actions", "databaseId" => nil})
      :ok = run(context)

      assert run(context) == :ok
      assert FakeGithub.writes(context.gh).comments == [{7, %{"body" => @comment_body}}]
    end

    test "a user whose login matches the bot's but whose id doesn't isn't the host", context do
      platform(context)
      FakeGithub.put_comment(context.gh, 7, @comment_body, "github-actions")

      assert run(context) == :ok
      assert FakeGithub.writes(context.gh).comments == [{7, %{"body" => @comment_body}}]
    end

    test "when the token's identity is unknown, posts no comment", context do
      platform(context)
      FakeGithub.viewer(context.gh, %{"login" => nil, "databaseId" => 41_898_282})

      assert {:error, :malformed_response} = run(context)
      assert FakeGithub.writes(context.gh).comments == []
    end

    test "when an issue has more comments than it can read, posts nothing and says so",
         context do
      platform(context)
      for n <- 1..1_000, do: FakeGithub.put_comment(context.gh, 7, "comment #{n}", "someone")

      result = run(context)

      assert result == {:error, :comment_scan_incomplete}
      assert Outcome.exit_code(result) == 2
      assert FakeGithub.writes(context.gh).comments == []
      refute_received {:published, _}
    end

    test "after its PR was merged (and the branch deleted), reports that PR and writes nothing visible",
         context do
      platform(context, published: {503, %{}})
      {:error, {:platform, 503, nil}} = run(context)
      assert_received {:published, _first}
      {red, fix} = chain(context)
      FakeGithub.close_pull(context.gh, 100, :merged)

      platform(context)
      assert run(context) == :ok

      assert Enum.count(posts(context.gh), &(&1 in ["/git/refs", "/pulls"])) == 2
      assert %{pulls: [_one], comments: [_one_comment]} = FakeGithub.writes(context.gh)

      assert_received {:published,
                       %{"pr_number" => 100, "red_commit_sha" => ^red, "fix_commit_sha" => ^fix}}
    end

    test "refuses a merged PR from the branch whose head isn't the signed commits", context do
      platform(context)
      FakeGithub.put_ref(context.gh, @branch, context.base)

      FakeGithub.put_pull(context.gh, %{
        "title" => "Fix SQL injection in lib/app.rb",
        "body" => @pr_body,
        "head" => @branch,
        "base" => "main"
      })

      FakeGithub.close_pull(context.gh, 100, :merged)

      result = run(context)

      assert result == {:error, :pull_collision}
      assert Outcome.exit_code(result) == 2
      refute Enum.any?(posts(context.gh), &(&1 in ["/git/refs", "/pulls"]))
      refute_received {:published, _}
    end

    test "after its PR was closed unmerged, refuses: closing it rejected the fix", context do
      platform(context, published: {503, %{}})
      {:error, {:platform, 503, nil}} = run(context)
      assert_received {:published, _first}
      FakeGithub.close_pull(context.gh, 100, :unmerged)
      writes = FakeGithub.writes(context.gh)
      before = length(posts(context.gh))

      platform(context)
      result = run(context)

      assert result == {:error, :pull_closed}
      assert Outcome.exit_code(result) == 2
      assert FakeGithub.writes(context.gh) == writes

      refute Enum.any?(Enum.drop(posts(context.gh), before), &(&1 in ["/git/refs", "/pulls"]))
      refute_received {:published, _}
    end

    test "refuses a branch with the fix's tree but another history", context do
      platform(context)
      :ok = run(context)
      {_red, fix} = chain(context)
      %{tree: tree} = FakeGithub.commit_info(context.gh, fix)

      for {parents, message} <- [
            {[], "fix: sanitize the query"},
            {[context.base], "fix: sanitize the query"},
            {[fix], "something else"}
          ] do
        FakeGithub.put_ref(
          context.gh,
          @branch,
          FakeGithub.put_commit(context.gh, tree, parents, message)
        )

        assert run(context) == {:error, :branch_collision}
      end
    end

    test "refuses an open PR from the branch whose title or body isn't the signed one", context do
      platform(context)

      FakeGithub.put_pull(context.gh, %{
        "title" => "Something else",
        "body" => @pr_body,
        "head" => @branch,
        "base" => "main"
      })

      result = run(context)

      assert result == {:error, :pull_collision}
      assert Outcome.exit_code(result) == 2
      assert %{labels: [], comments: []} = FakeGithub.writes(context.gh)
    end
  end

  describe "run/3 after the commits" do
    test "refuses a written tree that differs from the change set, before any ref", context do
      platform(context)

      FakeGithub.tamper(context.gh, fn
        %{"path" => "lib/app.rb"} = entry -> %{entry | "sha" => blob("evil\n")}
        entry -> entry
      end)

      assert run(context) == {:error, {:tree_mismatch, "lib/app.rb"}}
      refute "/git/refs" in posts(context.gh)
      assert FakeGithub.writes(context.gh).pulls == []
    end

    test "refuses a branch that holds something else", context do
      platform(context)
      FakeGithub.put_ref(context.gh, @branch, context.base)

      assert run(context) == {:error, :branch_collision}
      assert FakeGithub.writes(context.gh).pulls == []
    end

    test "a decision already consumed is configuration", context do
      platform(context, published: {409, %{error: "already_published"}})

      result = run(context)

      assert result == {:error, {:platform, 409, "already_published"}}
      assert Outcome.exit_code(result) == 2
    end
  end
end
