defmodule RsolvCore.DecisionTest do
  use ExUnit.Case, async: true

  alias RsolvCore.ChangeSet.Entry
  alias RsolvCore.Decision

  @vector __DIR__ |> Path.join("../vectors/decision.json") |> File.read!() |> JSON.decode!()
  @secret Base.decode16!(@vector["secret_key_hex"], case: :lower)
  @envelope @vector["envelope"]
  @decision @envelope["decision"]
  @now ~U[2026-11-05 12:10:00Z]
  @expect %{
    "run_id" => @decision["run_id"],
    "repository_id" => @decision["repository_id"],
    "issue" => @decision["issue"],
    "publish_attempt" => @decision["publish_attempt"],
    "check_run_id_publish" => @decision["check_run_id_publish"]
  }

  defp keys do
    {:ok, keys} = @vector["keys"] |> JSON.encode!() |> Decision.parse_keys()
    keys
  end

  defp verify(envelope, opts \\ [])

  defp verify(envelope, opts) when is_map(envelope),
    do: envelope |> JSON.encode!() |> verify(opts)

  defp verify(json, opts) do
    Decision.verify(
      json,
      Keyword.get(opts, :keys, keys()),
      now: Keyword.get(opts, :now, @now),
      expect: Keyword.get(opts, :expect, @expect)
    )
  end

  defp resigned(changes), do: @decision |> Map.merge(changes) |> Decision.sign(@secret)

  defp with_effects(changes),
    do: resigned(%{"effects" => Map.merge(@decision["effects"], changes)})

  defp with_comment(changes) do
    [comment] = @decision["effects"]["comments"]
    with_effects(%{"comments" => [Map.merge(comment, changes)]})
  end

  @hex64 String.duplicate("a", 64)

  describe "the OTP Ed25519 primitive" do
    test "signs RFC 8032 section 7.1 TEST 1" do
      signature = :crypto.sign(:eddsa, :none, "", [@secret, :ed25519])

      assert Base.encode16(signature, case: :lower) ==
               "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"
    end
  end

  describe "sign/2" do
    test "reproduces the golden envelope byte for byte" do
      assert Decision.sign(@decision, @secret) == @envelope
    end
  end

  describe "verify/3" do
    test "accepts the golden envelope and returns its change set" do
      assert {:ok, %{decision: @decision, change_set: [%Entry{op: :modify}, %Entry{op: :add}]}} =
               verify(@envelope)
    end
  end

  describe "verify/3 when the response repeats a member name" do
    test "refuses a duplicate kid in an otherwise valid envelope" do
      json =
        @envelope
        |> JSON.encode!()
        |> String.replace(~s({"decision":{), ~s({"decision":{"kid":"evil",), global: false)

      assert verify(json) == {:error, :malformed_decision}
    end

    test "refuses a duplicate member inside effects" do
      json =
        @envelope
        |> JSON.encode!()
        |> String.replace(~s("effects":{), ~s("effects":{"pr_title":"other",), global: false)

      assert verify(json) == {:error, :malformed_decision}
    end

    test "refuses a decoded map instead of the response bytes" do
      assert Decision.verify(@envelope, keys(), now: @now, expect: @expect) ==
               {:error, :malformed_decision}
    end
  end

  describe "verify/3 when the signature does not hold" do
    test "refuses a flipped signature byte" do
      <<first, rest::binary>> = Base.url_decode64!(@envelope["signature"], padding: false)
      flipped = Base.url_encode64(<<Bitwise.bxor(first, 1), rest::binary>>, padding: false)

      assert verify(%{@envelope | "signature" => flipped}) == {:error, :bad_signature}
    end

    for field <- ~w(v decision_id run_id repository_id issue work_attempt verify_attempt
                    publish_attempt check_run_id_work check_run_id_verify check_run_id_publish
                    base_sha target_branch branch change_set change_set_digest red_paths
                    policy_version verify_mode effects issued_at expires_at) do
      test "refuses #{field} changed after signing" do
        tampered = put_in(@envelope, ["decision", unquote(field)], "tampered")
        assert verify(tampered) == {:error, :bad_signature}
      end
    end
  end

  describe "verify/3 when the key does not apply" do
    test "refuses an unknown kid" do
      envelope = resigned(%{"kid" => "test-unknown"})
      assert verify(envelope) == {:error, :unknown_kid}
    end

    test "refuses a key past its not_after date" do
      [key] = keys()

      assert verify(@envelope, keys: [%{key | not_after: ~D[2026-11-04]}]) ==
               {:error, :key_expired}
    end
  end

  describe "verify/3 when the validity window does not hold" do
    test "refuses a decision at its expiry" do
      assert verify(@envelope, now: ~U[2026-11-05 12:30:00Z]) == {:error, :expired}
    end

    test "refuses a decision issued more than 60 s in the future" do
      assert verify(@envelope, now: ~U[2026-11-05 11:58:59Z]) == {:error, :not_yet_valid}
    end

    test "accepts a decision issued within the 60 s clock skew" do
      assert {:ok, _verified} = verify(@envelope, now: ~U[2026-11-05 11:59:00Z])
    end

    test "refuses a validity longer than 30 minutes" do
      envelope = resigned(%{"expires_at" => "2026-11-05T12:30:01Z"})
      assert verify(envelope) == {:error, :validity_too_long}
    end

    test "refuses an unparseable timestamp" do
      envelope = resigned(%{"issued_at" => "yesterday"})
      assert verify(envelope) == {:error, :malformed_decision}
    end
  end

  describe "verify/3 when the decision is malformed" do
    test "refuses a missing field" do
      envelope = @decision |> Map.delete("verify_mode") |> Decision.sign(@secret)
      assert verify(envelope) == {:error, :malformed_decision}
    end

    test "refuses an extra field" do
      assert verify(resigned(%{"extra" => true})) == {:error, :malformed_decision}
    end

    test "refuses a signature that is not 64 bytes" do
      assert verify(%{@envelope | "signature" => "AAAA"}) == {:error, :malformed_decision}
    end

    test "refuses an envelope without a decision" do
      assert verify(%{"signature" => @envelope["signature"]}) == {:error, :malformed_decision}
    end
  end

  describe "verify/3 when an identity field has the wrong type" do
    for field <- ~w(run_id repository_id issue work_attempt verify_attempt publish_attempt
                    check_run_id_work check_run_id_verify check_run_id_publish),
        {label, value} <- [string: "1", zero: 0, negative: -1, null: nil] do
      test "refuses #{field} as #{label}" do
        envelope = resigned(%{unquote(field) => unquote(value)})
        assert verify(envelope) == {:error, :malformed_decision}
      end
    end

    for value <- ["", "dec 1", "dec/1", String.duplicate("a", 129), 7] do
      test "refuses the decision_id #{inspect(value, printable_limit: 12)}" do
        assert verify(resigned(%{"decision_id" => unquote(value)})) ==
                 {:error, :malformed_decision}
      end
    end
  end

  describe "verify/3 when base or target is malformed" do
    for value <- [
          String.duplicate("A", 40),
          String.duplicate("a", 39),
          String.duplicate("a", 64),
          nil
        ] do
      test "refuses the base_sha #{inspect(value)}" do
        assert verify(resigned(%{"base_sha" => unquote(value)})) == {:error, :malformed_decision}
      end
    end

    for field <- ~w(target_branch branch policy_version),
        value <- ["", "a\nb", "a\u202eb", 1, nil] do
      test "refuses the #{field} #{inspect(value)}" do
        assert verify(resigned(%{unquote(field) => unquote(value)})) ==
                 {:error, :malformed_decision}
      end
    end
  end

  describe "verify/3 on verify_mode" do
    for mode <- ~w(job inline) do
      test "accepts #{mode}" do
        assert {:ok, _verified} = verify(resigned(%{"verify_mode" => unquote(mode)}))
      end
    end

    for mode <- ["test-mode", "", "JOB", nil] do
      test "refuses #{inspect(mode)}" do
        assert verify(resigned(%{"verify_mode" => unquote(mode)})) ==
                 {:error, :malformed_decision}
      end
    end
  end

  describe "verify/3 when effects is malformed" do
    test "refuses effects that are not an object" do
      assert verify(resigned(%{"effects" => false})) == {:error, :malformed_decision}
    end

    test "refuses an extra member" do
      assert verify(with_effects(%{"assignees" => []})) == {:error, :malformed_decision}
    end

    for field <- ~w(pr_title pr_body_sha256 labels comments red_commit_message fix_commit_message) do
      test "refuses effects without #{field}" do
        effects = Map.delete(@decision["effects"], unquote(field))
        assert verify(resigned(%{"effects" => effects})) == {:error, :malformed_decision}
      end
    end

    for value <- ["", "a\nb", "a\u202eb", String.duplicate("t", 257), 1] do
      test "refuses the pr_title #{inspect(value, printable_limit: 12)}" do
        assert verify(with_effects(%{"pr_title" => unquote(value)})) ==
                 {:error, :malformed_decision}
      end
    end

    for value <- [String.duplicate("A", 64), String.duplicate("a", 63), "sha256:" <> @hex64, nil] do
      test "refuses the pr_body_sha256 #{inspect(value, printable_limit: 12)}" do
        assert verify(with_effects(%{"pr_body_sha256" => unquote(value)})) ==
                 {:error, :malformed_decision}
      end
    end

    for value <- ["rsolv:test", [""], ["a\nb"], ["a", "a"], [1]] do
      test "refuses the labels #{inspect(value)}" do
        assert verify(with_effects(%{"labels" => unquote(value)})) ==
                 {:error, :malformed_decision}
      end
    end

    test "accepts no labels and no comments" do
      assert {:ok, _verified} = verify(with_effects(%{"labels" => [], "comments" => []}))
    end

    test "refuses comments that are not a list" do
      assert verify(with_effects(%{"comments" => %{}})) == {:error, :malformed_decision}
    end

    test "refuses a comment with an extra member" do
      assert verify(with_comment(%{"body" => "hi"})) == {:error, :malformed_decision}
    end

    for value <- ["42", 0, nil] do
      test "refuses a comment on issue #{inspect(value)}" do
        assert verify(with_comment(%{"issue" => unquote(value)})) == {:error, :malformed_decision}
      end
    end

    test "refuses a comment whose body_sha256 is not lowercase hex" do
      assert verify(with_comment(%{"body_sha256" => String.duplicate("F", 64)})) ==
               {:error, :malformed_decision}
    end

    for field <- ~w(red_commit_message fix_commit_message), value <- ["", "a\u0000b", 1] do
      test "refuses the #{field} #{inspect(value)}" do
        assert verify(with_effects(%{unquote(field) => unquote(value)})) ==
                 {:error, :malformed_decision}
      end
    end

    test "accepts a multi-line commit message" do
      message = "fix: resolve issue #42\n\nDetails on a second paragraph."
      assert {:ok, _verified} = verify(with_effects(%{"fix_commit_message" => message}))
    end
  end

  describe "verify/3 when red_paths is degenerate" do
    test "refuses no red paths" do
      assert verify(resigned(%{"red_paths" => []})) == {:error, :bad_red_paths}
    end

    test "refuses a repeated red path" do
      envelope = resigned(%{"red_paths" => ["test/handler.test.js", "test/handler.test.js"]})
      assert verify(envelope) == {:error, :bad_red_paths}
    end
  end

  describe "verify/3 when the timestamps are not whole UTC seconds" do
    for {field, value} <- [
          {"issued_at", "2026-11-05T12:00:00.000000Z"},
          {"expires_at", "2026-11-05T12:30:00.999999Z"},
          {"issued_at", "2026-11-05T12:00:00+00:00"},
          {"issued_at", "2026-11-05 12:00:00Z"},
          {"expires_at", "2026-11-05T12:30Z"}
        ] do
      test "refuses #{field} #{value}" do
        assert verify(resigned(%{unquote(field) => unquote(value)})) ==
                 {:error, :malformed_decision}
      end
    end
  end

  describe "verify/3 when the validity window is empty or inverted" do
    test "refuses expires_at equal to issued_at" do
      envelope = resigned(%{"expires_at" => "2026-11-05T12:00:00Z"})
      assert verify(envelope, now: ~U[2026-11-05 11:59:30Z]) == {:error, :malformed_decision}
    end

    test "refuses expires_at before issued_at, even with now inside the skew" do
      envelope =
        resigned(%{"issued_at" => "2026-11-05T12:11:00Z", "expires_at" => "2026-11-05T12:10:30Z"})

      assert verify(envelope, now: ~U[2026-11-05 12:10:00Z]) == {:error, :malformed_decision}
    end

    test "accepts a window of exactly 30 minutes" do
      assert {:ok, _verified} = verify(@envelope)
    end
  end

  describe "verify/3 when the signature is not canonical base64url" do
    test "refuses padding" do
      assert verify(%{@envelope | "signature" => @envelope["signature"] <> "=="}) ==
               {:error, :malformed_decision}
    end

    test "refuses non-zero trailing bits" do
      signature = @envelope["signature"]
      {head, <<last>>} = String.split_at(signature, -1)
      noncanonical = head <> <<last + 1>>

      assert Base.url_decode64!(noncanonical, padding: false) ==
               Base.url_decode64!(signature, padding: false)

      assert verify(%{@envelope | "signature" => noncanonical}) == {:error, :malformed_decision}
    end

    test "refuses the standard base64 alphabet" do
      standard = @envelope["signature"] |> String.replace("-", "+") |> String.replace("_", "/")
      assert standard != @envelope["signature"]
      assert verify(%{@envelope | "signature" => standard}) == {:error, :malformed_decision}
    end
  end

  describe "verify/3 when the content does not hold together" do
    test "refuses version 2" do
      assert verify(resigned(%{"v" => 2})) == {:error, :unsupported_version}
    end

    test "refuses a change_set_digest that does not match the entries" do
      envelope = resigned(%{"change_set_digest" => "sha256:" <> String.duplicate("0", 64)})
      assert verify(envelope) == {:error, :digest_mismatch}
    end

    test "refuses a red path that is not an add in the change set" do
      assert verify(resigned(%{"red_paths" => ["src/handler.js"]})) == {:error, :bad_red_paths}
    end

    test "refuses an invalid change set" do
      [first, second] = @decision["change_set"]
      assert verify(resigned(%{"change_set" => [second, first]})) == {:error, :unsorted}
    end
  end

  describe "verify/3 when the run binding differs" do
    for field <- ~w(publish_attempt run_id repository_id issue check_run_id_publish) do
      test "refuses a different #{field}" do
        expect = Map.update!(@expect, unquote(field), &(&1 + 1))
        assert verify(@envelope, expect: expect) == {:error, {:binding_mismatch, unquote(field)}}
      end
    end
  end

  describe "verify/3 when the expected binding is incomplete" do
    test "refuses an empty binding" do
      assert verify(@envelope, expect: %{}) == {:error, :invalid_binding}
    end

    for field <- ~w(run_id repository_id issue publish_attempt check_run_id_publish) do
      test "refuses a binding without #{field}" do
        expect = Map.delete(@expect, unquote(field))
        assert verify(@envelope, expect: expect) == {:error, :invalid_binding}
      end

      test "refuses a binding whose #{field} is not a positive integer" do
        expect = Map.put(@expect, unquote(field), "#{@expect[unquote(field)]}")
        assert verify(@envelope, expect: expect) == {:error, :invalid_binding}
      end
    end

    test "refuses 1.0 where the decision says 1" do
      expect = %{@expect | "publish_attempt" => 1.0}
      assert verify(@envelope, expect: expect) == {:error, :invalid_binding}
    end

    test "refuses a binding with an extra field" do
      expect = Map.put(@expect, "work_attempt", 1)
      assert verify(@envelope, expect: expect) == {:error, :invalid_binding}
    end

    test "refuses a binding with atom keys" do
      expect = %{
        run_id: 1_000_000_001,
        repository_id: 2_000_000_002,
        issue: 42,
        publish_attempt: 1,
        check_run_id_publish: 3_000_000_003
      }

      assert verify(@envelope, expect: expect) == {:error, :invalid_binding}
    end
  end

  describe "parse_keys/1" do
    test "parses a key set" do
      assert {:ok, [%{kid: "test-2026-11", public_key: <<_::256>>, not_after: ~D[2027-01-31]}]} =
               @vector["keys"] |> JSON.encode!() |> Decision.parse_keys()
    end

    test "refuses an empty key set" do
      assert Decision.parse_keys("[]") == {:error, :invalid_keys}
    end

    test "refuses a padded key" do
      json =
        @vector["keys"]
        |> Enum.map(&Map.update!(&1, "public_key", fn k -> k <> "=" end))
        |> JSON.encode!()

      assert Decision.parse_keys(json) == {:error, :invalid_keys}
    end

    test "refuses a 31-byte key" do
      key = Base.url_encode64(:binary.copy(<<1>>, 31), padding: false)
      json = JSON.encode!([%{"kid" => "k", "public_key" => key, "not_after" => "2027-01-31"}])
      assert Decision.parse_keys(json) == {:error, :invalid_keys}
    end

    test "refuses a bad date" do
      json =
        @vector["keys"] |> Enum.map(&Map.put(&1, "not_after", "2027-02-30")) |> JSON.encode!()

      assert Decision.parse_keys(json) == {:error, :invalid_keys}
    end

    test "refuses duplicate kids" do
      json = JSON.encode!(@vector["keys"] ++ @vector["keys"])
      assert Decision.parse_keys(json) == {:error, :invalid_keys}
    end

    test "refuses a key record that repeats kid" do
      [%{"public_key" => key}] = @vector["keys"]

      json =
        ~s([{"kid":"evil","kid":"test-2026-11","public_key":"#{key}","not_after":"2027-01-31"}])

      assert Decision.parse_keys(json) == {:error, :invalid_keys}
    end

    test "refuses text that is not JSON" do
      assert Decision.parse_keys("not json") == {:error, :invalid_keys}
    end
  end
end
