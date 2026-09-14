defmodule AshA2A.Semantic.ExecutionPackage do
  @moduledoc "Candidate-only bundle consumed by AshA2A planning/runtime boundaries."

  alias AshA2A.Planning.Candidate
  alias AshA2A.Semantic.{IR, Ontology, PlanningIR, Source}

  @enforce_keys [:source, :semantic_ir, :ontology, :planning_ir, :plan_candidate, :fingerprint]
  defstruct [
    :source,
    :semantic_ir,
    :ontology,
    :planning_ir,
    :plan_candidate,
    :fingerprint,
    :parent_fingerprint,
    feedback: [],
    standing: :candidate,
    authority: :none
  ]

  @type t :: %__MODULE__{}

  def new(%Source{} = source, %IR{} = ir, %Ontology{} = ontology, %PlanningIR{} = planning, %Candidate{} = candidate, opts \\ []) do
    with :ok <- fence(ir, ontology, planning, candidate) do
      term = {source.id, ontology.fingerprint, planning.fingerprint, candidate.fingerprint}

      {:ok,
       %__MODULE__{
         source: source,
         semantic_ir: ir,
         ontology: ontology,
         planning_ir: planning,
         plan_candidate: candidate,
         parent_fingerprint: Keyword.get(opts, :parent_fingerprint),
         feedback: Keyword.get(opts, :feedback, []),
         fingerprint: fingerprint(term)
       }}
    end
  end

  defp fence(%IR{standing: :admitted, authority: :none}, %Ontology{authority: :none}, %PlanningIR{authority: :none}, %Candidate{standing: :candidate, authority: :none}), do: :ok
  defp fence(_, _, _, _), do: {:error, %{code: :semantic_package_authority_ceiling_violated}}

  defp fingerprint(term) do
    term |> :erlang.term_to_binary() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end
end
