defmodule AshA2A.AuthZEN.PolicyEvidenceFactory do
  alias AshA2A.AuthZEN.{Metadata, PolicyEvidence, Types}
  alias AshA2A.C2.PreparedEffect

  def from_decision(%Types.Decision{} = decision, %PreparedEffect{} = effect, %Metadata{} = metadata, observed_at \\ System.system_time(:millisecond)) do
    %PolicyEvidence{
      decision: decision.decision,
      policy_decision_point: metadata.policy_decision_point,
      principal: effect.principal,
      effect_digest: effect.digest,
      observed_at: observed_at,
      context: decision.context || %{}
    }
  end
end
