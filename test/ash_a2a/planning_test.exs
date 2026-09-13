defmodule AshA2A.PlanningTest do
  use ExUnit.Case, async: true

  alias AshA2A.Planning
  alias AshA2A.Planning.Candidate
  alias AshA2A.Test.Fixture.Echo

  test "canonical planner capability ids are admitted but remain candidate-only" do
    envelope = %{
      "request_id" => "plan-1",
      "steps" => [%{"capability_id" => "AshA2A.Test.Fixture.Echo.read"}]
    }

    assert {:ok, candidate} =
             Planning.from_envelope(Echo, envelope,
               planner: :ferroplan,
               formalism: :pddl
             )

    assert candidate.standing == :candidate
    assert candidate.authority == :none
    assert candidate.planner == :ferroplan
    assert candidate.formalism == :pddl
    assert candidate.capability_ids == ["AshA2A.Test.Fixture.Echo.read"]
    assert [%{id: "AshA2A.Test.Fixture.Echo.read"}] = candidate.admitted_skills
  end

  test "noncanonical planner capability ids are refused before execution" do
    envelope = %{
      "steps" => [%{"capability_id" => "AshA2A.Test.Fixture.Echo.delete_everything"}]
    }

    assert {:error, %{code: :noncanonical_capability}} =
             Planning.from_envelope(Echo, envelope, planner: :ferroplan)
  end

  test "candidate authority ceiling cannot be widened by a planner" do
    candidate =
      Candidate.new(
        :external,
        %{"steps" => []},
        ["AshA2A.Test.Fixture.Echo.read"]
      )
      |> Map.put(:authority, :do)

    assert {:error, %{code: :planner_authority_ceiling_violated}} =
             Planning.admit(Echo, candidate)
  end

  test "nested capability projections are collected deterministically" do
    envelope = %{
      "methods" => [
        %{
          "subtasks" => [
            %{"capability_id" => "AshA2A.Test.Fixture.Echo.read"},
            %{"capability_ids" => ["AshA2A.Test.Fixture.Echo.read"]}
          ]
        }
      ]
    }

    assert Planning.extract_capability_ids(envelope) == [
             "AshA2A.Test.Fixture.Echo.read"
           ]
  end
end
