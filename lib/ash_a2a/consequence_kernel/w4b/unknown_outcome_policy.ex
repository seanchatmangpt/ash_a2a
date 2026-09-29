defmodule AshA2A.ConsequenceKernel.W4B.UnknownOutcomePolicy do
  @moduledoc false
  def next(:unknown_outcome, :retry), do: {:error, :reconciliation_required}
  def next(:unknown_outcome, action) when action in [:reconcile, :compensate], do: {:ok, action}
  def next(state, _) when state in [:completed, :failed], do: {:ok, :terminal}
  def next(_, _), do: {:error, :invalid_outcome}
end
