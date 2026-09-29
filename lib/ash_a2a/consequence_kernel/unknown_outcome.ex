defmodule AshA2A.ConsequenceKernel.UnknownOutcome do
  defstruct [:effect_id, :prepared_digest, :reason, :evidence]

  def new(prepared, reason, evidence \\ []) do
    %__MODULE__{
      effect_id: prepared.instance.effect_id,
      prepared_digest: prepared.prepared_digest,
      reason: reason,
      evidence: evidence
    }
  end
end
