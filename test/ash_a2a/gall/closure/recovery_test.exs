# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.RecoveryTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.Recovery

  test "recovery routes around the failed edge without bypassing it" do
    assert {:repair, :recompute_exact_scope} =
             Recovery.route(%{status: :refused, boundary: :scope_policy})

    assert {:repair, :reconcile_actuation_identity} =
             Recovery.route(%{status: :refused, boundary: :replay_guard})

    assert {:stop, :not_a_refusal} = Recovery.route(%{status: :ok})
  end
end
