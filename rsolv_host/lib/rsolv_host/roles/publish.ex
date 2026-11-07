defmodule RsolvHost.Roles.Publish do
  @moduledoc """
  The `publish` role, the host side of RFC-150 §6.2: it writes only what a
  decision signed by the platform allows, through GitHub's Git Data API. There is
  no checkout, no git and no sandbox in this role.

  In order: verify the signed decision against `RSOLV_DECISION_KEYS` and the
  job's own identity; check the unsigned bodies and post-images against their
  signed digests; check the base tree and that the target branch still contains
  `base_sha`; write the RED commit (exactly the `red_paths`) on `base_sha` and
  the fix commit on it; check both written trees; create the branch; open the
  pull request with its labels and comments; report it. Every refusal before the
  first write is configuration (exit 2): the remedy is re-running the issue's
  workflow for a fresh decision.
  """

  alias RsolvCore.{ChangeSet, Decision}
  alias RsolvHost.{GitHub, GitTree, Http, Oidc, Platform, TokenKeeper}

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
         {:ok, keeper} <- TokenKeeper.start(role: :publish, issue: issue, env: env, io: io) do
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
        TokenKeeper.stop(keeper)
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
         {:ok, expires_at, 0} <- DateTime.from_iso8601(verified.decision["expires_at"]),
         ctx = until(ctx, expires_at),
         :ok <- no_workflow_paths(verified.change_set),
         {:ok, bodies} <- bodies(verified),
         {:ok, images} <- post_images(ctx, verified.change_set),
         :ok <- GitTree.check_base(ctx.gh, verified.decision["base_sha"], verified.change_set),
         :ok <- on_target(ctx, verified.decision),
         {:ok, commits} <- write_commits(ctx, verified.decision, verified.change_set, images),
         {:ok, commits} <- branch(ctx, verified.decision, commits) do
      open_pull(ctx, verified.decision, bodies, commits)
    else
      {:ok, _unbound} -> {:error, :run_unbound}
      error -> error
    end
  end

  # The decision authorizes writes only until its `expires_at` (RFC-150 §6.1).
  # From here on, every GitHub and platform request carries that deadline
  # (`Http.deadline/3`): each attempt, retries included, is refused once it has
  # passed, before anything is sent, and its waits are cut to the time left. No
  # call site can skip the check, and a slow read can't lead into a late write.
  defp until(ctx, expires_at) do
    deadline =
      System.monotonic_time(:millisecond) +
        DateTime.diff(expires_at, DateTime.utc_now(), :millisecond)

    %{
      ctx
      | gh: %{ctx.gh | req: Http.deadline(ctx.gh.req, deadline, :expired)},
        req: Http.deadline(ctx.req, deadline, :expired)
    }
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

  # Defence in depth: the platform never signs a change under .github/ (CI
  # configuration), and the host refuses one anyway, whatever its case.
  defp no_workflow_paths(change_set) do
    if Enum.any?(change_set, &(String.downcase(&1.path) =~ ~r{\A\.github(/|\z)})),
      do: {:error, :workflow_path},
      else: :ok
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

  # RFC-150 §3: the signed base must be reachable from the target's head before
  # anything is written. In compare(target...base), only `behind` (the target
  # moved on from the base) and `identical` prove that; a moved target is
  # disclosed in the platform-signed PR body, never by the host.
  defp on_target(ctx, %{"target_branch" => target, "base_sha" => base}) do
    case GitHub.compare(ctx.gh, target, base) do
      {:ok, status} when status in ["behind", "identical"] -> :ok
      {:ok, _ahead_or_diverged} -> {:error, :base_not_on_target}
      error -> error
    end
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
      {:ok,
       %{red: red_commit, fix: fix_commit, red_tree: red_tree, fix_tree: fix_tree, base: base}}
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

  # Resume (RFC-150 §6.3). A branch left by an earlier attempt is reused only if
  # it is exactly the two signed commits on `base_sha`: the fix (signed message,
  # our fix tree) whose only parent is the RED commit (signed message, our RED
  # tree) whose only parent is the base. The commits reported are the branch's,
  # since rewriting a commit gives it a new SHA (its date).
  defp branch(ctx, %{"branch" => branch} = decision, commits) do
    case GitHub.create_ref(ctx.gh, branch, commits.fix) do
      :ok -> {:ok, commits}
      {:error, {:github, 422, _code}} -> existing_branch(ctx, decision, commits)
      error -> error
    end
  end

  defp existing_branch(ctx, %{"branch" => branch, "effects" => effects}, commits) do
    with {:ok, fix} <- GitHub.get_ref(ctx.gh, branch),
         {:ok, fix_commit} <- GitHub.get_commit(ctx.gh, fix),
         {:ok, red} <- parent(fix_commit, effects["fix_commit_message"], commits.fix_tree),
         {:ok, red_commit} <- GitHub.get_commit(ctx.gh, red),
         {:ok, base} <- parent(red_commit, effects["red_commit_message"], commits.red_tree),
         true <- base == commits.base do
      {:ok, %{commits | red: red, fix: fix}}
    else
      false -> {:error, :branch_collision}
      error -> error
    end
  end

  defp parent(
         %{"message" => message, "tree" => %{"sha" => tree}, "parents" => [%{"sha" => parent}]},
         message,
         tree
       )
       when is_binary(parent),
       do: {:ok, parent}

  defp parent(_commit, _message, _tree), do: {:error, :branch_collision}

  defp open_pull(ctx, decision, bodies, commits) do
    effects = decision["effects"]

    wanted = %{
      "title" => effects["pr_title"],
      "body" => bodies.pr_body,
      "head" => decision["branch"],
      "base" => decision["target_branch"]
    }

    with {:ok, %{"number" => number, "html_url" => url} = pull} <- pull(ctx, wanted, commits),
         :ok <- labels(ctx, pull, effects["labels"]),
         :ok <- comments(ctx, bodies.comments) do
      Platform.published(ctx.req, ctx.raw, ctx.run, ctx.issue, %{
        decision_id: decision["decision_id"],
        pr_number: number,
        pr_url: url,
        branch: decision["branch"],
        red_commit_sha: commits.red,
        fix_commit_sha: commits.fix
      })
    end
  end

  # An existing pull request from the branch is reused if it is the signed one;
  # a 422 from creating one (it exists, an earlier answer was lost) is looked up
  # again, once.
  defp pull(ctx, wanted, commits) do
    with {:ok, nil} <- find_pull(ctx, wanted, commits) do
      case GitHub.create_pull(ctx.gh, wanted) do
        {:ok, created} ->
          checked_pull(created, wanted, commits)

        {:error, {:github, 422, _code}} = refused ->
          retry_find(find_pull(ctx, wanted, commits), refused)

        error ->
          error
      end
    end
  end

  defp retry_find({:ok, nil}, refused), do: refused
  defp retry_find(found, _refused), do: found

  defp find_pull(ctx, %{"head" => head} = wanted, commits) do
    with {:ok, pulls} <- GitHub.list_pulls(ctx.gh, head, wanted["base"]) do
      pulls
      |> Enum.filter(&match?(%{"head" => %{"ref" => ^head}}, &1))
      |> case do
        [] -> {:ok, nil}
        [pull | _older] -> checked_pull(pull, wanted, commits)
      end
    end
  end

  defp checked_pull(
         %{
           "number" => number,
           "html_url" => url,
           "title" => title,
           "body" => body,
           "head" => %{"ref" => head},
           "base" => %{"ref" => base}
         } = pull,
         %{"title" => title, "body" => body, "head" => head, "base" => base},
         commits
       )
       when is_integer(number) and is_binary(url) do
    if pull["head"]["sha"] == commits.fix, do: {:ok, pull}, else: {:error, :pull_collision}
  end

  defp checked_pull(%{"number" => number, "html_url" => url}, _wanted, _commits)
       when is_integer(number) and is_binary(url),
       do: {:error, :pull_collision}

  defp checked_pull(_malformed, _wanted, _commits), do: {:error, :malformed_response}

  # Adding labels is a union on GitHub; only the missing ones are sent.
  defp labels(ctx, %{"number" => number} = pull, wanted) do
    present = for %{"name" => name} <- List.wrap(pull["labels"]), do: name

    case wanted -- present do
      [] -> :ok
      missing -> GitHub.add_labels(ctx.gh, number, missing)
    end
  end

  # A signed comment already on its issue (same body digest, as often as the
  # effects list it) isn't posted again.
  defp comments(ctx, comments) do
    with {:ok, posted} <- posted(ctx, comments |> Enum.map(&elem(&1, 0)) |> Enum.uniq()),
         {:ok, _posted} <- Enum.reduce_while(comments, {:ok, posted}, &comment(ctx, &1, &2)),
         do: :ok
  end

  defp comment(ctx, {issue, body}, {:ok, posted}) do
    key = {issue, sha256(body)}

    case Map.get(posted, key, 0) do
      0 -> comment(ctx, issue, body, posted)
      n -> {:cont, {:ok, Map.put(posted, key, n - 1)}}
    end
  end

  defp comment(ctx, issue, body, posted) do
    case GitHub.comment(ctx.gh, issue, body) do
      :ok -> {:cont, {:ok, posted}}
      error -> {:halt, error}
    end
  end

  # ponytail: reads at most 10 pages (1,000 comments) per issue; past that a
  # re-run could post a signed comment twice.
  defp posted(ctx, issues) do
    Enum.reduce_while(issues, {:ok, %{}}, fn issue, {:ok, acc} ->
      case posted(ctx, issue, 1, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        error -> {:halt, error}
      end
    end)
  end

  defp posted(ctx, issue, page, acc) do
    with {:ok, comments} <- GitHub.list_comments(ctx.gh, issue, page) do
      acc =
        for %{"body" => body} when is_binary(body) <- comments, reduce: acc do
          acc -> Map.update(acc, {issue, sha256(body)}, 1, &(&1 + 1))
        end

      if length(comments) == 100 and page < 10,
        do: posted(ctx, issue, page + 1, acc),
        else: {:ok, acc}
    end
  end
end
