# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.AuthZEN.PolicyEvidence do
  @moduledoc """
  Authority-free result of an external AuthZEN policy evaluation.
  This value is evidence only; it never substitutes for a C2 certificate.
  """
  @enforce_keys [:decision, :policy_decision_point, :principal, :effect_digest, :observed_at]
  defstruct @enforce_keys ++ [context: %{}]
  def allowed?(%__MODULE__{decision: true}), do: true
  def allowed?(%__MODULE__{}), do: false
end
