defmodule AshA2A.GallClosure.InterventionBudget do
  @moduledoc "Bounded GALL-029/030 guard for remaining_do."
  def admit(%{remaining_do: v}=s) when v not in [nil,false,""], do: {:ok, Map.put(s,:gall_guard,:intervention_budget)}
  def admit(_), do: {:error,:budget_exhausted}
end
