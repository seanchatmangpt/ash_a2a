# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.AttemptBudget do
  defstruct remaining: 3
  def new(n) when is_integer(n) and n > 0, do: %__MODULE__{remaining: n}
  def consume(%__MODULE__{remaining: n} = b) when n > 0, do: {:ok, %{b | remaining: n - 1}}
  def consume(%__MODULE__{}), do: {:error, AshA2A.Replan.Refusal.new(:replan_exhausted)}
end
