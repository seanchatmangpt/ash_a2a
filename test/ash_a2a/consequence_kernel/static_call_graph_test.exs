defmodule AshA2A.ConsequenceKernel.StaticCallGraphTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.StaticCallGraph
  test "50 portable source vectors classify through complete mediation" do
    root = Path.expand("../../../../priv/sa2a/c1/static_call_graph_vectors", __DIR__)
    files = Path.wildcard(Path.join(root, "*.json"))
    assert length(files) == 50
    Enum.each(files, fn file ->
      v = Jason.decode!(File.read!(file))
      results = StaticCallGraph.classify_source(v["source"], v["caller"])
      assert results != []
      assert Enum.any?(results, fn {_edge, result} -> elem(result, 0) == String.to_atom(v["expected"]) end)
    end)
  end
end
