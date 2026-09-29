defmodule AshA2A.ConsequenceKernel.CallGraphCourtTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.{CallGraphCourt, CompleteMediation}
  @vectors Path.expand("../../../priv/sa2a/c1/call_graph_vectors/*.json", __DIR__)
  test "portable call-graph vectors preserve complete mediation" do
    files = Path.wildcard(@vectors)
    assert length(files) == 50
    Enum.each(files, fn file ->
      vector = file |> File.read!() |> Jason.decode!()
      edge = Map.fetch!(vector, "edge")
      {decision, reason} = CallGraphCourt.classify(edge)
      assert Atom.to_string(decision) == vector["expected"]["decision"], file
      assert Atom.to_string(reason) == vector["expected"]["reason"], file
      case decision do
        :admit -> assert {:ok, ^reason} = CompleteMediation.admit_call_edge(edge)
        :refuse -> assert {:error, ^reason} = CompleteMediation.admit_call_edge(edge)
      end
    end)
  end
end
