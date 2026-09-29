defmodule AshA2A.Replan.RecoveryPolicy do
  # MERGE NOTE: main's policy kept (portable envelope contract); it is a strict superset of r2's
  # (adds :reconciled and :compensated as terminal :stop). All r2 mappings are unchanged.
  def next(:unknown_outcome), do: :reconcile_before_replan
  def next(:failed), do: :replan
  def next(:refused), do: :stop
  def next(:executed), do: :stop
  def next(:reconciled), do: :stop
  def next(:compensated), do: :stop
  def next(_), do: :replan
end
