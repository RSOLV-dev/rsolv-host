defmodule RsolvHost.NoShellTest do
  use ExUnit.Case, async: true

  # RFC-150 acceptance 16: no shell in trusted code. And the protocol is public,
  # so no wire input may become an atom.
  @shell ~r/System\.shell|:os\.cmd|\{:spawn,|"(ba)?sh",\s*\[?\s*"-c"/
  @atoms ~r/(?<!`)(String|List)\.to_(existing_)?atom|:erlang\.(binary|list)_to_(existing_)?atom|binary_to_(existing_)?atom/

  defp offenders(regex) do
    for path <-
          Path.wildcard("../rsolv_host/lib/**/*.ex") ++ Path.wildcard("../rsolv_core/lib/**/*.ex"),
        {line, number} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
        Regex.match?(regex, line),
        do: "#{path}:#{number}"
  end

  describe "trusted code under rsolv_host/lib and rsolv_core/lib" do
    test "reads the trees it guards" do
      assert length(Path.wildcard("../rsolv_host/lib/**/*.ex")) > 3
      assert length(Path.wildcard("../rsolv_core/lib/**/*.ex")) > 3
    end

    test "uses no shell API, no {:spawn, command} port and no sh -c argv" do
      assert offenders(@shell) == []
    end

    test "creates no atom from a string" do
      assert offenders(@atoms) == []
    end
  end

  describe "the guards" do
    test "allow a backticked mention in documentation" do
      refute Regex.match?(@atoms, "through `RsolvCore.Relay.tool/1`, never `String.to_atom/1`.")
    end

    test "catch every forbidden shell form" do
      for line <- [
            ~s|System.shell("id")|,
            ~s|:os.cmd(~c"id")|,
            ~s|Port.open({:spawn, "id"}, [])|,
            ~s|System.cmd("sh", ["-c", "id"])|,
            ~s|System.cmd("bash", ["-c", "id"])|,
            ~s|exec(sbx, ["bash", "-c", "id"])|
          ] do
        assert Regex.match?(@shell, line), line
      end
    end

    test "allow git -c inside the sandbox" do
      refute Regex.match?(@shell, ~s|["git", "-c", "core.autocrlf=false", "diff"]|)
    end

    test "catch every forbidden atom form" do
      for line <- [
            "String.to_atom(name)",
            "String.to_existing_atom(name)",
            "List.to_atom(chars)",
            "List.to_existing_atom(chars)",
            ":erlang.binary_to_atom(name, :utf8)",
            ":erlang.list_to_existing_atom(chars)",
            "binary_to_existing_atom(name)",
            "Enum.map(names, &String.to_atom/1)"
          ] do
        assert Regex.match?(@atoms, line), line
      end
    end
  end
end
