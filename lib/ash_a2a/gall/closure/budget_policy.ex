defmodule AshA2A.Gall.Closure.BudgetPolicy do
  @moduledoc "Enforces the GALL-030 one-consequence budget before any DO edge is reachable."

  def admit(1), do: {:ok, %{max_consequences: 1}}
  def admit(%{max_consequences: 1} = budget), do: {:ok, budget}
  def admit(%{"max_consequences" => 1} = budget), do: {:ok, budget}

  def admit(value),
    do: {:error, {:refused_gall, :budget_policy, {:must_equal_one, value}}}
end
