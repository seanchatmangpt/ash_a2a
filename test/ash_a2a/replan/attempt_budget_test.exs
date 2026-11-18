# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.AttemptBudgetTest do
  use ExUnit.Case, async: true

  test "budget exhausts" do
    b = AshA2A.Replan.AttemptBudget.new(1)
    assert {:ok, b} = AshA2A.Replan.AttemptBudget.consume(b)
    assert {:error, %{code: :replan_exhausted}} = AshA2A.Replan.AttemptBudget.consume(b)
  end
end
