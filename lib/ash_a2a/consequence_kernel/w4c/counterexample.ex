defmodule AshA2A.ConsequenceKernel.W4C.Counterexample do
  def minimal([]), do: nil
  def minimal([edge|_]), do: edge
end
