# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.Router do
  def decide(%{subject: s, outcome: o}) do
    case AshA2A.Replan.RecoveryPolicy.next(o) do
      :replan ->
        AshA2A.Replan.Decision.replan(s, o)

      :reconcile_before_replan ->
        AshA2A.Replan.Decision.replan(s, :unknown_outcome_reconcile_first)

      :stop ->
        AshA2A.Replan.Decision.stop(s, o)
    end
  end
end
