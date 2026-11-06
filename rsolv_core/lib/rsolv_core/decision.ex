defmodule RsolvCore.Decision do
  @moduledoc """
  The signed publish decision (RFC-150 §6.1, ADR-075). The platform signs it; the
  publish job verifies it before any write. The signature is Ed25519 over
  `"rsolv-decision-v1\\n" <> CanonicalJson.encode!(decision)`.

  An envelope is `%{"decision" => decision, "signature" => base64url}`; the publish
  response may carry an unsigned `"bodies"` member beside them. `verify/3` takes
  the response bytes and checks, in order: strict decoding, the shape (exactly the
  §6.1 fields, a canonical unpadded base64url signature), the key (`kid` known and
  not past `not_after`), the signature, the version, the schema, the validity
  window, the change set and its digest, and finally the run binding.

  ## Schema

  - `run_id`, `repository_id`, `issue`, the three `*_attempt`s and the three
    `check_run_id_*`s are positive integers; `decision_id` is 1–128 of
    `[A-Za-z0-9_-]`;
  - `base_sha` is 40 lowercase hex; `target_branch`, `branch` and
    `policy_version` are 1–255 characters of `RsolvCore.Text.plain?/1` text;
  - `verify_mode` is `"job"` (RED and GREEN ran in the verify job) or
    `"inline"` (they ran in the work job, RFC-150 §5's opt-in inline mode);
  - `red_paths` is non-empty, without repeats, and every path is an `add`;
  - `effects` has exactly `pr_title` (1–256 characters of plain text),
    `pr_body_sha256` (64 lowercase hex), `labels` (distinct, 1–50 characters of
    plain text each), `comments` (`[{"issue" => positive integer,
    "body_sha256" => 64 lowercase hex}]`), `red_commit_message` and
    `fix_commit_message` (non-empty plain text, newlines allowed, at most 64 KiB);
  - `issued_at` and `expires_at` are whole UTC seconds, `YYYY-MM-DDTHH:MM:SSZ`.

  ## Validity

  `issued_at` must be before `expires_at`, at most 30 minutes before it. A
  decision is accepted from 60 s before `issued_at` (clock skew) up to, but not
  at, `expires_at`.
  """

  alias RsolvCore.{CanonicalJson, ChangeSet, StrictJson, Text}

  @context "rsolv-decision-v1\n"
  @max_validity_s 30 * 60
  @skew_s 60
  @ids ~w(run_id repository_id issue work_attempt verify_attempt publish_attempt
          check_run_id_work check_run_id_verify check_run_id_publish)
  @verify_modes ~w(job inline)
  @max_message_bytes 64 * 1024
  @binding ~w(check_run_id_publish issue publish_attempt repository_id run_id)
  @max_envelope_bytes 1024 * 1024
  @max_keys_bytes 64 * 1024
  @fields ~w(v kid decision_id run_id repository_id issue work_attempt verify_attempt
             publish_attempt check_run_id_work check_run_id_verify check_run_id_publish
             base_sha target_branch branch change_set change_set_digest red_paths
             policy_version verify_mode effects issued_at expires_at)
          |> Enum.sort()

  @type key :: %{kid: String.t(), public_key: <<_::256>>, not_after: Date.t()}
  @type error ::
          :malformed_decision
          | :unknown_kid
          | :key_expired
          | :bad_signature
          | :unsupported_version
          | :expired
          | :not_yet_valid
          | :validity_too_long
          | :digest_mismatch
          | :bad_red_paths
          | :malformed_change_set
          | :invalid_path
          | :invalid_entry
          | :unsorted
          | :duplicate_path
          | :invalid_binding
          | {:binding_mismatch, String.t()}

  @doc "Signs `decision` with an Ed25519 secret key, returning the envelope."
  @spec sign(map(), <<_::256>>) :: map()
  def sign(%{"kid" => _kid} = decision, secret) do
    signature = :crypto.sign(:eddsa, :none, message!(decision), [secret, :ed25519])
    %{"decision" => decision, "signature" => Base.url_encode64(signature, padding: false)}
  end

  @doc """
  Parses the accepted public-key set: a JSON list of
  `{"kid", "public_key" (base64url, 32 bytes), "not_after" (ISO 8601 date)}`
  with unique kids.
  """
  @spec parse_keys(String.t()) :: {:ok, [key()]} | {:error, :invalid_keys}
  def parse_keys(json) when is_binary(json) do
    with {:ok, [_ | _] = list} <- StrictJson.decode(json, max_bytes: @max_keys_bytes),
         {:ok, keys} <- parse_each(list, []),
         true <- keys |> Enum.uniq_by(& &1.kid) |> length() == length(keys) do
      {:ok, keys}
    else
      _invalid -> {:error, :invalid_keys}
    end
  end

  def parse_keys(_json), do: {:error, :invalid_keys}

  @doc """
  Verifies the decision response body, the raw JSON bytes of
  `{"decision", "signature", ...}`, against a key set at `:now`, and checks that
  the decision carries the run binding in `:expect`.

  `:expect` is required and complete: a map with exactly the string keys
  `run_id`, `repository_id`, `issue`, `publish_attempt` and
  `check_run_id_publish`, each a positive integer the publish job established
  from its own trusted identity. Anything else is `{:error, :invalid_binding}`,
  before the response is looked at. Each field is compared with `===`.

  The bytes are decoded here, through `RsolvCore.StrictJson` (at most
  1 MiB, no repeated member names), so no caller can
  verify a map another parser built. The decoded envelope is returned too, for
  its unsigned `bodies`.
  """
  @spec verify(binary(), [key()], now: DateTime.t(), expect: map()) ::
          {:ok, %{decision: map(), change_set: [ChangeSet.Entry.t()], envelope: map()}}
          | {:error, error()}
  def verify(json, keys, opts) do
    now = Keyword.fetch!(opts, :now)
    expect = Keyword.fetch!(opts, :expect)

    with :ok <- expected_binding(expect),
         {:ok, envelope} <- decode(json),
         {:ok, decision, signature} <- shape(envelope),
         {:ok, key} <- key_for(keys, decision["kid"], now),
         :ok <- signature(decision, signature, key),
         :ok <- version(decision),
         :ok <- schema(decision),
         :ok <- validity(decision, now),
         {:ok, change_set} <- change_set(decision),
         :ok <- binding(decision, expect) do
      {:ok, %{decision: decision, change_set: change_set, envelope: envelope}}
    end
  end

  defp expected_binding(expect) when is_map(expect) and map_size(expect) == length(@binding) do
    if expect |> Map.keys() |> Enum.sort() == @binding and
         expect |> Map.values() |> Enum.all?(&(is_integer(&1) and &1 > 0)),
       do: :ok,
       else: {:error, :invalid_binding}
  end

  defp expected_binding(_expect), do: {:error, :invalid_binding}

  defp decode(json) do
    case StrictJson.decode(json, max_bytes: @max_envelope_bytes) do
      {:ok, envelope} -> {:ok, envelope}
      {:error, _reason} -> {:error, :malformed_decision}
    end
  end

  defp parse_each([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_each(
         [%{"kid" => kid, "public_key" => encoded, "not_after" => date} = json | rest],
         acc
       )
       when map_size(json) == 3 and is_binary(kid) and is_binary(encoded) and is_binary(date) do
    with {:ok, <<_::256>> = public_key} <- base64url(encoded),
         {:ok, not_after} <- Date.from_iso8601(date) do
      parse_each(rest, [%{kid: kid, public_key: public_key, not_after: not_after} | acc])
    else
      _invalid -> :error
    end
  end

  defp parse_each(_list, _acc), do: :error

  defp shape(%{"decision" => %{} = decision, "signature" => encoded}) when is_binary(encoded) do
    with true <- decision |> Map.keys() |> Enum.sort() == @fields,
         {:ok, <<signature::binary-64>>} <- base64url(encoded) do
      {:ok, decision, signature}
    else
      _malformed -> {:error, :malformed_decision}
    end
  end

  defp shape(_envelope), do: {:error, :malformed_decision}

  # Only the canonical form: unpadded, and zero trailing bits, so one value has
  # one spelling.
  defp base64url(encoded) do
    with {:ok, bytes} <- Base.url_decode64(encoded, padding: false),
         ^encoded <- Base.url_encode64(bytes, padding: false) do
      {:ok, bytes}
    else
      _noncanonical -> :error
    end
  end

  defp schema(decision) do
    if Enum.all?(@ids, &positive?(decision[&1])) and decision_id?(decision["decision_id"]) and
         hex?(decision["base_sha"], 40) and
         Enum.all?(~w(target_branch branch policy_version), &line?(decision[&1], 255)) and
         decision["verify_mode"] in @verify_modes and effects?(decision["effects"]),
       do: :ok,
       else: {:error, :malformed_decision}
  end

  defp effects?(
         %{
           "pr_title" => title,
           "pr_body_sha256" => body_sha,
           "labels" => labels,
           "comments" => comments,
           "red_commit_message" => red_message,
           "fix_commit_message" => fix_message
         } = effects
       )
       when map_size(effects) == 6 do
    line?(title, 256) and hex?(body_sha, 64) and labels?(labels) and comments?(comments) and
      message?(red_message) and message?(fix_message)
  end

  defp effects?(_effects), do: false

  defp labels?(labels) when is_list(labels),
    do: Enum.all?(labels, &line?(&1, 50)) and Enum.uniq(labels) == labels

  defp labels?(_labels), do: false

  defp comments?(comments) when is_list(comments), do: Enum.all?(comments, &comment?/1)
  defp comments?(_comments), do: false

  defp comment?(%{"issue" => issue, "body_sha256" => body_sha} = comment)
       when map_size(comment) == 2,
       do: positive?(issue) and hex?(body_sha, 64)

  defp comment?(_comment), do: false

  defp positive?(value), do: is_integer(value) and value > 0

  defp decision_id?(id), do: is_binary(id) and id =~ ~r/\A[A-Za-z0-9_-]{1,128}\z/

  defp hex?(value, length),
    do: is_binary(value) and byte_size(value) == length and value =~ ~r/\A[0-9a-f]+\z/

  defp line?(text, max_chars), do: Text.plain?(text) and String.length(text) in 1..max_chars

  defp message?(text) when is_binary(text) and byte_size(text) in 1..@max_message_bytes,
    do: text |> String.replace("\n", "") |> Text.plain?()

  defp message?(_text), do: false

  defp key_for(keys, kid, now) do
    case Enum.find(keys, &(&1.kid == kid)) do
      nil -> {:error, :unknown_kid}
      key -> unexpired(key, DateTime.to_date(now))
    end
  end

  defp unexpired(%{not_after: not_after} = key, today) do
    case Date.compare(today, not_after) do
      :gt -> {:error, :key_expired}
      _today_or_before -> {:ok, key}
    end
  end

  defp signature(decision, signature, %{public_key: public_key}) do
    with {:ok, json} <- CanonicalJson.encode(decision),
         true <-
           :crypto.verify(:eddsa, :none, @context <> json, signature, [public_key, :ed25519]) do
      :ok
    else
      _invalid -> {:error, :bad_signature}
    end
  end

  defp version(%{"v" => 1}), do: :ok
  defp version(_decision), do: {:error, :unsupported_version}

  defp validity(%{"issued_at" => issued_at, "expires_at" => expires_at}, now) do
    with {:ok, issued, _offset} <- parse_time(issued_at),
         {:ok, expires, _offset} <- parse_time(expires_at) do
      window(
        DateTime.diff(expires, issued),
        DateTime.diff(issued, now),
        DateTime.compare(now, expires)
      )
    else
      _unparseable -> {:error, :malformed_decision}
    end
  end

  defp parse_time(text) when is_binary(text) do
    if text =~ ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/,
      do: DateTime.from_iso8601(text),
      else: :error
  end

  defp parse_time(_other), do: :error

  defp window(validity_s, _ahead_s, _now_vs_expiry) when validity_s <= 0,
    do: {:error, :malformed_decision}

  defp window(validity_s, _ahead_s, _now_vs_expiry) when validity_s > @max_validity_s,
    do: {:error, :validity_too_long}

  defp window(_validity_s, ahead_s, _now_vs_expiry) when ahead_s > @skew_s,
    do: {:error, :not_yet_valid}

  defp window(_validity_s, _ahead_s, :lt), do: :ok
  defp window(_validity_s, _ahead_s, _at_or_after), do: {:error, :expired}

  defp change_set(%{
         "change_set" => json,
         "change_set_digest" => digest,
         "red_paths" => red_paths
       }) do
    with {:ok, entries} <- ChangeSet.from_json(json),
         :ok <- digest_matches(ChangeSet.digest(entries), digest),
         :ok <- red_paths_added(entries, red_paths) do
      {:ok, entries}
    end
  end

  defp digest_matches(digest, digest), do: :ok
  defp digest_matches(_computed, _signed), do: {:error, :digest_mismatch}

  defp red_paths_added(entries, [_ | _] = red_paths) do
    added = for %{op: :add, path: path} <- entries, into: MapSet.new(), do: path

    if Enum.all?(red_paths, &MapSet.member?(added, &1)) and Enum.uniq(red_paths) == red_paths,
      do: :ok,
      else: {:error, :bad_red_paths}
  end

  defp red_paths_added(_entries, _red_paths), do: {:error, :bad_red_paths}

  defp binding(decision, expect) do
    case Enum.find(expect, fn {field, value} -> decision[field] !== value end) do
      nil -> :ok
      {field, _value} -> {:error, {:binding_mismatch, field}}
    end
  end

  defp message!(decision), do: @context <> CanonicalJson.encode!(decision)
end
