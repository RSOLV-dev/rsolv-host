defmodule RsolvCore.GitAttributes do
  @moduledoc """
  Whether a path falls under a `filter` attribute (LFS and other clean/smudge
  filters; RFC-150 §4.2) according to the base's `.gitattributes` files on its
  ancestor chain, read as git's attr.c and wildmatch read them, and checked
  against `git check-attr` by `test/vectors/gitattributes.json`. Only `filter`
  is checked: the patch is `git diff` output against the work tree, which has
  already applied `ident`, `eol`/`text` and `working-tree-encoding`, base facts
  are blobs from `git ls-tree`/`git cat-file`, and the host commits raw blobs.

  It over-approximates on purpose, so it can only reject more:
  - any matching line that sets `filter` (directly, or through a chain of
    `[attr]` macros, from any definition in any of the files) counts, a later
    unset doesn't clear it, and a line git drops for an invalid attribute
    name still counts;
  - a bracket expression (ended where git's wildmatch ends it) matches any one
    character but `/`, and `**` away from a `/` matches `/` too;
  - a pattern over 256 bytes or with more than four `**` matches everything,
    as does a pattern the regex engine gives up on.

      iex> RsolvCore.GitAttributes.filtered?("assets/logo.png", %{"" => "*.png filter=lfs diff=lfs merge=lfs -text\\n"})
      true

      iex> RsolvCore.GitAttributes.filtered?("src/app.js", %{"" => "*.png filter=lfs\\n"})
      false
  """

  @max_pattern_bytes 256
  @max_globstars 4
  @match_limit 100_000
  @max_lines 50_000
  @max_macros 1_024
  @max_macro_depth 64
  @max_rules 1_024
  @blanks [" ", "\t", "\r"]

  @enforce_keys [:rules]
  defstruct @enforce_keys

  alias RsolvCore.{BaseFacts, Patch}

  @typedoc """
  Compiled attributes: per directory, a matcher for each line that sets
  `filter`; `:all` when the input was over a cap, so every path is filtered.
  """
  @type t :: %__MODULE__{rules: %{String.t() => [matcher()]} | :all}
  @typep matcher :: :any | {:basename | :path, tuple()}

  @doc """
  Compiles `attributes` (directory, `""` for the root, → the bytes of that
  directory's `.gitattributes`) once, for any number of `filtered?/2` calls.
  Over #{@max_lines} lines, #{@max_macros} macros, a macro chain #{@max_macro_depth}
  deep or #{@max_rules} lines that set `filter`, every path is filtered.
  """
  @spec compile(%{String.t() => binary()}) :: t()
  def compile(attributes) do
    with {:ok, files} <- parse(attributes),
         {:ok, setters} <- setters(files),
         {:ok, rules} <- rules(files, setters) do
      %__MODULE__{rules: rules}
    else
      :over_cap -> %__MODULE__{rules: :all}
    end
  end

  @doc """
  Whether `path` is filtered, given compiled attributes or the raw map
  `compile/1` takes.
  """
  @spec filtered?(String.t(), t() | %{String.t() => binary()}) :: boolean()
  def filtered?(_path, %__MODULE__{rules: :all}), do: true

  def filtered?(path, %__MODULE__{rules: rules}) do
    path
    |> dirs()
    |> Enum.any?(fn dir ->
      relative = relative(path, dir)
      rules |> Map.get(dir, []) |> Enum.any?(&matches?(&1, relative))
    end)
  end

  def filtered?(path, attributes), do: filtered?(path, compile(attributes))

  @doc "The directories whose `.gitattributes` apply to `path`, the root (`\"\"`) first."
  @spec dirs(String.t()) :: [String.t()]
  def dirs(path), do: ["" | BaseFacts.ancestors(path)]

  defp relative(path, ""), do: path

  defp relative(path, dir),
    do: binary_part(path, byte_size(dir) + 1, byte_size(path) - byte_size(dir) - 1)

  defp parse(attributes) do
    Enum.reduce_while(attributes, {:ok, %{}, 0}, fn {dir, text}, {:ok, files, count} ->
      lines = lines(text)
      count = count + length(lines)

      if count > @max_lines,
        do: {:halt, :over_cap},
        else: {:cont, {:ok, Map.put(files, dir, lines), count}}
    end)
    |> case do
      {:ok, files, _count} -> {:ok, files}
      :over_cap -> :over_cap
    end
  end

  # As git's attr.c reads a file: a leading UTF-8 BOM is skipped, lines end at
  # "\n", blanks are space, tab and "\r", and a pattern may be C-quoted (and
  # then ends at its first NUL, since git reads it as a C string).
  defp lines("\uFEFF" <> text), do: lines(text)

  defp lines(text) do
    for raw <- :binary.split(text, "\n", [:global]),
        line = skip_blanks(raw),
        line != "" and not String.starts_with?(line, "#"),
        do: line |> name() |> entry()
  end

  defp name(~s(") <> _ = line) do
    case Patch.c_unquote(line) do
      {:ok, name, rest} -> {name |> :binary.split(<<0>>) |> hd(), rest}
      :error -> bare(line)
    end
  end

  defp name(line), do: bare(line)

  defp bare(line) do
    case :binary.match(line, @blanks) do
      {at, _} -> {binary_part(line, 0, at), binary_part(line, at, byte_size(line) - at)}
      :nomatch -> {line, ""}
    end
  end

  defp entry({"[attr]" <> macro, rest}) when macro != "" do
    {name, _rest} = macro |> skip_blanks() |> bare()
    {:macro, name, attributes(rest)}
  end

  defp entry({pattern, rest}), do: {:pattern, pattern, attributes(rest)}

  defp attributes(rest), do: String.split(rest, @blanks, trim: true)

  defp skip_blanks(<<c, rest::binary>>) when c in ~c" \t\r", do: skip_blanks(rest)
  defp skip_blanks(line), do: line

  # The macros that set filter through any chain of macros, from any file and
  # any of a macro's definitions: git honours only the root's last definition,
  # so this can only find more. Breadth-first from the macros that set filter
  # directly, over "macro → the macros naming it", so each edge is walked once.
  defp setters(files) do
    macros = for {_dir, lines} <- files, {:macro, name, attrs} <- lines, do: {name, attrs}

    if length(macros) > @max_macros do
      :over_cap
    else
      direct = for {name, attrs} <- macros, Enum.any?(attrs, &sets_filter?/1), do: name

      named_by =
        Enum.group_by(
          for({name, attrs} <- macros, attr <- attrs, bare?(attr), do: {attr, name}),
          &elem(&1, 0),
          &elem(&1, 1)
        )

      reach(direct, MapSet.new(direct), named_by, 0)
    end
  end

  defp reach([], seen, _named_by, _depth), do: {:ok, seen}
  defp reach(_frontier, _seen, _named_by, @max_macro_depth), do: :over_cap

  defp reach(frontier, seen, named_by, depth) do
    next =
      frontier
      |> Enum.flat_map(&Map.get(named_by, &1, []))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(seen, &1))

    reach(next, MapSet.union(seen, MapSet.new(next)), named_by, depth + 1)
  end

  defp rules(files, setters) do
    rules =
      Map.new(files, fn {dir, lines} ->
        {dir,
         for(
           {:pattern, pattern, attrs} <- lines,
           Enum.any?(attrs, &(sets_filter?(&1) or MapSet.member?(setters, &1))),
           matcher = matcher(pattern),
           matcher != :never,
           do: matcher
         )}
      end)

    if rules |> Map.values() |> Enum.map(&length/1) |> Enum.sum() > @max_rules,
      do: :over_cap,
      else: {:ok, rules}
  end

  defp sets_filter?("filter"), do: true
  defp sets_filter?("filter=" <> _driver), do: true
  defp sets_filter?(_attr), do: false

  # An attribute set to true, the only state in which git expands a macro.
  defp bare?(<<c, _::binary>> = attr) when c not in ~c"-!", do: not String.contains?(attr, "=")
  defp bare?(_attr), do: false

  defp matches?(:any, _relative), do: true
  defp matches?({:basename, regex}, relative), do: regex_match?(regex, Path.basename(relative))
  defp matches?({:path, regex}, relative), do: regex_match?(regex, relative)

  # Anything but a clear "no match" (the match limit) counts as a match.
  # ponytail: the worst case is rules × paths × @match_limit backtracking steps
  # (1,024 × 1,000 × 100,000); add an aggregate step budget that fails closed if
  # base attributes ever become attacker-shaped rather than the customer's own.
  defp regex_match?(regex, target),
    do:
      :re.run(target, regex, [:report_errors, {:match_limit, @match_limit}, capture: :none]) !=
        :nomatch

  # git never matches a file with a directory-only or a negative pattern.
  defp matcher("!" <> _negative), do: :never
  defp matcher(pattern) when binary_part(pattern, byte_size(pattern) - 1, 1) == "/", do: :never
  defp matcher(pattern) when byte_size(pattern) > @max_pattern_bytes, do: :any

  defp matcher(pattern) do
    if length(String.split(pattern, "**")) - 1 > @max_globstars do
      :any
    else
      {anchored?, pattern} = anchor(pattern)

      with regex when regex != :never <- translate(pattern, []),
           {:ok, compiled} <- :re.compile(["\\A", regex, "\\z"]) do
        {if(anchored?, do: :path, else: :basename), compiled}
      else
        :never -> :never
        {:error, _reason} -> :any
      end
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
  # ponytail: 15 of the vectors' 26 over-approximations; translate the members into
  # a PCRE class (minus `/`) if that ever refuses real paths.
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
