defmodule RsolvCore.DocsTest do
  use ExUnit.Case, async: true

  setup_all do
    {:ok, modules} = :application.get_key(:rsolv_core, :modules)
    %{docs: Enum.map(modules, &{&1, Code.fetch_docs(&1)})}
  end

  describe "every module" do
    test "has loadable docs", %{docs: docs} do
      assert for({module, {:error, reason}} <- docs, do: {module, reason}) == []
    end

    test "has a @moduledoc", %{docs: docs} do
      assert for({module, {:docs_v1, _, _, _, :none, _, _}} <- docs, do: module) == []
    end
  end

  describe "every public function" do
    test "has a @doc (an explicit @doc false counts)", %{docs: docs} do
      undocumented =
        for {module, {:docs_v1, _, _, _, moduledoc, _, entries}} <- docs,
            moduledoc != :hidden,
            {{kind, name, arity}, _, _, :none, _} <- entries,
            kind in [:function, :macro],
            do: {module, name, arity}

      assert undocumented == []
    end
  end
end
