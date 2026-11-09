defmodule RsolvHost.PostImagesTest do
  use ExUnit.Case, async: true

  alias RsolvCore.ChangeSet
  alias RsolvCore.ChangeSet.Entry
  alias RsolvHost.PostImages

  doctest PostImages

  defp add(path, bytes),
    do: %Entry{
      path: path,
      op: :add,
      base_mode: nil,
      base_blob_sha: nil,
      mode: "100644",
      new_blob_sha: ChangeSet.blob_sha(bytes)
    }

  defp delete(path),
    do: %Entry{
      path: path,
      op: :delete,
      base_mode: "100644",
      base_blob_sha: "x",
      mode: nil,
      new_blob_sha: nil
    }

  describe "checked/2" do
    test "decodes exactly the adds and modifies, each matching its blob SHA" do
      assert PostImages.checked(%{"a.js" => Base.encode64("x")}, [
               add("a.js", "x"),
               delete("b.js")
             ]) ==
               {:ok, %{"a.js" => "x"}}
    end

    test "refuses an image that doesn't hash to its new blob" do
      assert PostImages.checked(%{"a.js" => Base.encode64("y")}, [add("a.js", "x")]) ==
               {:error, :digest_mismatch}
    end

    test "refuses a missing, an extra or a deleted file's image" do
      assert PostImages.checked(%{}, [add("a.js", "x")]) == {:error, :digest_mismatch}

      assert PostImages.checked(%{"a.js" => Base.encode64("x"), "b.js" => ""}, [add("a.js", "x")]) ==
               {:error, :digest_mismatch}

      assert PostImages.checked(%{"b.js" => ""}, [delete("b.js")]) == {:error, :digest_mismatch}
    end

    test "refuses what isn't a map of base64 strings" do
      assert PostImages.checked(["a.js"], [add("a.js", "x")]) == {:error, :digest_mismatch}
      assert PostImages.checked(%{"a.js" => 1}, [add("a.js", "x")]) == {:error, :digest_mismatch}

      assert PostImages.checked(%{"a.js" => "!!"}, [add("a.js", "x")]) ==
               {:error, :digest_mismatch}
    end
  end
end
