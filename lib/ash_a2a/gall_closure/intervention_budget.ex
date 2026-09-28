defmodule AshA2A.GallClosure.InterventionBudget do
  @moduledoc "Bounded GALL-029/030 guard for remaining_do: must be an integer > 0."
  def admit(%{remaining_do: v} = s) when is_integer(v) and v > 0,
    do: {:ok, Map.put(s, :gall_guard, :intervention_budget)}

  def admit(_), do: {:error, :budget_exhausted}
end
