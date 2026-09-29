defmodule AshA2A.Replan.Observation do
  @enforce_keys [:subject,:outcome]
  defstruct [:subject,:outcome,:receipt,:evidence]
  def from_feedback(f), do: %__MODULE__{subject:f.subject,outcome:f.outcome,receipt:f.receipt_id,evidence:f.evidence}
end