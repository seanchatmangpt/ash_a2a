defmodule AshA2A.ConsequenceKernel.W4C.Dedupe do
  def edges(xs), do: Enum.uniq_by(xs, &AshA2A.ConsequenceKernel.W4C.EdgeIdentity.key/1)
end
