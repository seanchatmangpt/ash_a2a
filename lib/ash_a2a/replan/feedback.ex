defmodule AshA2A.Replan.Feedback do
  @enforce_keys [:subject, :receipt_id, :outcome]
  defstruct [:subject, :receipt_id, :outcome, :evidence, :provider]

  def from_receipt(r, provider \\ nil),
    do: %__MODULE__{
      subject: Map.get(r, :semantic_subject),
      receipt_id: Map.get(r, :receipt_id),
      outcome: AshA2A.Replan.Outcome.classify(r),
      evidence: r,
      provider: provider
    }
end
