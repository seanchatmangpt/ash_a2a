defmodule AshA2A.Replan.ReconcileGate do
  def allow?(%{terminal_status: :unknown_outcome}), do: {:error,%{code: :reconcile_required}}
  def allow?(_), do: :ok
end