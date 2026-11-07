defmodule RsolvHost.Roles.Publish do
  @moduledoc """
  The `publish` role, the host side of RFC-150 §6.2: it writes only what a
  decision signed by the platform allows, through GitHub's Git Data API. There is
  no checkout, no git and no sandbox in this role.

  In order: verify the signed decision against `RSOLV_DECISION_KEYS` and the
  job's own identity; check the unsigned bodies and post-images against their
  signed digests; check the base tree; write the RED commit (exactly the
  `red_paths`) on `base_sha` and the fix commit on it; check both written trees;
  create the branch; open the pull request with its labels and comments; report
  it. Every refusal before the first write is configuration (exit 2): the remedy
  is re-running the issue's workflow for a fresh decision.
  """

  alias RsolvCore.{ChangeSet, Decision}
  alias RsolvHost.{GitHub, GitTree, Oidc, Platform, TokenKeeper}

  @doc "Runs the role. `deps`: `:io`."
  @spec run(map(), map(), keyword()) :: :ok | {:error, term()}
  def run(%{issue: issue}, env, deps \\ []) do
    io = Keyword.get(deps, :io, :stdio)

    with {:ok, keys} <- keys(env),
         {:ok, run_id} <- int_env(env, "GITHUB_RUN_ID"),
         {:ok, repository_id} <- int_env(env, "GITHUB_REPOSITORY_ID"),
         {:ok, attempt} <- int_env(env, "GITHUB_RUN_ATTEMPT"),
         {:ok, gh} <- GitHub.new(env),
         {:ok, check_run_id} <- check_run_id(env, io),
         {:ok, keeper} <- TokenKeeper.start_link(role: :publish, issue: issue, env: env, io: io) do
      expect = %{
        "run_id" => run_id,
        "repository_id" => repository_id,
        "issue" => issue,
        "publish_attempt" => attempt,
        "check_run_id_publish" => check_run_id
      }

      try do
        publish(%{gh: gh, keeper: keeper, issue: issue, keys: keys, expect: expect})
      after
        GenServer.stop(keeper)
      end
    end
  end

  defp keys(env) do
    case Decision.parse_keys(env["RSOLV_DECISION_KEYS"] || "") do
      {:ok, keys} -> {:ok, keys}
      {:error, :invalid_keys} -> {:error, :decision_keys_invalid}
    end
  end

  defp int_env(env, name) do
    with value when is_binary(value) <- env[name],
         {n, ""} when n > 0 <- Integer.parse(value) do
      {:ok, n}
    else
      _missing -> {:error, {:missing_env, name}}
    end
  end

  # The job's own check run, from its own OIDC token.
  defp check_run_id(env, io) do
    with {:ok, jwt} <- Oidc.fetch(env, io: io),
         {:ok, %{"check_run_id" => id}} <- Oidc.claims(jwt),
         {n, ""} when n > 0 <- Integer.parse(to_string(id)) do
      {:ok, n}
    else
      {:error, :oidc_unavailable} = error -> error
      {:error, {:oidc_http, _status}} = error -> error
      {:error, {:transport, _reason}} = error -> error
      _no_claim -> {:error, :oidc_unavailable}
    end
  end

  defp publish(ctx) do
    with {:ok, %{req: req, raw: raw, binding: %{"pipeline_run_id" => run}}} <-
           TokenKeeper.token(ctx.keeper),
         ctx = Map.merge(ctx, %{req: req, raw: raw, run: run}),
         {:ok, verified} <- decision(ctx),
         {:ok, bodies} <- bodies(verified),
         {:ok, images} <- post_images(ctx, verified.change_set),
         :ok <- GitTree.check_base(ctx.gh, verified.decision["base_sha"], verified.change_set),
         {:ok, commits} <- write_commits(ctx, verified.decision, verified.change_set, images),
         :ok <- branch(ctx, verified.decision["branch"], commits) do
      open_pull(ctx, verified.decision, bodies, commits)
    else
      {:ok, _unbound} -> {:error, :run_unbound}
      error -> error
    end
  end

  defp decision(ctx) do
    case Platform.decision(ctx.req, ctx.raw, ctx.run, ctx.issue) do
      {:ok, bytes} ->
        Decision.verify(bytes, ctx.keys, now: DateTime.utc_now(), expect: ctx.expect)

      {:error, {:platform, 404, _code}} ->
        {:error, :publish_unavailable}

      error ->
        error
    end
  end

  # The unsigned bodies, each checked against its signed digest.
  defp bodies(%{decision: %{"effects" => effects}, envelope: envelope}) do
    with %{"bodies" => %{"pr_body" => pr_body, "comments" => comments}}
         when is_binary(pr_body) and is_list(comments) <-
           envelope,
         true <- sha256(pr_body) == effects["pr_body_sha256"],
         true <- length(comments) == length(effects["comments"]),
         true <- Enum.all?(Enum.zip(comments, effects["comments"]), &comment?/1) do
      {:ok, %{pr_body: pr_body, comments: Enum.map(comments, &{&1["issue"], &1["body"]})}}
    else
      _mismatch -> {:error, :digest_mismatch}
    end
  end

  defp comment?(
         {%{"issue" => issue, "body" => body}, %{"issue" => issue, "body_sha256" => digest}}
       )
       when is_binary(body),
       do: sha256(body) == digest

  defp comment?(_pair), do: false

  defp sha256(text), do: :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower)

  # Exactly one post-image per add and modify, each hashing to its new blob SHA.
  defp post_images(ctx, change_set) do
    wanted =
      for %{op: op} = e <- change_set, op != :delete, into: %{}, do: {e.path, e.new_blob_sha}

    with {:ok, %{"files" => %{} = files}} <-
           Platform.post_images(ctx.req, ctx.raw, ctx.run, ctx.issue),
         true <- files |> Map.keys() |> Enum.sort() == wanted |> Map.keys() |> Enum.sort(),
         {:ok, images} <- decode_images(files, wanted) do
      {:ok, images}
    else
      {:error, _reason} = error -> error
      _mismatch -> {:error, :digest_mismatch}
    end
  end

  defp decode_images(files, wanted) do
    Enum.reduce_while(files, {:ok, %{}}, fn {path, encoded}, {:ok, acc} ->
      with true <- is_binary(encoded),
           {:ok, bytes} <- Base.decode64(encoded),
           true <- ChangeSet.blob_sha(bytes) == wanted[path] do
        {:cont, {:ok, Map.put(acc, path, bytes)}}
      else
        _mismatch -> {:halt, {:error, :digest_mismatch}}
      end
    end)
  end

  defp write_commits(ctx, decision, change_set, images) do
    {red, rest} = Enum.split_with(change_set, &(&1.path in decision["red_paths"]))
    base = decision["base_sha"]
    effects = decision["effects"]

    with {:ok, %{"tree" => %{"sha" => base_tree}}} <- GitHub.get_commit(ctx.gh, base),
         {:ok, red_tree} <- tree(ctx, base_tree, red, images),
         {:ok, red_commit} <-
           GitHub.create_commit(ctx.gh, effects["red_commit_message"], red_tree, [base]),
         {:ok, fix_tree} <- tree(ctx, red_tree, rest, images),
         {:ok, fix_commit} <-
           GitHub.create_commit(ctx.gh, effects["fix_commit_message"], fix_tree, [red_commit]),
         :ok <- GitTree.check_result(ctx.gh, red_commit, red),
         :ok <- GitTree.check_result(ctx.gh, fix_commit, change_set) do
      {:ok, %{red: red_commit, fix: fix_commit, fix_tree: fix_tree, base: base}}
    end
  end

  defp tree(ctx, base_tree, entries, images) do
    with :ok <- blobs(ctx, entries, images) do
      GitHub.create_tree(ctx.gh, base_tree, Enum.map(entries, &tree_entry/1))
    end
  end

  defp blobs(ctx, entries, images) do
    Enum.reduce_while(entries, :ok, fn
      %{op: :delete}, :ok ->
        {:cont, :ok}

      entry, :ok ->
        case GitHub.create_blob(ctx.gh, Map.fetch!(images, entry.path)) do
          {:ok, sha} when sha == entry.new_blob_sha -> {:cont, :ok}
          {:ok, _other} -> {:halt, {:error, {:tree_mismatch, entry.path}}}
          error -> {:halt, error}
        end
    end)
  end

  defp tree_entry(%{op: :delete, path: path}),
    do: %{"path" => path, "mode" => "100644", "type" => "blob", "sha" => nil}

  defp tree_entry(entry),
    do: %{
      "path" => entry.path,
      "mode" => entry.mode,
      "type" => "blob",
      "sha" => entry.new_blob_sha
    }

  # A branch left by an earlier attempt is reused only if it holds exactly this fix.
  defp branch(ctx, branch, commits) do
    case GitHub.create_ref(ctx.gh, branch, commits.fix) do
      :ok -> :ok
      {:error, {:github, 422, _code}} -> existing_branch(ctx, branch, commits)
      error -> error
    end
  end

  defp existing_branch(ctx, branch, commits) do
    with {:ok, sha} <- GitHub.get_ref(ctx.gh, branch),
         {:ok, %{"tree" => %{"sha" => tree}}} <- GitHub.get_commit(ctx.gh, sha) do
      if tree == commits.fix_tree, do: :ok, else: {:error, :branch_collision}
    end
  end

  defp open_pull(ctx, decision, bodies, commits) do
    effects = decision["effects"]

    with {:ok, %{"number" => number, "html_url" => url}}
         when is_integer(number) and is_binary(url) <-
           GitHub.create_pull(ctx.gh, %{
             "title" => effects["pr_title"],
             "body" => bodies.pr_body,
             "head" => decision["branch"],
             "base" => decision["target_branch"]
           }),
         :ok <- labels(ctx, number, effects["labels"]),
         :ok <- comments(ctx, bodies.comments),
         :ok <- target_moved(ctx, number, decision) do
      Platform.published(ctx.req, ctx.raw, ctx.run, ctx.issue, %{
        decision_id: decision["decision_id"],
        pr_number: number,
        pr_url: url,
        branch: decision["branch"],
        red_commit_sha: commits.red,
        fix_commit_sha: commits.fix
      })
    else
      {:ok, _malformed} -> {:error, :malformed_response}
      error -> error
    end
  end

  defp labels(_ctx, _number, []), do: :ok
  defp labels(ctx, number, labels), do: GitHub.add_labels(ctx.gh, number, labels)

  defp comments(ctx, comments) do
    Enum.reduce_while(comments, :ok, fn {issue, body}, :ok ->
      case GitHub.comment(ctx.gh, issue, body) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # compare(target...base): `behind` or `diverged` means the target moved on.
  defp target_moved(ctx, number, %{"target_branch" => target, "base_sha" => base}) do
    case GitHub.compare(ctx.gh, target, base) do
      {:ok, moved} when moved in ["behind", "diverged"] ->
        GitHub.comment(
          ctx.gh,
          number,
          "The target branch moved after this run started; this PR is based on " <> base
        )

      {:ok, _same_or_ahead} ->
        :ok

      error ->
        error
    end
  end
end
