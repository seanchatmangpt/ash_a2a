defmodule AshA2A.SemanticWork.BudgetTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.Budget

  test "refusal is typed" do
    assert {:error, {:refused_missing_identity, _}} = Budget.bind(%{})
    assert {:error, :refused_invalid_envelope} = Budget.bind(nil)
  end

  test "valid budget defaults consumed to 0" do
    assert {:ok, %{budget: 5, subject: "s", consumed: 0}} =
             Budget.bind(%{"budget" => 5, "subject" => "s"})

    assert {:ok, %{budget: 0, consumed: 0}} = Budget.bind(%{budget: 0, subject: "s"})
    assert {:ok, %{consumed: 5}} = Budget.bind(%{budget: 5, subject: "s", consumed: 5})
  end

  test "refuses consumed over budget" do
    assert {:error, {:refused_budget_exceeded, _}} =
             Budget.bind(%{budget: 5, subject: "s", consumed: 6})
  end

  test "refuses invalid consumed" do
    for bad <- [-1, 1.5, "1", :x] do
      assert {:error, {:refused_budget_exceeded, _}} =
               Budget.bind(%{budget: 5, subject: "s", consumed: bad})
    end
  end

  test "refuses invalid budget" do
    for bad <- [-1, 1.5, "10", :x] do
      assert {:error, {:refused_budget_exceeded, _}} = Budget.bind(%{budget: bad, subject: "s"})
    end
  end
end
