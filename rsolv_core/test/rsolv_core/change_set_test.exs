defmodule RsolvCore.ChangeSetTest do
  use ExUnit.Case, async: true

  doctest RsolvCore.ChangeSet

  alias RsolvCore.ChangeSet
  alias RsolvCore.ChangeSet.Entry

  @vectors __DIR__ |> Path.join("../vectors/change_set.json") |> File.read!() |> JSON.decode!()
  @sha_a String.duplicate("a", 40)
  @sha_b String.duplicate("b", 40)

  defp add(path, overrides \\ %{}) do
    Map.merge(
      %{
        "path" => path,
        "op" => "add",
        "base_mode" => nil,
        "base_blob_sha" => nil,
        "mode" => "100644",
        "new_blob_sha" => @sha_a
      },
      overrides
    )
  end

  defp modify(path, overrides) do
    Map.merge(
      %{
        "path" => path,
        "op" => "modify",
        "base_mode" => "100644",
        "base_blob_sha" => @sha_a,
        "mode" => "100644",
        "new_blob_sha" => @sha_b
      },
      overrides
    )
  end

  defp delete(path) do
    %{
      "path" => path,
      "op" => "delete",
      "base_mode" => "100644",
      "base_blob_sha" => @sha_a,
      "mode" => nil,
      "new_blob_sha" => nil
    }
  end

  describe "blob_sha/1" do
    for %{"base64" => base64, "sha" => sha} <- @vectors["blobs"] do
      test "is #{sha} for the bytes #{inspect(Base.decode64!(base64))}" do
        assert ChangeSet.blob_sha(Base.decode64!(unquote(base64))) == unquote(sha)
      end
    end
  end

  describe "from_json/1" do
    test "accepts an add" do
      assert {:ok, [%Entry{op: :add, base_mode: nil, base_blob_sha: nil, mode: "100644"}]} =
               ChangeSet.from_json([add("a.txt")])
    end

    test "accepts a modify that keeps an executable mode" do
      entry = modify("bin/run", %{"base_mode" => "100755", "mode" => "100755"})

      assert {:ok, [%Entry{op: :modify, base_mode: "100755", mode: "100755"}]} =
               ChangeSet.from_json([entry])
    end

    test "accepts a delete" do
      assert {:ok, [%Entry{op: :delete, mode: nil, new_blob_sha: nil}]} =
               ChangeSet.from_json([delete("gone.txt")])
    end

    test "decodes the vector change set" do
      assert {:ok, [%Entry{op: :modify}, %Entry{op: :delete}, %Entry{op: :add}]} =
               ChangeSet.from_json(@vectors["change_set"])
    end
  end

  describe "from_json/1 when the entries are out of order" do
    test "refuses an unsorted list" do
      assert ChangeSet.from_json([add("b"), add("a")]) == {:error, :unsorted}
    end

    test "refuses a duplicate path" do
      assert ChangeSet.from_json([add("a"), delete("a")]) == {:error, :duplicate_path}
    end
  end

  describe "from_json/1 when a path is invalid" do
    for path <- [
          "/abs",
          "a/../b",
          "./a",
          "a//b",
          "a\\b",
          "a/",
          ".git/config",
          "x/.GIT/hooks",
          "a\0b",
          <<0xFF, ?a>>,
          String.duplicate("a", 4097),
          "",
          "a\nb",
          "a\rb",
          "a\tb",
          "a\x01b",
          "a\x1fb",
          "a\x7fb",
          "a\u0085b",
          "a\u009fb",
          "a\u202ab",
          "\u202eevil.js",
          "a\u2066b",
          "a\u2069b",
          "-rf",
          "src/-b"
        ] do
      test "refuses #{inspect(path, limit: 3, printable_limit: 16)}" do
        assert ChangeSet.from_json([add(unquote(path))]) == {:error, :invalid_path}
      end
    end
  end

  describe "from_json/1 when a path is unusual but valid" do
    for path <- ["a-b", "src/b-", "caf\u00e9.txt", "\u00a0nbsp", "a b"] do
      test "accepts #{inspect(path)}" do
        assert {:ok, [_entry]} = ChangeSet.from_json([add(unquote(path))])
      end
    end
  end

  describe "from_json/1 when one path is a directory of another" do
    test "refuses adding both x and x/y" do
      assert ChangeSet.from_json([add("x"), add("x/y")]) == {:error, :path_conflict}
    end

    test "refuses modifying x while adding x/y/z" do
      assert ChangeSet.from_json([modify("x", %{}), add("x/y/z")]) == {:error, :path_conflict}
    end

    test "refuses the conflict when another path sorts between them" do
      assert ChangeSet.from_json([add("x"), add("x-a"), add("x/y")]) == {:error, :path_conflict}
    end

    test "accepts deleting the file x and adding x/y" do
      assert {:ok, [_delete, _add]} = ChangeSet.from_json([delete("x"), add("x/y")])
    end

    test "accepts adding x and deleting x/y" do
      assert {:ok, [_add, _delete]} = ChangeSet.from_json([add("x"), delete("x/y")])
    end

    test "accepts x and xy, which share only a prefix of the name" do
      assert {:ok, [_x, _xy]} = ChangeSet.from_json([add("x"), add("xy")])
    end
  end

  describe "from_json/1 when an entry is invalid" do
    test "refuses an add with an executable mode" do
      assert ChangeSet.from_json([add("a", %{"mode" => "100755"})]) == {:error, :invalid_entry}
    end

    test "refuses a modify that changes the mode" do
      assert ChangeSet.from_json([modify("a", %{"mode" => "100755"})]) == {:error, :invalid_entry}
    end

    test "refuses a symlink" do
      assert ChangeSet.from_json([add("a", %{"mode" => "120000"})]) == {:error, :invalid_entry}
    end

    test "refuses a gitlink" do
      entry = modify("a", %{"base_mode" => "160000", "mode" => "160000"})
      assert ChangeSet.from_json([entry]) == {:error, :invalid_entry}
    end

    for sha <- [
          String.duplicate("A", 40),
          String.duplicate("a", 39),
          String.duplicate("g", 40),
          nil
        ] do
      test "refuses the blob SHA #{inspect(sha)}" do
        assert ChangeSet.from_json([add("a", %{"new_blob_sha" => unquote(sha)})]) ==
                 {:error, :invalid_entry}
      end
    end
  end

  describe "from_json/1 when the document is malformed" do
    test "refuses a non-list" do
      assert ChangeSet.from_json(%{"path" => "a"}) == {:error, :malformed_change_set}
    end

    test "refuses an unknown op" do
      assert ChangeSet.from_json([add("a", %{"op" => "rename"})]) ==
               {:error, :malformed_change_set}
    end

    test "refuses an extra field" do
      assert ChangeSet.from_json([add("a", %{"x" => 1})]) == {:error, :malformed_change_set}
    end

    test "refuses an improper list" do
      assert ChangeSet.from_json([add("a") | :tail]) == {:error, :malformed_change_set}
    end
  end

  describe "digest/1" do
    setup do
      {:ok, entries} = ChangeSet.from_json(@vectors["change_set"])
      %{entries: entries}
    end

    test "matches the vector digest", %{entries: entries} do
      assert ChangeSet.digest(entries) == @vectors["digest"]
    end

    test "is sha256: and 64 lowercase hex characters", %{entries: entries} do
      assert ChangeSet.digest(entries) =~ ~r/\Asha256:[0-9a-f]{64}\z/
    end

    for field <- [:path, :base_blob_sha, :new_blob_sha, :mode, :base_mode, :op] do
      test "changes when #{field} of an entry changes", %{entries: [first | rest] = entries} do
        changed = [Map.update!(first, unquote(field), &mutate/1) | rest]
        refute ChangeSet.digest(changed) == ChangeSet.digest(entries)
      end
    end
  end

  describe "to_json/1" do
    test "inverts from_json/1 on the vector change set" do
      {:ok, entries} = ChangeSet.from_json(@vectors["change_set"])
      assert ChangeSet.to_json(entries) == @vectors["change_set"]
    end
  end

  defp mutate(:modify), do: :add
  defp mutate("100644"), do: "100755"
  defp mutate(string) when is_binary(string), do: string <> "0"
end
