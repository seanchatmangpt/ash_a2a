defmodule AshA2A.Replan.RecoveryPolicyTest do
  use ExUnit.Case, async: true

  test "unknown reconciles first" do
    assert :reconcile_before_replan = AshA2A.Replan.RecoveryPolicy.next(:unknown_outcome)
  end
end
