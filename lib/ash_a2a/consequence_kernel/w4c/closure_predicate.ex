defmodule AshA2A.ConsequenceKernel.W4C.ClosurePredicate do
  alias AshA2A.ConsequenceKernel.W4C.RawEffectEdges

  def evaluate(report) do
    case RawEffectEdges.from_report(report) do
      [] -> {:ok, :zero_consequential_raw_effect_edges}
      edges -> {:error, {:raw_effect_edges, edges}}
    end
  end
end
