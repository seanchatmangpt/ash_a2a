defmodule AshA2A.Replan.RecoveryPolicy do
  def next(:unknown_outcome), do: :reconcile_before_replan
  def next(:failed), do: :replan
  def next(:refused), do: :stop
  def next(:executed), do: :stop
  def next(_), do: :replan
end