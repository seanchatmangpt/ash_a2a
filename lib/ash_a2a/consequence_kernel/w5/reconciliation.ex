defmodule AshA2A.ConsequenceKernel.W5.Reconciliation do
  def resolve(:observed_applied, e), do: {:completed, e}
  def resolve(:observed_not_applied, e), do: {:failed, e}
  def resolve(_, e), do: {:unknown_outcome, e}
end
