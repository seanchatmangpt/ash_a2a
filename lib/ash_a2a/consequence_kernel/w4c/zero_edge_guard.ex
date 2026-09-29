defmodule AshA2A.ConsequenceKernel.W4C.ZeroEdgeGuard do
  def admit([]), do: :ok
  def admit(edges), do: {:error, {:raw_effect_edges, length(edges)}}
end
