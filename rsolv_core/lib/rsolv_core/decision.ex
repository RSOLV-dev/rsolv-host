defmodule RsolvCore.Decision do
  @moduledoc """
  The signed publish decision (RFC-150 §6.1, ADR-075). The platform signs it; the
  publish job verifies it before any write. The signature is Ed25519 over
  `"rsolv-decision-v1\\n" <> CanonicalJson.encode!(decision)`.

  An envelope is `%{"decision" => decision, "signature" => base64url}`; the publish
  response may carry an unsigned `"bodies"` member beside them. `verify/3` takes
  the response bytes and checks, in order: strict decoding, the shape, the key (`kid` known and not past `not_after`), the
  signature, the version, the validity window (at most 30 minutes, with 60 s of
  clock skew), the change set and its digest, and finally the run binding.
  """

  alias RsolvCore.{CanonicalJson, ChangeSet, StrictJson}

  @context "rsolv-decision-v1\n"
  @max_validity_s 30 * 60
  @skew_s 60
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
  the decision carries every `{field, value}` of `:expect` (the run binding).

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

    with {:ok, envelope} <- decode(json),
         {:ok, decision, signature} <- shape(envelope),
         {:ok, key} <- key_for(keys, decision["kid"], now),
         :ok <- signature(decision, signature, key),
         :ok <- version(decision),
         :ok <- validity(decision, now),
         {:ok, change_set} <- change_set(decision),
         :ok <- binding(decision, Keyword.fetch!(opts, :expect)) do
      {:ok, %{decision: decision, change_set: change_set, envelope: envelope}}
    end
  end

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
    with {:ok, <<_::256>> = public_key} <- Base.url_decode64(encoded, padding: false),
         {:ok, not_after} <- Date.from_iso8601(date) do
      parse_each(rest, [%{kid: kid, public_key: public_key, not_after: not_after} | acc])
    else
      _invalid -> :error
    end
  end

  defp parse_each(_list, _acc), do: :error

  defp shape(%{"decision" => %{} = decision, "signature" => encoded}) when is_binary(encoded) do
    with true <- decision |> Map.keys() |> Enum.sort() == @fields,
         {:ok, <<signature::binary-64>>} <- Base.url_decode64(encoded, padding: false) do
      {:ok, decision, signature}
    else
      _malformed -> {:error, :malformed_decision}
    end
  end

  defp shape(_envelope), do: {:error, :malformed_decision}

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

  defp parse_time(text) when is_binary(text), do: DateTime.from_iso8601(text)
  defp parse_time(_other), do: :error

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

  defp red_paths_added(entries, red_paths) when is_list(red_paths) do
    added = for %{op: :add, path: path} <- entries, into: MapSet.new(), do: path

    if Enum.all?(red_paths, &MapSet.member?(added, &1)),
      do: :ok,
      else: {:error, :bad_red_paths}
  end

  defp red_paths_added(_entries, _red_paths), do: {:error, :bad_red_paths}

  defp binding(decision, expect) do
    case Enum.find(expect, fn {field, value} -> decision[field] != value end) do
      nil -> :ok
      {field, _value} -> {:error, {:binding_mismatch, field}}
    end
  end

  defp message!(decision), do: @context <> CanonicalJson.encode!(decision)
end
