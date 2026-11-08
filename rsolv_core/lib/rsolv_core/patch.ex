defmodule RsolvCore.Patch do
  @moduledoc """
  A strict parser for the bytes of `git diff --binary --full-index --no-renames
  --no-textconv --no-ext-diff <base>` (RFC-150 §4.1). It reads structure only:
  `index` lines are checked for shape and otherwise ignored (the sandbox wrote
  them), and no base content is needed until `RsolvCore.Canonicalize`.

  Refusals:
  - `:binary` — `Binary files … differ`, `GIT binary patch`, or a NUL byte anywhere;
  - `:rename` — similarity, rename or copy headers;
  - `:mode_change` — `old mode`/`new mode`;
  - `:executable` — a new file whose mode isn't `100644`;
  - `:not_regular_file` — a symlink (`120000`) or gitlink (`160000`) on either side;
  - `:invalid_path` — a path `RsolvCore.ChangeSet.valid_path?/1` refuses, or names that disagree;
  - `:duplicate_path`, `:too_large` (over 8 MiB, 200,000 lines or 1,000 files);
  - `:malformed` — anything else that isn't exactly git's format.

      iex> {:ok, [diff]} = RsolvCore.Patch.parse("diff --git a/x b/x\\nnew file mode 100644\\nindex 0000000000000000000000000000000000000000..e69de29bb2d1d6434b8b29ae775ad8c2e48c5391\\n")
      iex> {diff.path, diff.op, diff.hunks}
      {"x", :add, []}
  """

  alias RsolvCore.ChangeSet

  defmodule FileDiff do
    @moduledoc "One file of a patch. See `RsolvCore.Patch`."
    @enforce_keys [:path, :op, :hunks]
    defstruct @enforce_keys

    @typedoc "A hunk line: its kind, its bytes without the newline, and whether a newline ended it."
    @type line :: {:context | :del | :add, binary(), boolean()}
    @type hunk :: %{old_start: non_neg_integer(), old_count: non_neg_integer(), lines: [line()]}
    @type t :: %__MODULE__{path: String.t(), op: :add | :modify | :delete, hunks: [hunk()]}
  end

  @type reason ::
          :binary
          | :rename
          | :mode_change
          | :executable
          | :not_regular_file
          | :invalid_path
          | :duplicate_path
          | :too_large
          | :malformed

  @max_bytes 8 * 1024 * 1024
  @max_files 1_000
  @max_lines 200_000
  @file_modes ["100644", "100755"]
  @hunk_header ~r/\A@@ -(\d{1,9})(?:,(\d{1,9}))? \+(\d{1,9})(?:,(\d{1,9}))? @@(?: |\z)/

  @doc "Parses patch bytes into one `FileDiff` per path. The empty patch is `{:ok, []}`."
  @spec parse(term()) :: {:ok, [FileDiff.t()]} | {:error, reason()}
  def parse(""), do: {:ok, []}

  def parse(bytes) when is_binary(bytes) and byte_size(bytes) > @max_bytes,
    do: {:error, :too_large}

  def parse(bytes) when is_binary(bytes) do
    with :ok <- text(bytes),
         :ok <- line_count(bytes, 0, 0) do
      case bytes |> :binary.split("\n", [:global]) |> Enum.reverse() do
        ["" | reversed] -> reversed |> Enum.reverse() |> files([], 0) |> unique()
        _no_final_newline -> {:error, :malformed}
      end
    end
  end

  def parse(_other), do: {:error, :malformed}

  defp text(bytes),
    do: if(:binary.match(bytes, <<0>>) == :nomatch, do: :ok, else: {:error, :binary})

  # Counted before splitting, so a patch of short lines is refused before it
  # becomes a list of millions of sub-binaries.
  defp line_count(_bytes, _from, @max_lines), do: {:error, :too_large}

  defp line_count(bytes, from, count) do
    case :binary.match(bytes, "\n", scope: {from, byte_size(bytes) - from}) do
      {at, 1} -> line_count(bytes, at + 1, count + 1)
      :nomatch -> :ok
    end
  end

  @doc "The paths `diffs` touch, sorted by bytes."
  @spec touched_paths([FileDiff.t()]) :: [String.t()]
  def touched_paths(diffs), do: diffs |> Enum.map(& &1.path) |> Enum.sort()

  defp files([], acc, _count), do: {:ok, Enum.reverse(acc)}
  defp files(_lines, _acc, @max_files), do: {:error, :too_large}

  defp files(["diff --git " <> names | rest], acc, count) do
    with {:ok, path} <- header_path(names),
         {:ok, op, rest} <- extended(rest, :modify),
         {:ok, hunks, rest} <- content(rest, path, op) do
      files(rest, [%FileDiff{path: path, op: op, hunks: hunks} | acc], count + 1)
    end
  end

  defp files(_lines, _acc, _count), do: {:error, :malformed}

  defp unique({:ok, diffs} = ok) do
    paths = Enum.map(diffs, & &1.path)
    if Enum.uniq(paths) == paths, do: ok, else: {:error, :duplicate_path}
  end

  defp unique(error), do: error

  # `diff --git a/P b/P`: both names quoted, or both bare and equal.
  defp header_path(~s(") <> _ = names) do
    with {:ok, "a/" <> a, " " <> rest} <- quoted(names),
         {:ok, "b/" <> b, ""} <- quoted(rest),
         true <- a == b do
      valid(a)
    else
      _disagree -> {:error, :invalid_path}
    end
  end

  defp header_path("a/" <> rest) when byte_size(rest) >= 5 and rem(byte_size(rest) - 3, 2) == 0 do
    half = div(byte_size(rest) - 3, 2)
    path = binary_part(rest, 0, half)

    if binary_part(rest, half, 3) == " b/" and binary_part(rest, half + 3, half) == path,
      do: valid(path),
      else: {:error, :invalid_path}
  end

  defp header_path(_names), do: {:error, :invalid_path}

  defp valid(path),
    do: if(ChangeSet.valid_path?(path), do: {:ok, path}, else: {:error, :invalid_path})

  defp extended(["new file mode " <> mode | rest], :modify),
    do: with(:ok <- new_mode(mode), do: extended(rest, :add))

  defp extended(["deleted file mode " <> mode | rest], :modify),
    do: with(:ok <- regular(mode), do: extended(rest, :delete))

  defp extended(["index " <> index | rest], op),
    do: with(:ok <- index(index), do: after_index(rest, op))

  defp extended([line | _rest], _op), do: {:error, refusal(line)}
  defp extended([], _op), do: {:error, :malformed}

  defp refusal("old mode " <> _), do: :mode_change
  defp refusal("new mode " <> _), do: :mode_change
  defp refusal("similarity index " <> _), do: :rename
  defp refusal("dissimilarity index " <> _), do: :rename
  defp refusal("rename " <> _), do: :rename
  defp refusal("copy " <> _), do: :rename
  defp refusal("Binary files " <> _), do: :binary
  defp refusal("GIT binary patch"), do: :binary
  defp refusal(_line), do: :malformed

  defp after_index(["Binary files " <> _ | _rest], _op), do: {:error, :binary}
  defp after_index(["GIT binary patch" | _rest], _op), do: {:error, :binary}
  defp after_index(rest, op), do: {:ok, op, rest}

  defp index(index) do
    case String.split(index, " ") do
      [shas] -> shas(shas)
      [shas, mode] -> with :ok <- shas(shas), do: regular(mode)
      _other -> {:error, :malformed}
    end
  end

  defp shas(shas),
    do: if(shas =~ ~r/\A[0-9a-f]{40}\.\.[0-9a-f]{40}\z/, do: :ok, else: {:error, :malformed})

  defp new_mode("100644"), do: :ok
  defp new_mode("100755"), do: {:error, :executable}
  defp new_mode(mode), do: regular(mode)

  defp regular(mode) when mode in @file_modes, do: :ok
  defp regular(mode) when mode in ["120000", "160000"], do: {:error, :not_regular_file}
  defp regular(_mode), do: {:error, :malformed}

  defp content(["--- " <> old, "+++ " <> new | rest], path, op) do
    with :ok <- sides(old, new, path, op),
         {:ok, [_ | _] = hunks, rest} <- hunks(rest, []) do
      {:ok, hunks, rest}
    else
      {:ok, [], _rest} -> {:error, :malformed}
      error -> error
    end
  end

  defp content(["--- " <> _ | _rest], _path, _op), do: {:error, :malformed}
  # An empty file added or deleted has no ---/+++ lines and no hunks.
  defp content(rest, _path, op) when op in [:add, :delete], do: {:ok, [], rest}
  defp content(_rest, _path, :modify), do: {:error, :malformed}

  defp sides(old, new, path, op) do
    if {side(old, "a/"), side(new, "b/")} == expected(op, path),
      do: :ok,
      else: {:error, :invalid_path}
  end

  defp expected(:add, path), do: {:null, path}
  defp expected(:delete, path), do: {path, :null}
  defp expected(:modify, path), do: {path, path}

  defp side("/dev/null", _prefix), do: :null

  # git appends a tab to a ---/+++ name that contains a space.
  defp side(name, prefix) do
    with {:ok, unquoted} <- name |> String.replace_suffix("\t", "") |> unquote_name(),
         true <- String.starts_with?(unquoted, prefix) do
      binary_part(unquoted, byte_size(prefix), byte_size(unquoted) - byte_size(prefix))
    else
      _invalid -> :invalid
    end
  end

  defp unquote_name(~s(") <> _ = name) do
    case quoted(name) do
      {:ok, bytes, ""} -> {:ok, bytes}
      _invalid -> :error
    end
  end

  defp unquote_name(name), do: {:ok, name}

  # git's C-style quoting: \a \b \t \n \v \f \r \" \\ and three-digit octal.
  defp quoted(~s(") <> rest), do: unescape(rest, [])
  defp quoted(_bare), do: :error

  defp unescape(~s(") <> rest, acc),
    do: {:ok, acc |> Enum.reverse() |> :erlang.list_to_binary(), rest}

  defp unescape(<<?\\, c, rest::binary>>, acc) when c in ~c"abtnvfr\"\\",
    do: unescape(rest, [escape(c) | acc])

  defp unescape(<<?\\, a, b, c, rest::binary>>, acc)
       when a in ?0..?3 and b in ?0..?7 and c in ?0..?7,
       do: unescape(rest, [(a - ?0) * 64 + (b - ?0) * 8 + (c - ?0) | acc])

  defp unescape(<<?\\, _rest::binary>>, _acc), do: :error
  defp unescape(<<c, rest::binary>>, acc), do: unescape(rest, [c | acc])
  defp unescape("", _acc), do: :error

  defp escape(?a), do: 7
  defp escape(?b), do: 8
  defp escape(?t), do: 9
  defp escape(?n), do: 10
  defp escape(?v), do: 11
  defp escape(?f), do: 12
  defp escape(?r), do: 13
  defp escape(c), do: c

  defp hunks(["@@ " <> _ = header | rest], acc) do
    with {:ok, hunk, rest} <- hunk(header, rest), do: hunks(rest, [hunk | acc])
  end

  defp hunks(rest, acc), do: {:ok, Enum.reverse(acc), rest}

  defp hunk(header, rest) do
    case Regex.run(@hunk_header, header, capture: :all_but_first) do
      nil ->
        {:error, :malformed}

      captures ->
        [old_start, old_count, _new_start, new_count] =
          captures ++ List.duplicate("", 4 - length(captures))

        old_count = count(old_count)

        with {:ok, lines, rest} <- body(rest, old_count, count(new_count), []) do
          {:ok, %{old_start: String.to_integer(old_start), old_count: old_count, lines: lines},
           rest}
        end
    end
  end

  defp count(""), do: 1
  defp count(digits), do: String.to_integer(digits)

  defp body(["\\ " <> _ | rest], old, new, [{kind, text, true} | acc]),
    do: body(rest, old, new, [{kind, text, false} | acc])

  defp body([" " <> text | rest], old, new, acc) when old > 0 and new > 0,
    do: body(rest, old - 1, new - 1, [{:context, text, true} | acc])

  defp body(["-" <> text | rest], old, new, acc) when old > 0,
    do: body(rest, old - 1, new, [{:del, text, true} | acc])

  defp body(["+" <> text | rest], old, new, acc) when new > 0,
    do: body(rest, old, new - 1, [{:add, text, true} | acc])

  defp body(_rest, 0, 0, []), do: {:error, :malformed}
  defp body(rest, 0, 0, acc), do: {:ok, Enum.reverse(acc), rest}
  defp body(_rest, _old, _new, _acc), do: {:error, :malformed}
end
