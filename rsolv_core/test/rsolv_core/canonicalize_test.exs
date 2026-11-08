defmodule RsolvCore.CanonicalizeTest do
  use ExUnit.Case, async: true

  alias RsolvCore.{BaseFacts, Canonicalize, ChangeSet, Patch}

  @vectors __DIR__ |> Path.join("../vectors/patch.json") |> File.read!() |> JSON.decode!()

  describe "change_set/2 against the git-generated vectors" do
    for vector <- @vectors["accept"] do
      @vector vector
      test "accepts #{vector["name"]}" do
        %{"patch" => patch, "base_sha" => base, "base_facts" => facts_json} = @vector
        {:ok, diffs} = patch |> Base.decode64!() |> Patch.parse()
        {:ok, facts} = BaseFacts.decode(facts_json, base, Patch.touched_paths(diffs))

        assert {:ok, entries, images} = Canonicalize.change_set(diffs, facts)
        assert ChangeSet.to_json(entries) == @vector["change_set"]
        assert ChangeSet.digest(entries) == @vector["digest"]

        assert Map.new(images, fn {path, bytes} -> {path, Base.encode64(bytes)} end) ==
                 @vector["post_images"]
      end
    end

    for vector <- @vectors["reject"] do
      @vector vector
      test "rejects #{vector["name"]} at #{vector["stage"]}" do
        assert Canonicalize.run(@vector) == {@vector["stage"], @vector["reason"], @vector["path"]}
      end
    end
  end

  describe "change_set/2 when the facts don't cover a path" do
    test "refuses it" do
      facts = %BaseFacts{base_sha: String.duplicate("b", 40), paths: %{}, attributes: %{}}
      diff = %Patch.FileDiff{path: "src/a.js", op: :add, hunks: []}
      assert Canonicalize.change_set([diff], facts) == {:error, {:missing_base_fact, "src/a.js"}}
    end
  end

  describe "apply_hunks/2" do
    test "refuses overlapping hunks" do
      hunk = %{old_start: 1, old_count: 1, lines: [{:del, "a", true}, {:add, "b", true}]}
      assert Canonicalize.apply_hunks("a\n", [hunk, hunk]) == {:error, :hunk_mismatch}
    end

    test "refuses a no-newline line that isn't last" do
      hunk = %{old_start: 1, old_count: 1, lines: [{:del, "a", true}, {:add, "b", false}]}
      assert Canonicalize.apply_hunks("a\nz\n", [hunk]) == {:error, :hunk_mismatch}
    end
  end
end
