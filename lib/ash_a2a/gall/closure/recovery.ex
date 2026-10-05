# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.Recovery do
  @moduledoc "Routes each typed refusal to an adjacent lawful repair edge without bypassing its failed guard."

  def route(%{boundary: :exact_subject}), do: {:repair, :rebind_exact_source}
  def route(%{boundary: :producer_policy}), do: {:repair, :refresh_producer_pin}
  def route(%{boundary: :evidence_policy}), do: {:repair, :supply_admitted_evidence}
  def route(%{boundary: :semantic_subject_policy}), do: {:repair, :resolve_semantic_subject}
  def route(%{boundary: :vocabulary_policy}), do: {:repair, :map_public_vocabulary}
  def route(%{boundary: :scope_policy}), do: {:repair, :recompute_exact_scope}
  def route(%{boundary: :budget_policy}), do: {:repair, :bound_budget_to_one}
  def route(%{boundary: :postcondition_policy}), do: {:repair, :reobserve_independently}
  def route(%{boundary: :receipt_binding}), do: {:repair, :reconstruct_receipt_binding}
  def route(%{boundary: :replay_guard}), do: {:repair, :reconcile_actuation_identity}
  def route(%{status: :refused}), do: {:repair, :reconstruct_candidate}
  def route(_), do: {:stop, :not_a_refusal}
end
