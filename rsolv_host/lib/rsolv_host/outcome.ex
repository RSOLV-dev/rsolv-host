defmodule RsolvHost.Outcome do
  @moduledoc """
  The host's exit-code contract (README "Exit codes"). Stable: changing a code is
  a breaking change. 0 model outcome, 1 host bug, 2 configuration, 3 transient
  (retried once by `rsolv-work.yml`), 4 sandbox.

  Annotations are fixed text plus host-controlled values (atoms the host
  defines, integers); no binary from an error reason is ever written.
  """

  alias RsolvHost.ActionsLog

  @type class :: :host_bug | :configuration | :transient | :sandbox
  @type outcome :: :validated | :false_positive | :not_validated | :mitigated | :mitigation_failed
  @type result ::
          :ok
          | {:outcome, outcome(), boolean()}
          | {:error, term()}
          | {:error, term(), :validated}

  @client_errors [400, 401, 403, 404, 409, 422]
  @verify_errors [
    :bad_signature,
    :unknown_kid,
    :key_expired,
    :expired,
    :not_yet_valid,
    :validity_too_long,
    :malformed_decision,
    :unsupported_version,
    :digest_mismatch,
    :bad_red_paths,
    :malformed_change_set,
    :invalid_path,
    :invalid_entry,
    :unsorted,
    :duplicate_path,
    :path_conflict
  ]
  @summary_header "| Issue | Outcome | Patch | Exit |\n|---|---|---|---|\n"

  @doc "Exit code for a role's result."
  @spec exit_code(result()) :: 0..4
  def exit_code(:ok), do: 0
  def exit_code({:outcome, _outcome, _has_patch}), do: 0
  def exit_code({:error, reason}), do: reason |> classify() |> code()
  def exit_code({:error, reason, :validated}), do: exit_code({:error, reason})

  @doc "Failure class of an error reason."
  @spec classify(term()) :: class()
  def classify(:usage), do: :configuration
  def classify({:preflight, _variable}), do: :configuration
  def classify({:missing_env, _variable}), do: :configuration
  def classify(:oidc_unavailable), do: :configuration
  def classify({:oidc_http, status}) when status == 429 or status >= 500, do: :transient
  def classify({:oidc_http, _status}), do: :configuration
  def classify(:api_url_not_allowed), do: :configuration
  def classify({:protocol_version, _theirs}), do: :configuration
  def classify(:decision_keys_invalid), do: :configuration
  def classify(:publish_unavailable), do: :configuration
  def classify(reason) when reason in @verify_errors, do: :configuration
  def classify({:binding_mismatch, _field}), do: :configuration
  def classify({:base_mismatch, _path}), do: :configuration
  def classify({:tree_mismatch, _path}), do: :configuration
  def classify(:branch_collision), do: :configuration
  def classify(:base_not_on_target), do: :configuration
  def classify(:pull_collision), do: :configuration

  def classify({:platform, 409, "already_exchanged"}), do: :transient

  def classify({api, status, _code})
      when api in [:platform, :github] and (status in @client_errors or status in 300..399),
      do: :configuration

  def classify({api, status, _code})
      when api in [:platform, :github] and (status == 429 or status >= 500),
      do: :transient

  def classify(:run_unbound), do: :configuration
  def classify(:truncated), do: :configuration
  def classify(:workflow_path), do: :configuration

  def classify({:transport, _reason}), do: :transient
  def classify(:token_expired), do: :transient
  def classify(:token_unavailable), do: :transient
  def classify({:session, _data}), do: :transient
  def classify(:stream_exhausted), do: :transient
  def classify(:session_timeout), do: :transient
  def classify({:handoff, _posix}), do: :sandbox
  # The platform or GitHub broke the protocol: not the host's bug, and not the
  # customer's to fix; a later run may pass.
  def classify({:stream, _reason}), do: :transient
  def classify(:too_many_tool_requests), do: :transient
  def classify(:malformed_tool_request), do: :transient
  def classify(:malformed_response), do: :transient

  # The sandbox broke its CLI contract (plan, "Sandbox CLI contract"), for
  # example a byte on the scanner's stderr, which shares the frame channel.
  def classify(reason)
      when reason in [:bad_frame, :frame_too_large, :frame_limit, :unknown_issue] or
             reason in [:too_many_issues, :malformed_patch],
      do: :sandbox

  def classify({:sandbox_setup, _step}), do: :sandbox
  def classify({:sandbox, _reason}), do: :sandbox
  def classify(_unexpected), do: :host_bug

  defp code(:host_bug), do: 1
  defp code(:configuration), do: 2
  defp code(:transient), do: 3
  defp code(:sandbox), do: 4

  @doc "Writes the one `::error::` annotation for `reason`."
  @spec annotate(term(), IO.device()) :: :ok
  def annotate(reason, io \\ :stdio) do
    class = classify(reason)
    ActionsLog.error(title(class), message(reason, class), io)
  end

  defp title(:host_bug), do: "RSOLV host client bug"
  defp title(:configuration), do: "RSOLV configuration"
  defp title(:transient), do: "RSOLV transient failure"
  defp title(:sandbox), do: "RSOLV sandbox setup"

  defp message(:usage, _class),
    do: "Invalid rsolv-host arguments. Call RSOLV through its reusable workflows."

  defp message({:preflight, variable}, _class),
    do:
      "Set #{variable} so rsolv-host installs under $RUNNER_TEMP. Call RSOLV through its reusable workflows."

  defp message({:missing_env, variable}, _class),
    do: "#{variable} is not set. Run rsolv-host only inside RSOLV's reusable workflows."

  defp message(:oidc_unavailable, _class),
    do: "Grant `id-token: write` to the job that calls RSOLV."

  defp message({:oidc_http, status}, :configuration),
    do:
      "GitHub refused the OIDC token request (HTTP #{status}). Grant `id-token: write` to the job that calls RSOLV."

  defp message(:api_url_not_allowed, _class),
    do:
      "RSOLV_API_URL must be https://api.rsolv.ai., https://api.rsolv.dev. or https://api.rsolv-staging.com. (with the trailing dot), or unset."

  defp message({:protocol_version, _theirs}, _class),
    do:
      "This rsolv-host and the RSOLV platform speak different protocol versions. Update to the current RSOLV workflow release."

  defp message(:decision_keys_invalid, _class),
    do:
      "RSOLV_DECISION_KEYS is empty or invalid. Use RSOLV's reusable publish workflow unmodified."

  defp message(:publish_unavailable, _class), do: "Publishing isn't enabled for this run yet."

  defp message(:branch_collision, _class),
    do:
      "The fix branch already exists with different content. Delete it and re-run the issue's workflow."

  defp message(:pull_collision, _class),
    do:
      "A pull request from the fix branch already exists and isn't the one RSOLV signed. Close it, delete the branch and re-run the issue's workflow."

  defp message(:run_unbound, _class),
    do:
      "The RSOLV platform issued this job's run token without its run (base and target). Re-run the scan, then this issue's workflow."

  defp message(:truncated, _class),
    do:
      "A directory this fix touches has more entries than GitHub's tree API lists, so RSOLV can't check the fix against it and won't publish it."

  defp message(:workflow_path, _class),
    do:
      "The fix touches .github/, which RSOLV never publishes. Apply that part of the fix by hand."

  defp message(:base_not_on_target, _class),
    do:
      "The target branch no longer contains the commit this run was scanned at (it was rewritten). Run a new scan."

  defp message({:platform, status, _code}, :configuration),
    do:
      "The RSOLV platform refused the request (HTTP #{status}). Check that this repository's owner is connected to RSOLV and that the job uses RSOLV's reusable workflows."

  defp message({:github, status, _code}, :configuration),
    do:
      "GitHub refused the request (HTTP #{status}). Grant `issues: write` to the scan job, and `contents: write` and `pull-requests: write` to the publish job."

  defp message({:unexpected, %module{}}, :host_bug),
    do: "rsolv-host crashed (#{inspect(module)}). #{report_bug()}"

  defp message(reason, :host_bug), do: "rsolv-host failed (#{kind(reason)}). #{report_bug()}"

  defp message(reason, :configuration),
    do:
      "The platform's signed publish decision was refused (#{kind(reason)}). Re-run the issue's workflow for a fresh decision; if this repeats, contact RSOLV support."

  defp message({:sandbox, :enoent}, :sandbox),
    do: "Docker is not available on this runner (no `docker` on PATH)."

  defp message({:handoff, _posix}, :sandbox),
    do:
      "Couldn't write the run-token hand-off file under $RUNNER_TEMP. Check the runner's temp disk."

  defp message({:sandbox_setup, step}, :sandbox),
    do:
      "Sandbox setup failed at step `#{kind(step)}`. Check that Docker on this runner can create internal networks and run containers."

  defp message(reason, :sandbox)
       when reason in [:bad_frame, :frame_too_large, :frame_limit, :unknown_issue] or
              reason in [:too_many_issues, :malformed_patch],
       do:
         "The sandbox broke rsolv-host's protocol (#{kind(reason)}), for example by writing to stderr during a scan. Use the sandbox image the RSOLV workflow pins."

  defp message(reason, :sandbox), do: "The sandbox failed (#{kind(reason)})."

  defp message({:platform, 409, "already_exchanged"}, :transient),
    do:
      "This job's run token was issued, but the answer was lost on the way. Re-run the workflow."

  defp message(reason, :transient),
    do:
      "A platform or network failure (#{kind(reason)}). The RSOLV work workflow retries once; if this repeats, re-run the workflow later."

  defp report_bug,
    do: "Please open an issue on RSOLV-dev/rsolv-host with this workflow run's URL."

  # Only host-defined atoms name a reason; wire input never becomes an atom.
  defp kind(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp kind(reason) when is_tuple(reason) and is_atom(elem(reason, 0)), do: kind(elem(reason, 0))
  defp kind(_reason), do: "unexpected"

  @doc """
  Records a `work` result: `outcome` and `has_patch` step outputs, one job-summary
  row and, for a false positive, a notice. Options: `:issue`, `:io`, and the
  `:output` and `:summary` file paths (`GITHUB_OUTPUT`, `GITHUB_STEP_SUMMARY`);
  a missing path is skipped.
  """
  @spec report(result(), keyword()) :: :ok
  def report({:outcome, outcome, has_patch} = result, opts),
    do: record(outcome, has_patch, exit_code(result), opts)

  def report({:error, _reason, :validated} = result, opts),
    do: record(:validated, false, exit_code(result), opts)

  defp record(outcome, has_patch, code, opts) do
    issue = Keyword.fetch!(opts, :issue)

    if output = opts[:output] do
      :ok = ActionsLog.set_output("outcome", Atom.to_string(outcome), output)
      :ok = ActionsLog.set_output("has_patch", to_string(has_patch), output)
    end

    if summary = opts[:summary] do
      patch = if has_patch, do: "yes", else: "no"

      ActionsLog.summary_row(
        @summary_header,
        "| ##{issue} | #{outcome} | #{patch} | #{code} |",
        summary
      )
    end

    notify(outcome, issue, Keyword.get(opts, :io, :stdio))
  end

  defp notify(:false_positive, issue, io),
    do:
      ActionsLog.notice(
        "RSOLV",
        "Issue ##{issue} is a false positive; no patch was produced.",
        io
      )

  defp notify(_outcome, _issue, _io), do: :ok
end
