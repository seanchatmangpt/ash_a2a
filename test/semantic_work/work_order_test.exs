# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticWork.WorkOrderTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.WorkOrder

  test "fails closed" do
    assert {:error, _} = WorkOrder.bind(%{})
    assert {:error, :refused_invalid_envelope} = WorkOrder.bind(:invalid)
  end
end
