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
