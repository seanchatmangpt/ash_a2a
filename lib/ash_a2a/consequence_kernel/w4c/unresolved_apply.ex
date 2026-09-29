defmodule AshA2A.ConsequenceKernel.W4C.UnresolvedApply do
  alias AshA2A.ConsequenceKernel.W4C.GraphEdge
  def edge(caller, source), do: %GraphEdge{caller: caller, callee: :unresolved_apply, kind: :dynamic_effect, source: source}
end
