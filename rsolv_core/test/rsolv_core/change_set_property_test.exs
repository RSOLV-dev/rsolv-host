defmodule RsolvCore.ChangeSetPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias RsolvCore.ChangeSet
  alias RsolvCore.ChangeSet.Entry

  @fields [:path, :op, :base_mode, :base_blob_sha, :mode, :new_blob_sha]

  defp segment do
    [?a..?z, ?0..?9, [?., ?_, ?-]]
    |> Enum.concat()
    |> string(min_length: 1, max_length: 12)
    |> filter(&(&1 not in [".", "..", ".git"]))
  end

  defp path, do: segment() |> list_of(min_length: 1, max_length: 4) |> map(&Enum.join(&1, "/"))

  defp sha, do: string(Enum.concat(?0..?9, ?a..?f), length: 40)

  defp entry(path) do
    one_of([
      map(
        sha(),
        &%Entry{
          path: path,
          op: :add,
          base_mode: nil,
          base_blob_sha: nil,
          mode: "100644",
          new_blob_sha: &1
        }
      ),
      bind(member_of(["100644", "100755"]), fn mode ->
        map(
          {sha(), sha()},
          fn {base, new} ->
            %Entry{
              path: path,
              op: :modify,
              base_mode: mode,
              base_blob_sha: base,
              mode: mode,
              new_blob_sha: new
            }
          end
        )
      end),
      map(
        {member_of(["100644", "100755"]), sha()},
        fn {mode, base} ->
          %Entry{
            path: path,
            op: :delete,
            base_mode: mode,
            base_blob_sha: base,
            mode: nil,
            new_blob_sha: nil
          }
        end
      )
    ])
  end

  defp change_set(min_length \\ 0) do
    path()
    |> uniq_list_of(min_length: min_length, max_length: 8)
    |> map(&Enum.sort/1)
    |> bind(fn paths -> paths |> Enum.map(&entry/1) |> fixed_list() end)
  end

  defp json_leaf,
    do: one_of([constant(nil), boolean(), integer(), string(:printable), list_of(integer())])

  defp mutate(:op, :add), do: :delete
  defp mutate(:op, _op), do: :add
  defp mutate(_field, nil), do: "x"
  defp mutate(_field, string), do: string <> "0"

  describe "from_json/1 on a valid change set" do
    property "inverts to_json/1" do
      check all(entries <- change_set()) do
        assert entries |> ChangeSet.to_json() |> ChangeSet.from_json() == {:ok, entries}
      end
    end

    property "refuses two swapped neighbours as unsorted" do
      check all([first, second | rest] <- change_set(2)) do
        assert [second, first | rest] |> ChangeSet.to_json() |> ChangeSet.from_json() ==
                 {:error, :unsorted}
      end
    end

    property "refuses a duplicated entry" do
      check all([first | rest] <- change_set(1)) do
        assert [first, first | rest] |> ChangeSet.to_json() |> ChangeSet.from_json() ==
                 {:error, :duplicate_path}
      end
    end
  end

  describe "digest/1" do
    property "is stable across calls" do
      check all(entries <- change_set()) do
        assert ChangeSet.digest(entries) == ChangeSet.digest(entries)
      end
    end

    property "changes when any one field of any one entry changes" do
      check all(
              entries <- change_set(1),
              index <- integer(0..(length(entries) - 1)),
              field <- member_of(@fields)
            ) do
        changed =
          List.update_at(entries, index, &Map.update!(&1, field, fn v -> mutate(field, v) end))

        refute ChangeSet.digest(changed) == ChangeSet.digest(entries)
      end
    end
  end

  describe "from_json/1 on arbitrary input" do
    property "returns a result for any term, and never raises" do
      check all(value <- term()) do
        assert match?({:ok, _}, ChangeSet.from_json(value)) or
                 match?({:error, _}, ChangeSet.from_json(value))
      end
    end

    property "returns a result when any field of a valid document is replaced, and never raises" do
      check all(
              entries <- change_set(1),
              index <- integer(0..(length(entries) - 1)),
              key <- member_of(~w(path op base_mode base_blob_sha mode new_blob_sha extra)),
              value <- json_leaf()
            ) do
        document =
          entries
          |> ChangeSet.to_json()
          |> List.update_at(index, &Map.put(&1, key, value))
          |> JSON.encode!()
          |> JSON.decode!()

        assert match?({:ok, _}, ChangeSet.from_json(document)) or
                 match?({:error, _}, ChangeSet.from_json(document))
      end
    end
  end

  describe "valid_path?/1" do
    property "never raises, and refuses NUL, backslash and absolute paths" do
      check all(bytes <- binary()) do
        result = ChangeSet.valid_path?(bytes)

        if String.contains?(bytes, [<<0>>, "\\"]) or String.starts_with?(bytes, "/") do
          refute result
        else
          assert is_boolean(result)
        end
      end
    end

    property "refuses a .git segment in any case, anywhere in the path" do
      check all(
              prefix <- list_of(segment(), max_length: 3),
              suffix <- list_of(segment(), max_length: 3),
              git <- map({boolean(), boolean(), boolean()}, &git_segment/1)
            ) do
        refute ChangeSet.valid_path?(Enum.join(prefix ++ [git | suffix], "/"))
      end
    end

    property "accepts every generated path" do
      check all(path <- path()) do
        assert ChangeSet.valid_path?(path)
      end
    end
  end

  describe "blob_sha/1" do
    @describetag :git
    @describetag :tmp_dir

    property "agrees with git hash-object", %{tmp_dir: tmp_dir} do
      check all(bytes <- binary(), max_runs: 50) do
        file = Path.join(tmp_dir, "blob")
        File.write!(file, bytes)
        {sha, 0} = System.cmd("git", ["hash-object", "--no-filters", file])
        assert ChangeSet.blob_sha(bytes) == String.trim(sha)
      end
    end
  end

  defp git_segment({g, i, t}), do: "." <> up("g", g) <> up("i", i) <> up("t", t)
  defp up(letter, true), do: String.upcase(letter)
  defp up(letter, false), do: letter
end
