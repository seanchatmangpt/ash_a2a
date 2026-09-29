defmodule AshA2A.C2.BudgetLedger do
  def allocate(%{remaining: r} = b, n) when is_number(n) and n >= 0 and n <= r,
    do: {:ok, %{b | remaining: r - n}, %{limit: n, remaining: n}}

  def allocate(_, _), do: {:error, :budget_exceeded}

  def conserved?(parent, children), do: Enum.sum(Enum.map(children, & &1.limit)) <= parent.limit
end
