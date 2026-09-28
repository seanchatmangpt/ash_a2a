defmodule AshA2A.Gall.Closure.PlanningConsumer do
  @moduledoc "Projects GALL candidate semantics to a planner without granting execution authority."

  def project(candidate) when is_map(candidate) do
    with capability when is_binary(capability) <-
           AshA2A.Gall.Fields.get(candidate, :capability_id),
         digest when is_binary(digest) <- AshA2A.Gall.Fields.get(candidate, :candidate_digest) do
      {:ok,
       %{
         kind: :bounded_intervention_candidate,
         candidate_digest: digest,
         capability_id: capability,
         horizon: AshA2A.Gall.Fields.get(candidate, :horizon),
         finding_class: AshA2A.Gall.Fields.get(candidate, :finding_class),
         authority: :none,
         standing: :candidate
       }}
    else
      _ -> {:error, {:refused_gall, :planning_consumer, :invalid_candidate}}
    end
  end

  def project(_), do: {:error, {:refused_gall, :planning_consumer, :invalid_candidate}}
end
