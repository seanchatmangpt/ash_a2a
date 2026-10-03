defmodule AshA2A.AuthZEN.DecisionGate do
  @moduledoc """
  Re-checks observed AuthZEN policy evidence against a `AshA2A.C2.PreparedEffect` in
  `admit/3`: allow, expected PDP, effect digest, and principal must all hold. A PDP
  allow is evidence only and never substitutes for admission.
  """

  alias AshA2A.AuthZEN.PolicyEvidence
  alias AshA2A.C2.PreparedEffect

  def admit(%PolicyEvidence{} = evidence, %PreparedEffect{} = effect, expected_pdp) do
    cond do
      evidence.decision != true -> {:error, :denied}
      evidence.policy_decision_point != expected_pdp -> {:error, :pdp_mixup}
      evidence.effect_digest != effect.digest -> {:error, :effect_digest_mismatch}
      evidence.principal != effect.principal -> {:error, :principal_mismatch}
      true -> :ok
    end
  end
end
