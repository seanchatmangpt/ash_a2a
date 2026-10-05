# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.AuthZEN.DecisionGate do
  @moduledoc """
  Re-checks observed AuthZEN policy evidence against a `AshA2A.C2.PreparedEffect` in
  `admit/3`: allow, expected PDP, effect digest, and principal must all hold. A PDP
  allow is evidence only and never substitutes for admission.

  ## Delegation-aware admission (FR-01.4)

  `admit_delegated/4` is a strictly-additive extension: it is `admit/3`, and
  additionally -- when a delegation chain (`AshA2A.AuthZEN.Monotonic` struct)
  is supplied -- requires the effect's capability to lie inside the chain's
  effective (narrowed) set. An expansion attempt refuses with the typed
  `AshA2A.AuthZEN.Monotonic.Refusal` receipt
  (`:refused_non_monotonic_grant`) before any downstream dispatch; a `nil`
  chain degrades to plain `admit/3`. The existing `admit/3` clauses are
  untouched.
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

  @doc """
  Delegation-aware admission (FR-01.4): `admit/3`, plus a monotonic-narrowing
  check of the effect's capability against the delegation `chain`.

  Refuses in gate order: first every `admit/3` condition, then -- only after
  the evidence binds the exact effect -- the chain check, so a refused
  capability surfaces as the typed
  `{:error, %AshA2A.AuthZEN.Monotonic.Refusal{}}` receipt with code
  `:refused_non_monotonic_grant` and zero downstream dispatch. `nil` chain
  means "no delegation in scope" and admits exactly as `admit/3` does.
  """
  def admit_delegated(evidence, effect, expected_pdp, nil) do
    admit(evidence, effect, expected_pdp)
  end

  def admit_delegated(evidence, effect, expected_pdp, %AshA2A.AuthZEN.Monotonic{} = chain) do
    with :ok <- admit(evidence, effect, expected_pdp) do
      AshA2A.AuthZEN.Monotonic.authorize(chain, effect.capability)
    end
  end
end
