# Generates test/vectors/gitattributes.json: what `git check-attr filter` says for
# paths under synthetic .gitattributes files, so RsolvCore.GitAttributes is checked
# against git itself, never against its own reading of the format.
#   cd rsolv_core && elixir test/vectors/gen_gitattributes_vectors.exs [output path]
# Nothing is committed, so every run writes the same vectors;
# RsolvCore.GitAttributesVectorsTest regenerates them and compares.
defmodule GenGitAttributesVectors do
  # {name, %{directory ("" for the root) => .gitattributes bytes}, [path]}
  def cases do
    chain = Enum.map_join(1..3_000, &"[attr]m#{&1} m#{&1 - 1}\n") <> "[attr]m0 filter=lfs\n"

    [
      # Bracket expressions
      {"posix_class", %{"" => "[[:digit:]] filter=lfs\n"}, ~w(5 a 55)},
      {"bracket_negated_close_first", %{"" => "[!]] filter=lfs\n"}, ["a", "]"]},
      {"bracket_caret_negation", %{"" => "x[^ab] filter=lfs\n"}, ~w(xa xc x)},
      {"bracket_close_first", %{"" => "[]] filter=lfs\n"}, ["]", "a"]},
      {"bracket_range", %{"" => "f[a-c].txt filter=lfs\n"}, ~w(fa.txt fb.txt fd.txt f-.txt)},
      {"bracket_negated_range", %{"" => "f[!a-c].txt filter=lfs\n"}, ~w(fa.txt fd.txt)},
      {"bracket_range_to_open_bracket", %{"" => "[a-[:digit:]] filter=lfs\n"},
       ["a]", "5", "a", "[]"]},
      {"bracket_trailing_dash", %{"" => "[a-]] filter=lfs\n"}, ["a]", "-]", "a"]},
      {"bracket_escaped_close", %{"" => "[\\]x] filter=lfs\n"}, ["x", "]", "y"]},
      {"bracket_unterminated", %{"" => "[abc filter=lfs\n"}, ["[abc", "a", "b"]},
      {"bracket_unknown_class", %{"" => "[[:nope:]] filter=lfs\n"}, ["a", ":"]},
      {"bracket_colon_not_class", %{"" => "[[:a] filter=lfs\n"}, ["a", "[", ":", "]"]},
      {"bracket_in_directory", %{"" => "d[0-9]/*.bin filter=lfs\n"}, ~w(d1/a.bin dx/a.bin)},
      {"bracket_slash", %{"" => "a[/]b filter=lfs\n"}, ~w(a/b axb)},
      # Stars and question marks
      {"star_basename", %{"" => "*.bin filter=lfs\n"},
       ~w(a.bin d/a.bin d/e/a.bin a.bin.txt .bin abin)},
      {"globstar_leading", %{"" => "**/x.bin filter=lfs\n"}, ~w(x.bin d/x.bin d/e/x.bin d/y.bin)},
      {"globstar_middle", %{"" => "a/**/b.bin filter=lfs\n"},
       ~w(a/b.bin a/x/b.bin a/x/y/b.bin ab.bin c/a/b.bin)},
      {"globstar_trailing", %{"" => "a/** filter=lfs\n"}, ~w(a/x a/x/y b/x a)},
      {"globstar_not_at_boundary", %{"" => "a**b filter=lfs\n"}, ~w(ab axb d/axb)},
      {"globstar_in_path_not_at_boundary", %{"" => "d/a**b filter=lfs\n"}, ~w(d/ab d/axb d/a/b)},
      {"triple_star", %{"" => "***.bin filter=lfs\n"}, ~w(a.bin d/a.bin)},
      {"triple_star_globstar_leading", %{"" => "***/x.png filter=lfs\n"},
       ~w(x.png d/x.png d/y.png)},
      {"triple_star_globstar_middle", %{"" => "a/***/b filter=lfs\n"}, ~w(a/b a/x/b a/x/y/b ab)},
      {"star_run_globstars", %{"" => "*****/** filter=lfs\n"}, ~w(foo1 d/foo1)},
      {"escaped_star_before_globstar", %{"" => "\\***/x filter=lfs\n"}, ~w(*/x */d/x x d/x)},
      {"escaped_star_between_stars", %{"" => "*\\** filter=lfs\n"}, ~w(a*b * ab d/a*b a/*/b)},
      {"question_mark", %{"" => "?.c filter=lfs\n"}, ~w(a.c ab.c d/a.c .c)},
      {"question_mark_in_path", %{"" => "d?e/f filter=lfs\n"}, ~w(dxe/f d/e/f)},
      # Escapes
      {"escaped_star", %{"" => "\\*.bin filter=lfs\n"}, ~w(*.bin a.bin)},
      {"escaped_bracket", %{"" => "\\[x] filter=lfs\n"}, ~w([x] x)},
      {"escaped_question_mark", %{"" => "a\\?c filter=lfs\n"}, ~w(a?c abc)},
      {"trailing_backslash", %{"" => "x\\ filter=lfs\n"}, ["x\\", "x"]},
      # With and without a slash
      {"pattern_with_slash", %{"" => "d/*.bin filter=lfs\n"}, ~w(d/a.bin e/d/a.bin d/e/a.bin)},
      {"pattern_leading_slash", %{"" => "/top.bin filter=lfs\n"}, ~w(top.bin d/top.bin)},
      {"pattern_literal_path", %{"" => "d/x.bin filter=lfs\n"}, ~w(d/x.bin e/d/x.bin)},
      {"pattern_literal_basename", %{"" => "x.bin filter=lfs\n"}, ~w(x.bin d/x.bin xx.bin)},
      {"pattern_trailing_slash", %{"" => "d/ filter=lfs\n"}, ~w(d/x d/e/x d)},
      {"pattern_negative", %{"" => "!*.bin filter=lfs\n"}, ~w(a.bin !a.bin)},
      # Subdirectory files
      {"subdirectory_basename", %{"sub" => "*.bin filter=lfs\n"},
       ~w(sub/a.bin sub/x/a.bin a.bin other/a.bin)},
      {"subdirectory_anchored", %{"sub" => "/a.bin filter=lfs\n"},
       ~w(sub/a.bin sub/x/a.bin a.bin)},
      {"subdirectory_with_slash", %{"sub" => "x/*.bin filter=lfs\n"},
       ~w(sub/x/a.bin sub/y/x/a.bin x/a.bin)},
      {"nested_subdirectories", %{"a" => "*.c filter=one\n", "a/b" => "*.h filter=two\n"},
       ~w(a/b/x.c a/b/x.h a/x.h x.c)},
      {"subdirectory_unsets_root", %{"" => "*.bin filter=lfs\n", "sub" => "*.bin -filter\n"},
       ~w(sub/a.bin a.bin)},
      {"subdirectory_sets_over_root_unset",
       %{"" => "*.bin -filter\n", "sub" => "*.bin filter=x\n"}, ~w(sub/a.bin a.bin)},
      # Negation, unset and unspecified
      {"later_unset", %{"" => "*.bin filter=lfs\na.bin -filter\n"}, ~w(a.bin b.bin)},
      {"later_unspecified", %{"" => "*.bin filter=lfs\na.bin !filter\n"}, ~w(a.bin b.bin)},
      {"later_set_wins", %{"" => "*.bin -filter\na.bin filter=lfs\n"}, ~w(a.bin b.bin)},
      {"only_unset", %{"" => "*.bin -filter\n"}, ~w(a.bin)},
      {"only_unspecified", %{"" => "*.bin !filter\n"}, ~w(a.bin)},
      {"bare_filter_is_set", %{"" => "*.bin filter\n"}, ~w(a.bin a.txt)},
      {"empty_driver", %{"" => "*.bin filter=\n"}, ~w(a.bin)},
      {"unset_with_value", %{"" => "*.bin -filter=lfs\n"}, ~w(a.bin)},
      {"other_attributes_only", %{"" => "*.bin diff=lfs merge=lfs -text filterx=lfs\n"},
       ~w(a.bin)},
      {"same_line_unset_after_set", %{"" => "*.bin filter=lfs -filter\n"}, ~w(a.bin)},
      {"same_line_set_after_unset", %{"" => "*.bin -filter filter=lfs\n"}, ~w(a.bin)},
      {"invalid_attribute_drops_line", %{"" => "*.bin filter=lfs b@d\n"}, ~w(a.bin)},
      # Macros
      {"macro", %{"" => "[attr]lfs filter=lfs diff=lfs\n*.psd lfs\n"}, ~w(a.psd a.png)},
      {"macro_defined_after_use", %{"" => "*.psd lfs\n[attr]lfs filter=lfs\n"}, ~w(a.psd)},
      {"macro_chain", %{"" => "* m3\n[attr]m3 m2\n[attr]m2 m1\n[attr]m1 m0\n[attr]m0 filter=x\n"},
       ~w(a)},
      {"macro_chain_3000", %{"" => chain <> "* m3000\n"}, ~w(a.txt)},
      {"macro_cycle", %{"" => "[attr]a b\n[attr]b a\n* a\n"}, ~w(x)},
      {"macro_cycle_with_filter", %{"" => "[attr]a b filter=x\n[attr]b a\n* b\n"}, ~w(x)},
      {"macro_unset", %{"" => "[attr]m filter=lfs\n* -m\n"}, ~w(a)},
      {"macro_unspecified", %{"" => "[attr]m filter=lfs\n* !m\n"}, ~w(a)},
      {"macro_with_value", %{"" => "[attr]m filter=lfs\n* m=x\n"}, ~w(a)},
      {"macro_redefined", %{"" => "[attr]m filter=lfs\n[attr]m text\n* m\n"}, ~w(a)},
      {"macro_redefined_to_filter", %{"" => "[attr]m text\n[attr]m filter=lfs\n* m\n"}, ~w(a)},
      {"macro_quoted_name", %{"" => ~s("[attr]m" filter=lfs\n* m\n)}, ~w(a)},
      {"attr_alone_is_a_pattern", %{"" => "[attr] filter=lfs\n"}, ~w(a t r x)},
      {"macro_in_subdirectory_ignored", %{"sub" => "[attr]m filter=lfs\n* m\n"}, ~w(sub/a)},
      {"root_macro_used_in_subdirectory", %{"" => "[attr]m filter=lfs\n", "sub" => "*.bin m\n"},
       ~w(sub/a.bin a.bin)},
      {"builtin_binary_macro", %{"" => "*.bin binary\n"}, ~w(a.bin)},
      {"builtin_binary_redefined", %{"" => "[attr]binary filter=lfs\n*.bin binary\n"}, ~w(a.bin)},
      # Case
      {"case_sensitive_pattern", %{"" => "*.BIN filter=lfs\n"}, ~w(a.bin a.BIN)},
      {"case_sensitive_directory", %{"" => "D/*.bin filter=lfs\n"}, ~w(d/a.bin D/a.bin)},
      # Whitespace
      {"trailing_spaces", %{"" => "*.bin filter=lfs   \n*.txt \t\n"}, ~w(a.bin a.txt)},
      {"leading_whitespace", %{"" => "  \t*.bin filter=lfs\n"}, ~w(a.bin)},
      {"tab_separated", %{"" => "*.bin\tfilter=lfs\n"}, ~w(a.bin)},
      {"crlf", %{"" => "*.bin filter=lfs\r\n*.txt text\r\n"}, ~w(a.bin a.txt)},
      {"lone_cr_is_a_separator", %{"" => "*.bin\rfilter=lfs\n"}, ~w(a.bin)},
      {"no_final_newline", %{"" => "*.bin filter=lfs"}, ~w(a.bin)},
      {"byte_order_mark", %{"" => "﻿*.bin filter=lfs\n"}, ~w(a.bin)},
      {"vertical_tab_is_not_a_separator", %{"" => "*.bin\vfilter=lfs\n"}, ~w(a.bin)},
      {"comments", %{"" => "# *.bin filter=lfs\n  # x\n*.c filter=c # trailing\n"},
       ~w(a.bin a.c)},
      {"hash_inside_pattern", %{"" => "a#b filter=lfs\n"}, ~w(a#b a)},
      {"nul_line", %{"" => "*.c text\n\0\n*.bin filter=lfs\n"}, ~w(a.bin)},
      # Quoted patterns
      {"quoted_with_space", %{"" => ~s("a b.bin" filter=lfs\n)}, ["a b.bin", "a", "c.bin"]},
      {"quoted_glued_to_attributes", %{"" => ~s("a"filter=lfs\n)}, ~w(a b)},
      {"quoted_octal", %{"" => ~s("\\141.bin" filter=lfs\n)}, ~w(a.bin b.bin)},
      {"quoted_glob", %{"" => ~s("*.bin" filter=lfs\n)}, ~w(x.bin x.txt)},
      {"quoted_unterminated", %{"" => ~s("abc filter=lfs\n)}, [~s("abc), "abc"]},
      {"quoted_bad_escape", %{"" => ~s("a\\qb" filter=lfs\n)}, [~s("a\\qb"), "aqb"]},
      {"quoted_nul_truncates", %{"" => ~s("*\\000.png" filter=lfs\n)}, ~w(a.txt a.png)},
      {"quoted_nul_truncates_in_subdirectory", %{"sub" => ~s("x\\000" filter=lfs\n)},
       ~w(sub/x sub/xy x)}
    ]
  end

  @git_env [{"GIT_CONFIG_NOSYSTEM", "1"}, {"GIT_CONFIG_GLOBAL", "/dev/null"}]

  def run(out) do
    vectors = isolated(fn -> Enum.map(cases(), &vector/1) end)
    File.write!(out, JSON.encode!(%{"cases" => vectors}) <> "\n")

    IO.puts(
      "wrote #{length(vectors)} cases, #{vectors |> Enum.map(&map_size(&1["filter"])) |> Enum.sum()} paths"
    )
  end

  # git reads only what the vectors set: no system or user config or attributes,
  # and nothing a caller's GIT_* environment would change.
  defp isolated(fun) do
    home = Path.join(System.tmp_dir!(), "rsolv-vec-home-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)

    for {name, _value} <- System.get_env(),
        String.starts_with?(name, "GIT_"),
        do: System.delete_env(name)

    System.put_env(%{
      "HOME" => home,
      "XDG_CONFIG_HOME" => home,
      "GIT_ATTR_NOSYSTEM" => "1",
      "GIT_CONFIG_NOSYSTEM" => "1"
    })

    try do
      fun.()
    after
      File.rm_rf!(home)
    end
  end

  defp vector({name, attributes, paths}) do
    dir = Path.join(System.tmp_dir!(), "rsolv-attr-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      {_out, 0} = System.cmd("git", ["init", "-q", "--template=", dir], env: @git_env)

      for {sub, text} <- attributes do
        File.mkdir_p!(Path.join(dir, sub))
        File.write!(Path.join([dir, sub, ".gitattributes"]), text)
      end

      {out, 0} =
        System.cmd("git", ["check-attr", "-z", "filter", "--" | paths],
          cd: dir,
          env: @git_env,
          stderr_to_stdout: false
        )

      %{
        "name" => name,
        "attributes" => Map.new(attributes, fn {sub, text} -> {sub, Base.encode64(text)} end),
        "filter" => out |> String.split(<<0>>) |> parse(%{})
      }
    after
      File.rm_rf!(dir)
    end
  end

  defp parse([path, "filter", value | rest], acc), do: parse(rest, Map.put(acc, path, value))
  defp parse([""], acc), do: acc
end

case System.argv() do
  [] -> GenGitAttributesVectors.run(Path.join(__DIR__, "gitattributes.json"))
  [out] -> GenGitAttributesVectors.run(out)
end
