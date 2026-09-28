defmodule AshA2A.Gall.Closure.SimulationConsumerTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.SimulationConsumer

  test "simulation consumer cannot cross the consequence boundary" do
    candidate = %{candidate_digest: "cand", capability_id: "Item.create"}
    projection = SimulationConsumer.project(candidate, %{input_digest: "x"}, %{item_exists: true})

    assert projection.kind == :gall_simulation_case
    assert projection.evidence_ceiling == :construct
    assert projection.authority == :none
  end
end
