defmodule RsolvCore.CanonicalizePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias RsolvCore.{BaseFacts, Canonicalize, Patch}

  @vectors __DIR__ |> Path.join("../vectors/patch.json") |> File.read!() |> JSON.decode!()

  defp line, do: StreamData.string([?a..?z, ?\s, ?\r, ?é], min_length: 1)

  defp text([], _newline?), do: ""
  defp text(lines, newline?), do: Enum.join(lines, "\n") <> if(newline?, do: "\n", else: "")

  defp side(kind, lines, newline?) do
    last = length(lines) - 1
    lines |> Enum.with_index() |> Enum.map(fn {line, i} -> {kind, line, i < last or newline?} end)
  end

  property "a whole-file hunk turns any base into any new text" do
    check all(
            base <- list_of(line()),
            new <- list_of(line()),
            base_nl <- boolean(),
            new_nl <- boolean()
          ) do
      hunk = %{
        old_start: if(base == [], do: 0, else: 1),
        old_count: length(base),
        lines: side(:del, base, base_nl) ++ side(:add, new, new_nl)
      }

      assert Canonicalize.apply_hunks(text(base, base_nl), [hunk]) == {:ok, text(new, new_nl)}
    end
  end

  property "parse never raises on arbitrary bytes" do
    check all(bytes <- binary(max_length: 4_096)) do
      assert match?({:ok, _}, Patch.parse(bytes)) or match?({:error, _}, Patch.parse(bytes))
    end
  end

  property "parse never raises on a real patch with one byte changed" do
    patches = Enum.map(@vectors["accept"], &Base.decode64!(&1["patch"]))

    check all(
            patch <- member_of(patches),
            at <- integer(0..(byte_size(patch) - 1)),
            byte <- integer(0..255)
          ) do
      <<head::binary-size(^at), _old, tail::binary>> = patch
      mutated = head <> <<byte>> <> tail
      assert match?({:ok, _}, Patch.parse(mutated)) or match?({:error, _}, Patch.parse(mutated))
    end
  end

  property "change_set never raises on a real patch with one byte changed" do
    vectors =
      for vector <- @vectors["accept"] do
        patch = Base.decode64!(vector["patch"])
        {:ok, diffs} = Patch.parse(patch)

        {:ok, facts} =
          BaseFacts.decode(vector["base_facts"], vector["base_sha"], Patch.touched_paths(diffs))

        {patch, facts}
      end

    check all(
            {patch, facts} <- member_of(vectors),
            at <- integer(0..(byte_size(patch) - 1)),
            byte <- integer(0..255)
          ) do
      <<head::binary-size(^at), _old, tail::binary>> = patch

      with {:ok, diffs} <- Patch.parse(head <> <<byte>> <> tail) do
        assert match?({:ok, _entries, _images}, Canonicalize.change_set(diffs, facts)) or
                 match?({:error, {_reason, _path}}, Canonicalize.change_set(diffs, facts))
      end
    end
  end
end
