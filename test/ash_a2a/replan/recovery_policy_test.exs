# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.RecoveryPolicyTest do
  use ExUnit.Case, async: true

  test "unknown reconciles first" do
    assert :reconcile_before_replan = AshA2A.Replan.RecoveryPolicy.next(:unknown_outcome)
  end
end
