defmodule AshA2A.Replan.AttemptBudgetTest do
  use ExUnit.Case, async: true

  test "budget exhausts" do
    b = AshA2A.Replan.AttemptBudget.new(1)
    assert {:ok, b} = AshA2A.Replan.AttemptBudget.consume(b)
    assert {:error, %{code: :replan_exhausted}} = AshA2A.Replan.AttemptBudget.consume(b)
  end
end
