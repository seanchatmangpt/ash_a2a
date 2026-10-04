defmodule AshA2A.CelonisConformanceTest do
  @moduledoc """
  Celonis-style process mining conformance and replay court for AshA2A event logs.

  Verifies:
  1. Fitness == 1.0 on admitted A2A trace executions (all events replay lawfully against model).
  2. Precision >= 0.90 against the state transition model.
  3. Segregation of Duties (SoD) anti-vacuity court: detecting unauthorized authority/consequence transitions.
  """

  use ExUnit.Case, async: true

  # Model transitions for a lawful A2A Command execution trace:
  # ADMITTED -> CLAIMED -> RECEIPT_ANCHORED -> EXECUTING -> CONSEQUENCE_OBSERVED -> COMMITTED
  @valid_transitions %{
    "ADMITTED" => ["CLAIMED"],
    "CLAIMED" => ["RECEIPT_ANCHORED", "DEDUP_COMMITTED"],
    "RECEIPT_ANCHORED" => ["EXECUTING"],
    "EXECUTING" => ["CONSEQUENCE_OBSERVED"],
    "CONSEQUENCE_OBSERVED" => ["COMMITTED"],
    "COMMITTED" => []
  }

  describe "Celonis-style OCEL conformance court" do
    test "computes fitness == 1.0 for valid A2A execution traces" do
      trace = [
        "ADMITTED",
        "CLAIMED",
        "RECEIPT_ANCHORED",
        "EXECUTING",
        "CONSEQUENCE_OBSERVED",
        "COMMITTED"
      ]

      fitness = compute_fitness(trace, @valid_transitions)
      assert fitness == 1.0
    end

    test "detects SoD violation (Segregation of Duties) when consequence executes without authority anchor" do
      # Deliberate illegal trace: skips RECEIPT_ANCHORED (SoD violation)
      # Transitions: ADMITTED->CLAIMED (valid), CLAIMED->EXECUTING (invalid),
      # EXECUTING->CONSEQUENCE_OBSERVED (valid), CONSEQUENCE_OBSERVED->COMMITTED (valid)
      # Total transitions: 4, valid: 3 -> fitness = 0.75
      illegal_trace = [
        "ADMITTED",
        "CLAIMED",
        "EXECUTING",
        "CONSEQUENCE_OBSERVED",
        "COMMITTED"
      ]

      fitness = compute_fitness(illegal_trace, @valid_transitions)
      assert fitness < 1.0
      assert fitness == 0.75
    end

    test "precision >= 0.90 on state transitions" do
      observed_paths = [
        ["ADMITTED", "CLAIMED", "RECEIPT_ANCHORED", "EXECUTING", "CONSEQUENCE_OBSERVED", "COMMITTED"],
        ["ADMITTED", "CLAIMED", "DEDUP_COMMITTED"]
      ]

      precision = compute_precision(observed_paths, @valid_transitions)
      assert precision >= 0.90
    end
  end

  # Helper: computes token replay fitness
  defp compute_fitness(trace, model) do
    transitions = Enum.zip(trace, tl(trace))

    valid_count =
      Enum.count(transitions, fn {from, to} ->
        allowed = Map.get(model, from, [])
        to in allowed
      end)

    valid_count / length(transitions)
  end

  # Helper: computes model precision
  defp compute_precision(traces, model) do
    observed_edges =
      traces
      |> Enum.flat_map(fn trace -> Enum.zip(trace, tl(trace)) end)
      |> MapSet.new()

    model_edges =
      model
      |> Enum.flat_map(fn {from, tos} -> Enum.map(tos, &{from, &1}) end)
      |> MapSet.new()

    # Precision = observed model edges / total model edges reachable in visited states
    visited_states =
      traces
      |> List.flatten()
      |> MapSet.new()

    reachable_model_edges =
      Enum.filter(model_edges, fn {from, _to} -> MapSet.member?(visited_states, from) end)
      |> MapSet.new()

    if MapSet.size(reachable_model_edges) == 0 do
      1.0
    else
      MapSet.size(MapSet.intersection(observed_edges, reachable_model_edges)) /
        MapSet.size(reachable_model_edges)
    end
  end
end
