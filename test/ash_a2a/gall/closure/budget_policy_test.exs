defmodule AshA2A.Gall.Closure.BudgetPolicyTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.BudgetPolicy

  test "one consequence is the only admitted budget" do
    assert {:ok, %{max_consequences: 1}} = BudgetPolicy.admit(1)
    assert {:ok, %{max_consequences: 1}} = BudgetPolicy.admit(%{max_consequences: 1})

    assert {:error, {:refused_gall, :budget_policy, {:must_equal_one, 2}}} =
             BudgetPolicy.admit(2)
  end
end
