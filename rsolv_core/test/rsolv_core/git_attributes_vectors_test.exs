defmodule RsolvCore.GitAttributesVectorsTest do
  use ExUnit.Case, async: true

  alias RsolvCore.GitAttributes

  @committed Path.expand("../vectors/gitattributes.json", __DIR__)
  @generator Path.expand("../vectors/gen_gitattributes_vectors.exs", __DIR__)
  @not_filtered ["unset", "unspecified"]

  # Where we say filtered and git doesn't, each for a reason the moduledoc gives.
  @over_approximations [
    # A bracket expression is any one character but `/`.
    {"posix_class", "a"},
    {"bracket_negated_close_first", "]"},
    {"bracket_caret_negation", "xa"},
    {"bracket_close_first", "a"},
    {"bracket_range", "f-.txt"},
    {"bracket_range", "fd.txt"},
    {"bracket_negated_range", "fa.txt"},
    {"bracket_range_to_open_bracket", "[]"},
    {"bracket_escaped_close", "y"},
    {"bracket_unknown_class", ":"},
    {"bracket_unknown_class", "a"},
    {"bracket_colon_not_class", "]"},
    {"bracket_in_directory", "dx/a.bin"},
    {"bracket_slash", "axb"},
    {"attr_alone_is_a_pattern", "x"},
    # `**` away from a `/` is any characters, `/` included.
    {"globstar_in_path_not_at_boundary", "d/a/b"},
    {"escaped_star_before_globstar", "*/d/x"},
    # A trailing `\` is a literal backslash.
    {"trailing_backslash", "x\\"},
    # A later unset doesn't clear a set.
    {"subdirectory_unsets_root", "sub/a.bin"},
    {"later_unset", "a.bin"},
    {"later_unspecified", "a.bin"},
    {"same_line_unset_after_set", "a.bin"},
    # A line git drops for an invalid attribute name still counts.
    {"invalid_attribute_drops_line", "a.bin"},
    {"comments", "a.c"},
    # Every definition of a macro counts, from any file.
    {"macro_redefined", "a"},
    {"macro_in_subdirectory_ignored", "sub/a"}
  ]

  @moduletag :tmp_dir

  setup_all do
    %{"cases" => cases} = @committed |> File.read!() |> JSON.decode!()

    results =
      for %{"name" => name, "attributes" => encoded, "filter" => filter} <- cases,
          attributes =
            GitAttributes.compile(Map.new(encoded, fn {d, t} -> {d, Base.decode64!(t)} end)),
          {path, value} <- filter,
          do: {name, path, value, GitAttributes.filtered?(path, attributes)}

    %{results: results}
  end

  describe "test/vectors/gitattributes.json" do
    test "filters every path git puts under a filter", %{results: results} do
      assert for(
               {name, path, value, false} <- results,
               value not in @not_filtered,
               do: {name, path}
             ) ==
               []
    end

    test "says filtered where git doesn't only where it's known to over-approximate",
         %{results: results} do
      over = for {name, path, value, true} <- results, value in @not_filtered, do: {name, path}
      assert Enum.sort(over) == Enum.sort(@over_approximations)
    end

    test "is exactly what the generator writes from real git", %{tmp_dir: tmp_dir} do
      out = Path.join(tmp_dir, "gitattributes.json")
      hostile = Path.join(tmp_dir, "attributes")
      File.write!(hostile, "* filter=hostile\n")

      assert {_output, 0} =
               System.cmd("elixir", [@generator, out],
                 env: hostile_git_env("core.attributesFile", hostile),
                 stderr_to_stdout: true
               )

      assert out |> File.read!() |> JSON.decode!() == @committed |> File.read!() |> JSON.decode!()
    end
  end

  # A caller's git environment, which the generator must not let reach git.
  defp hostile_git_env(key, value),
    do: [{"GIT_CONFIG_COUNT", "1"}, {"GIT_CONFIG_KEY_0", key}, {"GIT_CONFIG_VALUE_0", value}]
end
