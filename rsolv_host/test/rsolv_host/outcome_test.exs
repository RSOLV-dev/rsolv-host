defmodule RsolvHost.OutcomeTest do
  use ExUnit.Case, async: true

  alias RsolvHost.Outcome

  defp capture(fun) do
    {:ok, io} = StringIO.open("")
    fun.(io)
    {:ok, {_in, out}} = StringIO.close(io)
    out
  end

  describe "classify/1" do
    test "a host-side impossibility or an unrecognised term is a host bug" do
      for reason <- [
            :sandbox_image_unpinned,
            :resume_unavailable,
            :invalid_binding,
            {:unexpected, %RuntimeError{}},
            {:what, 1}
          ] do
        assert Outcome.classify(reason) == :host_bug, inspect(reason)
      end
    end

    test "what the customer can fix, or a refused signed decision, is configuration" do
      verify_errors = [
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
        :path_conflict,
        {:binding_mismatch, "run_id"}
      ]

      http =
        for api <- [:platform, :github],
            status <- [400, 401, 403, 404, 409, 422],
            do: {api, status, "code"}

      for reason <-
            [
              :usage,
              {:preflight, "RSOLV_HOST_INSTALL_DIR"},
              {:vm_env, "ERL_FLAGS"},
              :oidc_unavailable,
              {:oidc_http, 403},
              :api_url_not_allowed,
              {:protocol_version, 2},
              :decision_keys_invalid,
              :publish_unavailable,
              {:base_mismatch, "a"},
              {:tree_mismatch, "a"},
              :branch_collision,
              {:missing_env, "GITHUB_RUN_ID"}
            ] ++ verify_errors ++ http do
        assert Outcome.classify(reason) == :configuration, inspect(reason)
      end
    end

    test "a platform, GitHub or network failure that may pass is transient" do
      for reason <- [
            {:platform, 429, nil},
            {:platform, 503, "x"},
            {:github, 500, :server_error},
            {:oidc_http, 503},
            {:transport, :timeout},
            :token_expired,
            {:session, %{}},
            :stream_exhausted
          ] do
        assert Outcome.classify(reason) == :transient, inspect(reason)
      end
    end

    test "a sandbox setup step or a missing docker is sandbox infrastructure" do
      assert Outcome.classify({:sandbox_setup, :network_create}) == :sandbox
      assert Outcome.classify({:sandbox, :enoent}) == :sandbox
    end

    test "the platform or GitHub breaking the protocol is transient, not a host bug" do
      for reason <- [
            {:stream, :line_too_long},
            {:stream, :malformed_event},
            :too_many_tool_requests,
            :malformed_tool_request,
            :malformed_response,
            :token_unavailable,
            :session_timeout,
            {:platform, 409, "already_exchanged"}
          ] do
        assert Outcome.classify(reason) == :transient, inspect(reason)
      end
    end

    test "the sandbox breaking its CLI contract is a sandbox failure, not a host bug" do
      for reason <- [
            :bad_frame,
            :frame_too_large,
            :frame_limit,
            :unknown_issue,
            :too_many_issues,
            :malformed_patch,
            {:handoff, :enospc}
          ] do
        assert Outcome.classify(reason) == :sandbox, inspect(reason)
      end
    end

    test "what a re-run can't fix but the repository's owner can is configuration" do
      for reason <- [
            :run_unbound,
            :truncated,
            :base_not_on_target,
            :pull_collision,
            :workflow_path,
            {:github, 307, :refused}
          ] do
        assert Outcome.classify(reason) == :configuration, inspect(reason)
      end
    end
  end

  describe "exit_code/1" do
    test "a role that finished, or any model outcome, exits 0" do
      assert Outcome.exit_code(:ok) == 0
      assert Outcome.exit_code({:outcome, :false_positive, false}) == 0
    end

    test "each failure class has its own code" do
      assert Outcome.exit_code({:error, {:what, 1}}) == 1
      assert Outcome.exit_code({:error, :oidc_unavailable}) == 2
      assert Outcome.exit_code({:error, :stream_exhausted}) == 3
      assert Outcome.exit_code({:error, {:sandbox, :enoent}}) == 4
    end

    test "a failure after VALIDATE confirmed exits by its class" do
      assert Outcome.exit_code({:error, :stream_exhausted, :validated}) == 3
    end
  end

  describe "annotate/2" do
    test "names the fix for a missing OIDC permission" do
      assert capture(&Outcome.annotate(:oidc_unavailable, &1)) ==
               "::error title=RSOLV configuration::Grant `id-token: write` to the job that calls RSOLV.\n"
    end

    test "names a missing Actions variable" do
      assert capture(&Outcome.annotate({:missing_env, "GITHUB_WORKSPACE"}, &1)) =~
               ~r/\A::error title=RSOLV configuration::GITHUB_WORKSPACE is not set/
    end

    test "names an ERL_* variable to unset" do
      assert capture(&Outcome.annotate({:vm_env, "ERL_AFLAGS"}, &1)) =~
               ~r/\A::error title=RSOLV configuration::Unset ERL_AFLAGS/
    end

    test "titles each class as the contract says" do
      assert capture(&Outcome.annotate({:what, 1}, &1)) =~ "::error title=RSOLV host client bug::"

      assert capture(&Outcome.annotate(:token_expired, &1)) =~
               "::error title=RSOLV transient failure::"

      assert capture(&Outcome.annotate({:sandbox_setup, :network_create}, &1)) =~
               ~r/\A::error title=RSOLV sandbox setup::.*network_create/
    end

    test "never echoes text from the error reason" do
      out = capture(&Outcome.annotate({:platform, 403, "</script>::add-mask::x"}, &1))

      assert [_one_line] = String.split(out, "\n", trim: true)
      refute out =~ "script"
      refute out =~ "add-mask"
    end

    test "names only the exception's module for a crash" do
      out = capture(&Outcome.annotate({:unexpected, %RuntimeError{message: "secret"}}, &1))

      assert out =~ "RuntimeError"
      refute out =~ "secret"
    end
  end

  describe "report/2" do
    @describetag :tmp_dir

    setup %{tmp_dir: dir} do
      %{output: Path.join(dir, "output"), summary: Path.join(dir, "summary")}
    end

    test "when the issue is a false positive, writes outputs, a summary row and a notice",
         %{output: output, summary: summary} do
      out =
        capture(fn io ->
          Outcome.report({:outcome, :false_positive, false},
            issue: 7,
            io: io,
            output: output,
            summary: summary
          )
        end)

      assert File.read!(output) == "outcome=false_positive\nhas_patch=false\n"

      assert File.read!(summary) =~
               ~r/\A\| Issue \|.*\n\|---.*\n\| #7 \| false_positive \| no \| 0 \|\n\z/

      assert out == "::notice title=RSOLV::Issue #7 is a false positive; no patch was produced.\n"
    end

    test "when mitigated, reports a patch and writes no notice", %{
      output: output,
      summary: summary
    } do
      out =
        capture(fn io ->
          Outcome.report({:outcome, :mitigated, true},
            issue: 7,
            io: io,
            output: output,
            summary: summary
          )
        end)

      assert File.read!(output) == "outcome=mitigated\nhas_patch=true\n"
      assert out == ""
    end

    test "writes the summary header only once", %{output: output, summary: summary} do
      for issue <- [7, 8] do
        Outcome.report({:outcome, :not_validated, false},
          issue: issue,
          io: :stdio,
          output: output,
          summary: summary
        )
      end

      assert [_header, _rule, "| #7 " <> _, "| #8 " <> _] =
               String.split(File.read!(summary), "\n", trim: true)
    end

    test "when VALIDATE confirmed before a failure, records how far it got",
         %{output: output, summary: summary} do
      Outcome.report({:error, :stream_exhausted, :validated},
        issue: 7,
        io: :stdio,
        output: output,
        summary: summary
      )

      assert File.read!(output) == "outcome=validated\nhas_patch=false\n"
      assert File.read!(summary) =~ "| #7 | validated | no | 3 |"
    end
  end
end
