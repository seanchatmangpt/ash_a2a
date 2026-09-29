defmodule AshA2A.Replan.ReconcileGateTest do
  use ExUnit.Case, async: true

  test "unknown outcome blocks replan" do
    assert {:error, %{code: :reconcile_required}} =
             AshA2A.Replan.ReconcileGate.allow?(%{terminal_status: :unknown_outcome})
  end
end
