defmodule RsolvHost.Frame do
  @moduledoc """
  Length-prefixed JSON framing between the host and `rsolv-sandbox` (plan,
  "Sandbox CLI contract"): one line holding the decimal byte length, `\\n`, then
  exactly that many bytes of UTF-8 JSON. The host never has to half-close a
  Port's stdin.
  """

  alias RsolvCore.StrictJson

  @max_length_digits 20

  @doc "Frames `term` as JSON."
  @spec encode(term()) :: binary()
  def encode(term) do
    json = JSON.encode!(term)
    Integer.to_string(byte_size(json)) <> "\n" <> json
  end

  @doc """
  Decodes the first frame of `buffer`, refusing one longer than `max_bytes`
  before buffering it. Returns the term and the bytes after it, `:more` when the
  frame is incomplete, or an error.
  """
  @spec decode(binary(), pos_integer()) ::
          {:ok, term(), binary()} | :more | {:error, :frame_too_large | :bad_frame}
  def decode(buffer, max_bytes) do
    case :binary.match(buffer, "\n") do
      :nomatch when byte_size(buffer) > @max_length_digits ->
        {:error, :bad_frame}

      :nomatch ->
        :more

      {at, 1} ->
        payload(
          binary_part(buffer, 0, at),
          binary_part(buffer, at + 1, byte_size(buffer) - at - 1),
          max_bytes
        )
    end
  end

  defp payload(length, rest, max_bytes) do
    with true <- length =~ ~r/\A[0-9]{1,#{@max_length_digits}}\z/,
         {size, ""} <- Integer.parse(length) do
      take(size, rest, max_bytes)
    else
      _not_decimal -> {:error, :bad_frame}
    end
  end

  defp take(size, _rest, max_bytes) when size > max_bytes, do: {:error, :frame_too_large}
  defp take(size, rest, _max_bytes) when byte_size(rest) < size, do: :more

  defp take(size, rest, max_bytes) do
    <<json::binary-size(^size), after_frame::binary>> = rest

    case StrictJson.decode(json, max_bytes: max_bytes) do
      {:ok, term} -> {:ok, term, after_frame}
      {:error, _reason} -> {:error, :bad_frame}
    end
  end
end
