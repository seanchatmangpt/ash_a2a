defmodule AshA2A.Semantic.PlanProjection do
  @moduledoc """
  `P = pi_plan(O*)` -- the derived planning projection (RFC-SA2A-001 S23),
  and the projected-ephemeral-software fence (RFC-SA2A-001 S27).

  ## S23: the projection is DERIVED; the semantic graph stays authoritative

  A conforming planner operates only over admitted planning objects. This
  struct is manufactured from an already-admitted
  `AshA2A.Semantic.PlanningIR` plus the `AshA2A.Semantic.Ontology` it was
  projected from -- `from_admitted/2` has no clause that accepts raw input,
  a candidate-standing IR, or a hand-built map. The only lawful entry is an
  admitted pair, so a `%PlanProjection{}` existing at all is evidence that
  admission ran.

  This module deliberately does NOT re-derive the planning content: that is
  `PlanningIR.from_ir/2`'s job and duplicating it here would create the
  second source of truth S27 forbids. What this adds on top of `PlanningIR`
  is the *binding to a source graph identity* plus the drift/tamper checks
  that make S27 a checkable property rather than a stated intention.

  ## S27: a projection MUST NOT become a second source of semantic truth

  Two real, separately-refusable failure modes, both checked by `verify/2`:

    * **source drift** -- the authoritative graph moved on. The projection
      records `source_graph_digest` (the ontology fingerprint it was
      projected from). Re-verifying against a *different* ontology refuses
      with `:projection_source_drift`. The projection does not silently
      "update"; a stale projection is refused, forcing re-projection from
      the graph.
    * **projection tampering** -- somebody edited the projection in place
      (the literal "manual edits to a projection MUST NOT become canonical
      semantic change" case). `projection_digest` is a
      `AshA2A.Semantic.CanonicalTermDigest` over the projection's own content
      fields. `verify/2` recomputes it and refuses with
      `:projection_manual_edit_not_canonical` when the recomputed digest
      disagrees with the recorded one.

  Note the asymmetry, which is the whole point of S27: an edited projection
  is *refused*, never promoted. There is deliberately no `promote/1`,
  `commit/1`, or `adopt/1` function on this module -- the only way to change
  what a projection says is to change the graph and re-project.

  Standing is `:derived` and authority is `:none`. A projection is evidence,
  not a grant; nothing here can be presented to `AshA2A.CommandBus`.
  """

  alias AshA2A.Semantic.{CanonicalTermDigest, Ontology, PlanningIR, Vocabulary}

  @enforce_keys [
    :source_id,
    :source_graph_digest,
    :planning_ir_fingerprint,
    :goals,
    :objects,
    :predicates,
    :projection_digest
  ]
  defstruct [
    :source_id,
    :source_graph_digest,
    :planning_ir_fingerprint,
    :goals,
    :objects,
    :predicates,
    :projection_digest,
    constraints: [],
    task_candidates: [],
    nondeterminism: [],
    exclusions: [],
    standing: :derived,
    authority: :none
  ]

  @type t :: %__MODULE__{
          source_id: String.t(),
          source_graph_digest: String.t(),
          planning_ir_fingerprint: String.t(),
          goals: [String.t()],
          objects: [map()],
          predicates: [map()],
          projection_digest: String.t(),
          constraints: [String.t()],
          task_candidates: [String.t()],
          nondeterminism: [String.t()],
          exclusions: [String.t()],
          standing: :derived,
          authority: :none
        }

  @type refusal :: {:error, %{code: atom(), detail: term()}}

  # The fields that ARE the projection's semantic content. `projection_digest`
  # itself is excluded (it is the digest OF these) and so are `standing`/
  # `authority`, which are structural constants this module enforces rather
  # than projected content.
  @content_fields [
    :source_id,
    :source_graph_digest,
    :planning_ir_fingerprint,
    :goals,
    :objects,
    :predicates,
    :constraints,
    :task_candidates,
    :nondeterminism,
    :exclusions
  ]

  @doc """
  Manufactures `P = pi_plan(O*)` from an admitted planning IR and the
  ontology it came from.

  Refuses (rather than coercing) when:

    * the `PlanningIR` is not `authority: :none` -- `:projection_authority_ceiling_violated`
    * the `Ontology` is not `standing: :admitted, authority: :none` --
      `:projection_requires_admitted_graph`
    * the IR was projected from a different ontology than the one supplied
      (`planning.ontology_fingerprint != ontology.fingerprint`) --
      `:projection_ontology_mismatch`. This is the S23 "the graph stays
      authoritative" check at construction time: you cannot staple a
      planning IR onto an unrelated graph to make it look admitted.
  """
  @spec from_admitted(PlanningIR.t(), Ontology.t()) :: {:ok, t()} | refusal()
  def from_admitted(%PlanningIR{} = planning, %Ontology{} = ontology) do
    with :ok <- fence(planning, ontology),
         :ok <- same_graph(planning, ontology) do
      projection = %__MODULE__{
        source_id: ontology.source_id,
        source_graph_digest: ontology.fingerprint,
        planning_ir_fingerprint: planning.fingerprint,
        goals: planning.goals,
        objects: planning.objects,
        predicates: planning.predicates,
        constraints: planning.constraints,
        task_candidates: planning.task_candidates,
        nondeterminism: planning.nondeterminism,
        exclusions: planning.exclusions,
        projection_digest: "pending"
      }

      {:ok, %{projection | projection_digest: content_digest(projection)}}
    end
  end

  def from_admitted(_planning, _ontology),
    do: error(:projection_requires_admitted_planning_ir)

  @doc """
  Recomputes this projection's content digest from its own current fields.

  Exposed so a caller can compare digests itself without going through
  `verify/2` (for example when re-projecting and asking "did anything
  actually change?").
  """
  @spec content_digest(t()) :: String.t()
  def content_digest(%__MODULE__{} = projection) do
    projection
    |> Map.take(@content_fields)
    |> CanonicalTermDigest.digest()
  end

  @doc """
  The S27 check, run against the currently-authoritative graph.

  `{:ok, projection}` iff the projection has not been manually edited AND
  the ontology it names is still the one supplied. Otherwise a typed
  refusal:

    * `:projection_manual_edit_not_canonical` -- recomputed content digest
      disagrees with the recorded `projection_digest`. Detail carries both
      digests.
    * `:projection_source_drift` -- the projection's recorded
      `source_graph_digest` is not this ontology's fingerprint. Detail
      carries `%{recorded: ..., current: ...}`.

    * `:projection_not_witnessed_by_graph` -- the projection is
      self-consistent (for example edited AND re-digested) but its content is
      not what the graph carries. Detail names the first unwitnessed field.

  A projection whose `standing`/`authority` is not `:derived`/`:none` is
  refused as `:projection_manual_edit_not_canonical` as well.

  Order matters: the tamper check runs first, because a hand-edited
  `source_graph_digest` would otherwise be able to masquerade as a
  legitimate drift (or, worse, as agreement).
  """
  @spec verify(t(), Ontology.t()) :: {:ok, t()} | refusal()
  def verify(%__MODULE__{} = projection, %Ontology{} = ontology) do
    projection |> check_against_graph(ontology) |> emit_verify(:graph)
  end

  defp check_against_graph(projection, ontology) do
    with {:ok, projection} <- check_self(projection) do
      if projection.source_graph_digest != ontology.fingerprint do
        error(:projection_source_drift, %{
          recorded: projection.source_graph_digest,
          current: ontology.fingerprint
        })
      else
        witnessed_by_graph(projection, ontology)
      end
    end
  end

  # RFC-SA2A-002 §77 (SA2A-PROJECTION-002): a projection edited AND re-digested
  # passes the self-check, so the authoritative graph must witness the content.
  # Every projected string field must equal, as a multiset, the
  # `schema:description`s of the ontology nodes typed with the IR field it was
  # derived from; objects must be exactly the entity nodes (and carry their
  # `rdf:type`); predicates must be exactly the relation triples. Object labels
  # are not in `O*` (the ontology records an entity's description), so they are
  # the one projected value the graph cannot witness.
  @witnessed_text [
    goals: :goals,
    constraints: :constraints,
    task_candidates: :capabilities,
    nondeterminism: :uncertainties,
    exclusions: :exclusions
  ]

  defp witnessed_by_graph(projection, %Ontology{triples: triples}) do
    rdf_type = Vocabulary.expand("rdf:type")
    description = Vocabulary.expand("schema:description")

    typed = fn field ->
      for %{predicate: ^rdf_type, object: object, subject: s} <- triples,
          object == Vocabulary.local(field),
          into: MapSet.new(),
          do: s
    end

    described = fn nodes ->
      for %{predicate: ^description, subject: s, object: o} <- triples,
          MapSet.member?(nodes, s),
          do: o
    end

    mismatch =
      Enum.find_value(@witnessed_text, fn {field, ir_field} ->
        witnessed = described.(typed.(ir_field))
        unless same_multiset?(Map.fetch!(projection, field), witnessed), do: {field, witnessed}
      end) ||
        objects_mismatch(projection.objects, typed.(:entities), triples, rdf_type) ||
        predicates_mismatch(projection.predicates, typed.(:relations), triples)

    case mismatch do
      nil ->
        {:ok, projection}

      {field, witnessed} ->
        error(:projection_not_witnessed_by_graph, %{
          field: field,
          projected: Map.fetch!(projection, field),
          witnessed: witnessed,
          source_graph_digest: projection.source_graph_digest
        })
    end
  end

  defp objects_mismatch(objects, entity_nodes, triples, rdf_type) do
    witnessed_ids =
      entity_nodes |> Enum.map(&String.replace_prefix(&1, Ontology.node_iri(""), ""))

    typed? = fn
      %{"id" => id, "type" => type} ->
        %{subject: Ontology.node_iri(id), predicate: rdf_type, object: Vocabulary.expand(type)} in triples

      %{"id" => _} ->
        true

      _ ->
        false
    end

    ids = if is_list(objects), do: Enum.map(objects, &(is_map(&1) && &1["id"])), else: nil

    unless same_multiset?(ids, witnessed_ids) and Enum.all?(objects, typed?),
      do: {:objects, witnessed_ids}
  end

  defp predicates_mismatch(predicates, relation_nodes, triples) do
    witnessed? = fn
      %{"subject" => s, "predicate" => p, "object" => o} when is_binary(s) and is_binary(p) ->
        Enum.any?(triples, fn t ->
          t.subject == Ontology.node_iri(s) and t.predicate == Vocabulary.expand(p) and
            t.object in [Ontology.node_iri(o), o]
        end)

      _ ->
        false
    end

    unless is_list(predicates) and length(predicates) == MapSet.size(relation_nodes) and
             Enum.all?(predicates, witnessed?),
           do: {:predicates, MapSet.size(relation_nodes)}
  end

  defp same_multiset?(projected, witnessed) when is_list(projected),
    do: Enum.sort(projected) == Enum.sort(witnessed)

  defp same_multiset?(_projected, _witnessed), do: false

  @doc """
  Tamper check alone, with no ontology in hand.

  Useful at a boundary that receives a projection back over the wire and has
  not (yet) loaded the graph: it can still refuse a self-inconsistent
  projection before spending anything on graph retrieval.
  """
  @spec verify_self(t()) :: {:ok, t()} | refusal()
  def verify_self(%__MODULE__{} = projection) do
    projection |> check_self() |> emit_verify(:self)
  end

  defp check_self(projection) do
    recomputed = content_digest(projection)

    cond do
      recomputed != projection.projection_digest ->
        error(:projection_manual_edit_not_canonical, %{
          recorded: projection.projection_digest,
          recomputed: recomputed
        })

      # `standing`/`authority` are structural constants outside the content
      # digest; an edit to them is an edit, not a promotion (SA2A-PROJECTION-003).
      {projection.standing, projection.authority} != {:derived, :none} ->
        error(:projection_manual_edit_not_canonical, %{
          forged_fence: %{standing: projection.standing, authority: projection.authority},
          required: %{standing: :derived, authority: :none}
        })

      true ->
        {:ok, projection}
    end
  end

  @doc false
  def __sa2a_refusal_codes__, do: %{projection_not_witnessed_by_graph: :refused_plan}

  defp fence(%PlanningIR{authority: :none}, %Ontology{standing: :admitted, authority: :none}),
    do: :ok

  defp fence(%PlanningIR{authority: authority}, _ontology) when authority != :none,
    do: error(:projection_authority_ceiling_violated, authority)

  defp fence(_planning, _ontology), do: error(:projection_requires_admitted_graph)

  defp same_graph(%PlanningIR{ontology_fingerprint: fingerprint}, %Ontology{
         fingerprint: fingerprint
       }),
       do: :ok

  defp same_graph(planning, ontology) do
    error(:projection_ontology_mismatch, %{
      planning_ir_expects: planning.ontology_fingerprint,
      ontology_is: ontology.fingerprint
    })
  end

  # RFC-SA2A-002 §12 attempt evidence, emitted where the S27 decision is made.
  defp emit_verify(result, mode) do
    :telemetry.execute([:ash_a2a, :semantic, :plan_projection, :verify], %{}, %{
      outcome: if(match?({:ok, _}, result), do: :verified, else: :refused),
      code: with({:error, %{code: code}} <- result, do: code, else: (_ -> nil)),
      mode: mode
    })

    result
  end

  defp error(code, detail \\ nil), do: {:error, %{code: code, detail: detail}}
end
