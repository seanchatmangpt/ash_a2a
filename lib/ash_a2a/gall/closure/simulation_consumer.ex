defmodule AshA2A.Gall.Closure.SimulationConsumer do
  @moduledoc "Projects an admitted candidate into a simulation-only case that cannot cross DO."

  def project(candidate, scope, expected_postcondition)
      when is_map(candidate) and is_map(scope) and is_map(expected_postcondition) do
    %{
      kind: :gall_simulation_case,
      candidate_digest: field(candidate, :candidate_digest),
      capability_id: field(candidate, :capability_id),
      scope: scope,
      expected_postcondition: expected_postcondition,
      evidence_ceiling: :construct,
      authority: :none
    }
  end

  def project(_, _, _), do: {:error, {:refused_gall, :simulation_consumer, :invalid_input}}

  defp field(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end
