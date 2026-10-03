defmodule AshA2A.AuthZEN.PolicyEvidenceFactory do
  @moduledoc """
  Builds `AshA2A.AuthZEN.PolicyEvidence` from an observed decision, prepared effect, and
  PDP metadata via `from_decision/4`. The product is authority-free evidence of what the
  PDP said; it never substitutes for a C2 certificate.
  """

  alias AshA2A.AuthZEN.{Metadata, PolicyEvidence, Types}
  alias AshA2A.C2.PreparedEffect

  def from_decision(
        %Types.Decision{} = decision,
        %PreparedEffect{} = effect,
        %Metadata{} = metadata,
        observed_at \\ System.system_time(:millisecond)
      ) do
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
