defmodule AshA2A.GallClosure.InterventionBudgetTest do
  use ExUnit.Case, async: true
  alias AshA2A.GallClosure.InterventionBudget

  test "bounded admission",
    do: assert(match?({:ok, _}, InterventionBudget.admit(%{remaining_do: "witness"})))

  test "typed refusal", do: assert(InterventionBudget.admit(%{}) == {:error, :budget_exhausted})
end
