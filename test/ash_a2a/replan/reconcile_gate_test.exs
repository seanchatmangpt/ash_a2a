# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.ReconcileGateTest do
  use ExUnit.Case, async: true

  test "unknown outcome blocks replan" do
    assert {:error, %{code: :reconcile_required}} =
             AshA2A.Replan.ReconcileGate.allow?(%{terminal_status: :unknown_outcome})
  end
end
