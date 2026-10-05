# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.ReplayGuardTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.ReplayGuard

  test "same effect identity is exact replay, rebinding is refused" do
    previous = %{command_id: "c1", actuation_id: "a1", idempotency_key: "k1"}
    assert {:ok, :exact_replay} = ReplayGuard.classify(previous, previous)

    rebound = %{command_id: "c1", actuation_id: "a2", idempotency_key: "k2"}

    assert {:error, {:refused_gall, :replay_guard, :command_rebound_to_new_effect}} =
             ReplayGuard.classify(previous, rebound)
  end
end
