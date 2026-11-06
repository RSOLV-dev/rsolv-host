defmodule RsolvCore.IsolationTest do
  use ExUnit.Case, async: true

  @tooling [:stream_data, :credo]

  describe "the core's dependencies" do
    test "are only test and lint tooling, never a runtime, path or git dependency" do
      deps = Mix.Project.config()[:deps]

      assert Enum.map(deps, &elem(&1, 0)) -- @tooling == []

      assert Enum.all?(deps, fn {_name, _req, opts} ->
               opts[:only] && !opts[:path] && !opts[:git]
             end)
    end
  end

  describe "the core's source" do
    test "names no platform module" do
      offenders =
        for path <- Path.wildcard("lib/**/*.ex"),
            {line, number} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
            Regex.match?(~r/\bRsolv(Web)?\./, line),
            do: "#{path}:#{number}"

      assert offenders == []
    end
  end
end
