defmodule RsolvCore.Text do
  @moduledoc """
  The one definition of text that is safe to show a person: in a path, a branch
  name, a PR title, a label, an Actions annotation.

      iex> RsolvCore.Text.plain?("src/handler.js")
      true

      iex> RsolvCore.Text.plain?("evil\\u202Esj.exe")
      false
  """

  # C0 controls (including tab, LF and CR), DEL, C1 controls, and the Unicode
  # bidirectional embedding, override and isolate controls.
  @unsafe for c <- Enum.concat([0x00..0x1F, [0x7F], 0x80..0x9F, 0x202A..0x202E, 0x2066..0x2069]),
              do: <<c::utf8>>

  @doc """
  Whether `text` is valid UTF-8 containing no control character (C0, DEL or C1)
  and no bidirectional control (U+202A–U+202E, U+2066–U+2069).
  """
  @spec plain?(term()) :: boolean()
  def plain?(text) when is_binary(text),
    do: String.valid?(text) and not String.contains?(text, @unsafe)

  def plain?(_text), do: false
end
