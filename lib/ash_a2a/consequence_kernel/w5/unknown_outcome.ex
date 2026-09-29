defmodule AshA2A.ConsequenceKernel.W5.UnknownOutcome do
  def next(:unknown_outcome), do: {:reconcile, :effect_id}
  def next(_), do: {:error, :not_unknown_outcome}
  def retry(:unknown_outcome), do: {:error, :retry_forbidden}
end
