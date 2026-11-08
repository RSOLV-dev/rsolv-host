defmodule RsolvCore.BaseFactsTest do
  use ExUnit.Case, async: true

  doctest RsolvCore.BaseFacts

  alias RsolvCore.{BaseFacts, ChangeSet}

  @base String.duplicate("b", 40)

  defp blob(content, mode \\ "100644"),
    do: %{
      "type" => "blob",
      "mode" => mode,
      "sha" => ChangeSet.blob_sha(content),
      "content" => Base.encode64(content)
    }

  defp json(paths, attributes \\ %{}),
    do: %{"base_sha" => @base, "paths" => paths, "attributes" => attributes}

  describe "required_paths/1" do
    test "adds every ancestor directory, sorted and unique" do
      assert BaseFacts.required_paths(["a/b/c.js", "a/d.js"]) ==
               {:ok, ["a", "a/b", "a/b/c.js", "a/d.js"]}
    end

    test "refuses a path deeper than 128 segments, quickly, at the patch caps' size" do
      deep = for n <- 1..1_000, do: "p#{n}/" <> :binary.copy("a/", 2_040) <> "x.js"

      {micros, result} = :timer.tc(fn -> BaseFacts.required_paths(deep) end)

      assert result == {:error, {:path_too_deep, hd(deep)}}
      assert micros < 1_000_000
    end

    test "accepts a path of exactly 128 segments" do
      path = :binary.copy("a/", 127) <> "x"
      assert {:ok, paths} = BaseFacts.required_paths([path])
      assert length(paths) == 128
    end

    test "refuses more unique paths than base facts may hold" do
      paths = for n <- 1..100, do: "p#{n}/" <> :binary.copy("a/", 100) <> "x.js"
      assert BaseFacts.required_paths(paths) == {:error, :too_many_paths}
    end
  end

  describe "decode/3" do
    test "decodes blobs, trees, missing paths and attributes" do
      facts =
        json(
          %{
            "src" => %{"type" => "tree"},
            "src/a.js" => blob("x\n"),
            "src/new.js" => %{"type" => "missing"}
          },
          %{"" => Base.encode64("*.png filter=lfs\n")}
        )

      assert {:ok,
              %BaseFacts{
                paths: %{"src/a.js" => %{type: :blob, mode: "100644", content: "x\n"}},
                attributes: %{"" => "*.png filter=lfs\n"}
              }} =
               BaseFacts.decode(facts, @base, ["src/a.js", "src/new.js"])
    end

    test "round-trips through to_json/1" do
      facts = json(%{"a.js" => blob("x\n")})
      {:ok, decoded} = BaseFacts.decode(facts, @base, ["a.js"])
      assert BaseFacts.to_json(decoded) == facts
    end
  end

  describe "decode/3 when the facts are refused" do
    test "refuses content that doesn't hash to its sha" do
      lying = put_in(blob("x\n"), ["content"], Base.encode64("y\n"))

      assert BaseFacts.decode(json(%{"a.js" => lying}), @base, ["a.js"]) ==
               {:error, :invalid_base_facts}
    end

    test "refuses another base" do
      facts = %{json(%{"a.js" => blob("x\n")}) | "base_sha" => String.duplicate("c", 40)}
      assert BaseFacts.decode(facts, @base, ["a.js"]) == {:error, :invalid_base_facts}
    end

    test "refuses facts that miss an ancestor" do
      assert BaseFacts.decode(json(%{"src/a.js" => blob("x\n")}), @base, ["src/a.js"]) ==
               {:error, :invalid_base_facts}
    end

    test "refuses facts for a path nobody asked about" do
      facts = json(%{"a.js" => blob("x\n"), "b.js" => blob("y\n")})
      assert BaseFacts.decode(facts, @base, ["a.js"]) == {:error, :invalid_base_facts}
    end

    test "refuses attributes for a directory that isn't a tree on the chain" do
      facts = json(%{"a.js" => blob("x\n")}, %{"other" => Base.encode64("* filter=x\n")})
      assert BaseFacts.decode(facts, @base, ["a.js"]) == {:error, :invalid_base_facts}
    end

    test "refuses an unknown member" do
      facts = json(%{"a.js" => Map.put(blob("x\n"), "extra", 1)})
      assert BaseFacts.decode(facts, @base, ["a.js"]) == {:error, :invalid_base_facts}
    end

    test "refuses a path that exists beneath an ancestor that isn't a tree" do
      facts = json(%{"src" => %{"type" => "missing"}, "src/a.js" => blob("x\n")})
      assert BaseFacts.decode(facts, @base, ["src/a.js"]) == {:error, :invalid_base_facts}
    end

    test "refuses requested paths that aren't a list of strings" do
      assert BaseFacts.decode(json(%{}), @base, :all) == {:error, :invalid_base_facts}
      assert BaseFacts.decode(json(%{}), @base, [1]) == {:error, :invalid_base_facts}
    end
  end
end
