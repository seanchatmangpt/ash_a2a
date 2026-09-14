defmodule AshA2A.Semantic.PlanningIR do
  @moduledoc "Formal-planning projection manufactured from admitted semantics."

  alias AshA2A.Semantic.{IR, Ontology}

  @enforce_keys [:ontology_fingerprint, :goals, :objects, :predicates, :fingerprint]
  defstruct [
    :ontology_fingerprint,
    :goals,
    :objects,
    :predicates,
    :fingerprint,
    constraints: [],
    task_candidates: [],
    nondeterminism: [],
    observations: [],
    exclusions: [],
    standing: :admitted,
    authority: :none
  ]

  @type t :: %__MODULE__{}

  def from_ir(%IR{standing: :admitted, authority: :none} = ir, %Ontology{} = ontology) do
    planning = %__MODULE__{
      ontology_fingerprint: ontology.fingerprint,
      goals: Enum.map(ir.goals, &Map.fetch!(&1, "description")),
      objects: Enum.map(ir.entities, &Map.take(&1, ["id", "type", "label"])),
      predicates: Enum.map(ir.relations, &Map.take(&1, ["subject", "predicate", "object"])),
      constraints: Enum.map(ir.constraints, &Map.fetch!(&1, "description")),
      task_candidates: Enum.map(ir.capabilities, &Map.fetch!(&1, "description")),
      nondeterminism: Enum.map(ir.uncertainties, &Map.fetch!(&1, "description")),
      observations: Enum.map(ir.observations, &Map.fetch!(&1, "description")),
      exclusions: Enum.map(ir.exclusions, &Map.fetch!(&1, "description")),
      fingerprint: "pending"
    }

    {:ok, %{planning | fingerprint: fingerprint(planning)}}
  end

  def from_ir(_, _), do: {:error, %{code: :planning_ir_requires_admitted_semantics}}

  def primary_goal(%__MODULE__{goals: [goal | _]}), do: goal

  def observation(%__MODULE__{} = planning) do
    planning
    |> Map.from_struct()
    |> Map.drop([:fingerprint])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  def with_observation(%__MODULE__{} = planning, observation) when is_map(observation) do
    next = %{
      planning
      | observations: planning.observations ++ [observation],
        fingerprint: "pending"
    }

    %{next | fingerprint: fingerprint(next)}
  end

  defp fingerprint(term) do
    term
    |> Map.from_struct()
    |> Map.delete(:fingerprint)
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
