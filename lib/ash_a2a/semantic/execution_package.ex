defmodule AshA2A.Semantic.ExecutionPackage do
  @moduledoc "Candidate-only bundle consumed by AshA2A planning/runtime boundaries."

  alias A2A.Part
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

  def new(
        %Source{} = source,
        %IR{} = ir,
        %Ontology{} = ontology,
        %PlanningIR{} = planning,
        %Candidate{} = candidate,
        opts \\ []
      ) do
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

  defp fence(
         %IR{standing: :admitted, authority: :none},
         %Ontology{authority: :none},
         %PlanningIR{authority: :none},
         %Candidate{standing: :candidate, authority: :none}
       ),
       do: :ok

  defp fence(_, _, _, _), do: {:error, %{code: :semantic_package_authority_ceiling_violated}}

  defp fingerprint(term) do
    term
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Converts an admitted `t()` into a real `AshA2A.Dispatcher.reply()` --
  the same reply-tuple contract the ordinary CRUD/generic-action dispatch
  path returns, so a caller of the explicit semantic-request A2A surface
  (`AshA2A.Agent.__dispatch__/3`) sees one consistent reply shape regardless
  of which real path produced it.

  The reply carries only candidate-standing, `authority: :none` evidence --
  `request_id`/`capability_ids` (re-admitted against the canonical
  `AshA2A.Info` capability index by `SemanticSynthesis.synthesize/4`, never
  the model's own claim), the synthesized `hddl`/`fond`/`rationale` text,
  and this package's own content-addressed `fingerprint` (so a caller can
  later present it back as a continuation for `AshA2A.Semantic.Compiler.
  replan/4` -- see `AshA2A.Agent`'s receipt-driven replanning wiring). It
  never claims execution occurred; nothing in this reply can be mistaken
  for a `DO` receipt.
  """
  @spec to_reply(t()) :: AshA2A.Dispatcher.reply()
  def to_reply(%__MODULE__{standing: :candidate, authority: :none} = package) do
    candidate = package.plan_candidate
    synthesis = Map.get(candidate.plan, "synthesis", %{})

    body = %{
      "execution_package_fingerprint" => package.fingerprint,
      "standing" => "candidate",
      "authority" => "none",
      "request_id" => Map.get(candidate.plan, "request_id"),
      "capability_ids" => candidate.capability_ids,
      "hddl" => Map.get(synthesis, "hddl"),
      "fond" => Map.get(synthesis, "fond"),
      "rationale" => Map.get(synthesis, "rationale")
    }

    {:reply, [Part.Data.new(body)]}
  end

  def to_reply(_non_admitted_package) do
    {:error, %{code: :semantic_package_authority_ceiling_violated}}
  end
end
