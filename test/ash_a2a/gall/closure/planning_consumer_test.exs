# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.PlanningConsumerTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.PlanningConsumer

  test "planning projection preserves candidate standing but not authority" do
    candidate = %{
      candidate_digest: "cand",
      capability_id: "Item.create",
      horizon: "FAST",
      finding_class: "conformance"
    }

    assert {:ok, projection} = PlanningConsumer.project(candidate)
    assert projection.standing == :candidate
    assert projection.authority == :none

    assert {:error, {:refused_gall, :planning_consumer, :invalid_candidate}} =
             PlanningConsumer.project(%{candidate_digest: "cand"})
  end
end
