defmodule AshA2A.ConsequenceKernel.W4C.RawEffectEdges do
  alias AshA2A.ConsequenceKernel.W4C.{GraphEdge, GraphReport}
  def from_report(edges) do
    edges
    |> GraphReport.normalize()
    |> Enum.filter(&GraphEdge.consequential?/1)
    |> Enum.reject(fn edge ->
      String.starts_with?(to_string(edge.caller), "Elixir.AshA2A.ConsequenceKernel")
    end)
  end
end
