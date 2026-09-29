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
