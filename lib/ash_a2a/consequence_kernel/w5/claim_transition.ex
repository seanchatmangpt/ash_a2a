defmodule AshA2A.ConsequenceKernel.W5.ClaimTransition do
  @allowed MapSet.new([{:claimed,:doing},{:doing,:completed},{:doing,:failed},{:doing,:unknown_outcome},
    {:unknown_outcome,:reconciled_completed},{:unknown_outcome,:reconciled_not_applied},{:unknown_outcome,:reconciled_unknown}])
  def admit(f,t), do: if(MapSet.member?(@allowed,{f,t}),do: :ok,else: {:error,:effect_claim_transition_refused})
end
