defmodule AshA2A.ConsequenceKernel.W4C.ClosureStatus do
  def from_edges([]), do: :closed
  def from_edges(_), do: :open
end
