defmodule RsolvCore.GitAttributes do
  @moduledoc """
  Whether a path falls under a `filter` attribute (LFS and other clean/smudge
  filters; RFC-150 §4.2) according to the base's `.gitattributes` files on its
  ancestor chain. It over-approximates on purpose, so it can only reject more:
  - any matching line that sets `filter` (directly, or through a chain of
    `[attr]` macros defined in any of the files) counts, and a later unset
    doesn't clear it;
  - a bracket expression (ended where git's wildmatch ends it) matches any one
    character but `/`, and one git can't end matches nothing, as in git;
  - a quoted pattern, a pattern over 256 bytes or one with more than four `**`
    matches everything, as does a pattern the regex engine gives up on.

      iex> RsolvCore.GitAttributes.filtered?("assets/logo.png", %{"" => "*.png filter=lfs diff=lfs merge=lfs -text\\n"})
      true

      iex> RsolvCore.GitAttributes.filtered?("src/app.js", %{"" => "*.png filter=lfs\\n"})
      false
  """

  @max_pattern_bytes 256
  @max_globstars 4
  @match_limit 100_000

  @doc """
  Whether `path` is filtered, given `attributes`: directory (`""` for the root)
  → the bytes of that directory's `.gitattributes`.
  """
  @spec filtered?(String.t(), %{String.t() => binary()}) :: boolean()
  def filtered?(path, attributes) do
    # ponytail: re-parses the files and recompiles each pattern per call; for patches near
    # the 1,000-file cap over large .gitattributes, parse once per change set instead.
    files = Map.new(attributes, fn {dir, text} -> {dir, lines(text)} end)
    macros = files |> Map.values() |> Enum.concat() |> macros(MapSet.new())

    path
    |> dirs()
    |> Enum.any?(fn dir ->
      case Map.fetch(files, dir) do
        {:ok, lines} -> lines_filter?(lines, macros, relative(path, dir))
        :error -> false
      end
    end)
  end

  @doc "The directories whose `.gitattributes` apply to `path`, the root (`\"\"`) first."
  @spec dirs(String.t()) :: [String.t()]
  def dirs(path) do
    segments = path |> String.split("/") |> Enum.drop(-1)
    ["" | for(n <- 1..length(segments)//1, do: segments |> Enum.take(n) |> Enum.join("/"))]
  end

  defp relative(path, ""), do: path

  defp relative(path, dir),
    do: binary_part(path, byte_size(dir) + 1, byte_size(path) - byte_size(dir) - 1)

  defp lines(text) do
    text
    |> String.split(["\r\n", "\n"])
    |> Enum.map(&String.split(&1, [" ", "\t"], trim: true))
    |> Enum.reject(&(&1 == [] or String.starts_with?(hd(&1), "#")))
  end

  # Every macro that sets filter, through any chain of macros, from any file:
  # git honours only the root's definitions, so this can only find more.
  defp macros(lines, known) do
    found =
      for ["[attr]" <> name | attrs] <- lines,
          sets_filter?(attrs, known),
          into: known,
          do: name

    if MapSet.equal?(found, known), do: known, else: macros(lines, found)
  end

  defp lines_filter?(lines, macros, relative) do
    Enum.any?(lines, fn
      ["[attr]" <> _ | _attrs] -> false
      [~s(") <> _ | attrs] -> sets_filter?(attrs, macros)
      [pattern | attrs] -> sets_filter?(attrs, macros) and matches?(pattern, relative)
    end)
  end

  defp sets_filter?(attrs, macros) do
    Enum.any?(attrs, fn
      "filter" -> true
      "filter=" <> _driver -> true
      attr -> MapSet.member?(macros, attr)
    end)
  end

  defp matches?(pattern, _relative) when byte_size(pattern) > @max_pattern_bytes, do: true

  defp matches?(pattern, relative) do
    pattern = if String.ends_with?(pattern, "/"), do: "**/" <> pattern <> "**", else: pattern

    if length(String.split(pattern, "**")) - 1 > @max_globstars do
      true
    else
      {anchored?, pattern} = anchor(pattern)
      target = if anchored?, do: relative, else: Path.basename(relative)

      case translate(pattern, []) do
        :never -> false
        regex -> regex_match?("\\A" <> IO.iodata_to_binary(regex) <> "\\z", target)
      end
    end
  end

  # Anything but a clear "no match" (a compile error, the match limit) counts as a match.
  defp regex_match?(source, target) do
    case :re.compile(source) do
      {:ok, regex} ->
        :re.run(target, regex, [:report_errors, {:match_limit, @match_limit}, capture: :none]) !=
          :nomatch

      {:error, _reason} ->
        true
    end
  end

  defp anchor("/" <> rest), do: {true, rest}
  defp anchor(pattern), do: {String.contains?(pattern, "/"), pattern}

  defp translate("**/" <> rest, acc), do: translate(rest, [acc, "(?:.*/)?"])
  defp translate("/**", acc), do: [acc, "/.*"]
  defp translate("**" <> rest, acc), do: translate(rest, [acc, ".*"])
  defp translate("*" <> rest, acc), do: translate(rest, [acc, "[^/]*"])
  defp translate("?" <> rest, acc), do: translate(rest, [acc, "[^/]"])

  # Any one character but `/`: a superset of every bracket expression, negated or not.
  defp translate("[" <> rest, acc) do
    case bracket(rest) do
      {:ok, rest} -> translate(rest, [acc, "[^/]"])
      :unterminated -> :never
    end
  end

  defp translate(<<?\\, c, rest::binary>>, acc), do: translate(rest, [acc, Regex.escape(<<c>>)])
  defp translate(<<c, rest::binary>>, acc), do: translate(rest, [acc, Regex.escape(<<c>>)])
  defp translate("", acc), do: acc

  # Where git's wildmatch ends a bracket expression: after an optional `!` or
  # `^`, the first member is never the end (so a leading `]` is literal); `\\`
  # escapes; a range's end is the next character, even `[`; `[:class:]` is one
  # member. Git aborts the whole match on an unterminated one.
  defp bracket(<<negate, rest::binary>>) when negate in ~c"!^", do: member(rest, 0, true)
  defp bracket(rest), do: member(rest, 0, true)

  defp member("", _prev, _first?), do: :unterminated
  defp member("]" <> rest, _prev, false), do: {:ok, rest}
  defp member(<<?\\, c, rest::binary>>, _prev, _first?), do: member(rest, c, false)
  defp member("\\", _prev, _first?), do: :unterminated

  defp member(<<?-, ?\\, _c, rest::binary>>, prev, _first?) when prev != 0,
    do: member(rest, 0, false)

  defp member(<<?-, c, rest::binary>>, prev, _first?) when prev != 0 and c != ?],
    do: member(rest, 0, false)

  defp member("[:" <> rest, _prev, _first?) do
    case :binary.match(rest, "]") do
      {at, 1} when at > 0 and binary_part(rest, at - 1, 1) == ":" ->
        member(binary_part(rest, at + 1, byte_size(rest) - at - 1), 0, false)

      {_at, 1} ->
        member(":" <> rest, ?[, false)

      :nomatch ->
        :unterminated
    end
  end

  defp member(<<c, rest::binary>>, _prev, _first?), do: member(rest, c, false)
end
