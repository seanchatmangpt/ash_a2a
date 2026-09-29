defmodule AshA2A.Replan.Outcome do
  @terminal [:executed,:refused,:failed,:reconciled,:compensated,:unknown_outcome]
  def classify(%{terminal_status: s}) when s in @terminal, do: s
  def classify(_), do: :unknown_outcome
  def recoverable?(:unknown_outcome), do: true
  def recoverable?(:failed), do: true
  def recoverable?(_), do: false
end