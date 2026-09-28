defmodule AshA2A.GallClosure.InterventionBudgetTest do
  use ExUnit.Case, async: true
  alias AshA2A.GallClosure.InterventionBudget

  test "bounded admission",
    do: assert(match?({:ok, _}, InterventionBudget.admit(%{remaining_do: 1})))

  test "typed refusal", do: assert(InterventionBudget.admit(%{}) == {:error, :budget_exhausted})

  test "admits positive integers with guard tag" do
    assert {:ok, %{gall_guard: :intervention_budget}} =
             InterventionBudget.admit(%{remaining_do: 3})
  end

  test "refuses exhausted or non-integer budgets" do
    for v <- [0, -1, "witness", "3", 1.5, true, nil, false, ""] do
      assert InterventionBudget.admit(%{remaining_do: v}) == {:error, :budget_exhausted}
    end
  end
end
