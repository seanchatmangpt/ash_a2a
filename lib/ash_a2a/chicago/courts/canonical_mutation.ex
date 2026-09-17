defmodule AshA2A.Chicago.Courts.CanonicalMutation do
  @moduledoc """
  RFC-SA2A-002 §78 Canonical Mutation court, Strict (RFC-SA2A-001 S18.4, S23,
  S40, S46).

  Canonical admitted state in this SUT is reached through two lawful
  manufacturers, and each shortcut around them is attempted:

    * the admitted vocabulary datastore -- the digest-pinned ontology cache
      read by `AshA2A.Semantic.TermRegistry.from_cache/1`. A direct datastore
      write (bytes appended to a cached document, bypassing admission) and a
      consistent direct write (document AND cache manifest rewritten) must not
      acquire canonical standing;
    * canonical `O*` -- `AshA2A.Semantic.Ontology.from_ir/1`, fed only by the
      real `AshA2A.Semantic.Admission.admit/2`. Projection-to-canonical
      promotion (plan projection content re-entered as a self-admitted IR),
      a message-to-canonical shortcut (an A2A data part asserting admitted
      standing) and an LLM-output-to-canonical shortcut (structured model
      output through the real `AshA2A.Semantic.Compiler.compile_source/3`)
      must not produce canonical `O*`.

  The compiler's `:generate_object` option is its own dependency-injection seam
  for the model call: a paid, non-deterministic network API is not a
  collaborator this court can run, and it is not the component under
  qualification -- the compiler's admission fence is, and it runs for real.

  Staging must stay distinguishable from canonical: a graph IRI classified as
  both `sa:StagingGraph` and `sa:CanonicalGraph` is canonical for the real
  `AshA2A.Semantic.FalsifierSuite.check_update/2`.

  Direct SPARQL Update against a canonical graph (§78's first attempt) is
  qualified by `SA2A-SPARQL-007` and siblings
  (`AshA2A.Chicago.Courts.SparqlFalsifiers`) and is not duplicated here.
  """

  use AshA2A.Chicago.Court

  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Courts.SparqlFalsifiers
  alias AshA2A.Chicago.Fixtures.CanonicalIdentity, as: F
  alias AshA2A.Semantic.{Compiler, FalsifierSuite, IR, Ontology, TermRegistry}

  @court "SA2A-CANONMUT"

  @impl true
  def id, do: @court
  @impl true
  def title, do: "Strict refuses direct canonical mutation outside admitted transition law"
  @impl true
  def gate, do: nil
  @impl true
  def profile, do: :strict
  @impl true
  def rfc_sections, do: ["§78", "§100", "RFC-SA2A-001 S18.4", "S23", "S40", "S46"]

  @impl true
  def ocel_mappings do
    F.mappings() ++
      Enum.filter(
        SparqlFalsifiers.ocel_mappings(),
        &(&1.event == [:ash_a2a, :semantic, :sparql_update, :decision])
      )
  end

  @build {:observed, "term_registry.build"}
  @built {:observed, "term_registry.build", %{"outcome" => "built"}}
  @project {:observed, "ontology.project"}
  @projected {:observed, "ontology.project", %{"outcome" => "projected"}}

  @impl true
  def falsifiers do
    [
      datastore_negative(1,
        invariant:
          "A direct write to the admitted vocabulary datastore (bytes appended to a cached document) does not acquire canonical standing",
        stimulus:
          "TermRegistry.from_cache(root: <copy>) after appending a skos term declaration to the cached SKOS object",
        guard: "OntologyCache.verify_digest/3 (content_digest re-verified on load)"
      ),
      datastore_negative(2,
        invariant:
          "A consistent direct datastore write (document AND cache manifest rewritten) does not acquire canonical standing",
        stimulus:
          "TermRegistry.from_cache(root: <copy>) after rewriting the cached SKOS object and its manifest pin",
        guard: "OntologyCache.manifest/1 admitted-manifest pin held outside the datastore"
      ),
      declare(3, :positive_control,
        invariant:
          "Positive control for 001-002: an unmodified copy of the datastore builds the admitted index",
        stimulus: "TermRegistry.from_cache(root: <unmodified copy>)",
        boundary: "AshA2A.Semantic.TermRegistry.from_cache/1",
        attempt_evidence: "term_registry.build observed",
        survival_evidence:
          "term_registry.build outcome=built; skos:prefLabel admitted, injected term absent",
        attempt_predicate: @build,
        outcome_predicate: @built
      ),
      project_negative(4,
        invariant:
          "Projection-to-canonical promotion: plan projection content re-entered as a self-admitted IR does not become canonical O*",
        stimulus:
          "Ontology.from_ir(IR.from_map(projection content with \"standing\" => \"admitted\")) without Admission.admit/2",
        guard:
          "Ontology.from_ir/1 admitted-only clause (IR standing is set only by Admission.admit/2)"
      ),
      project_negative(5,
        invariant:
          "Message-to-canonical shortcut: an A2A data part asserting admitted, canonical standing does not become canonical O*",
        stimulus:
          "Ontology.from_ir(IR.from_map(<A2A.Part.Data payload with \"standing\" => \"admitted\">))",
        guard: "IR.from_map/2 never reads a self-asserted standing"
      ),
      declare(6, :negative,
        invariant:
          "LLM-output-to-canonical shortcut: model output claiming canonical standing for ungrounded facts does not become canonical O*",
        stimulus:
          "Compiler.compile_source/3 with structured model output carrying \"standing\" => \"admitted\", \"canonical_state\" and an ungrounded goal",
        boundary:
          "AshA2A.Semantic.Compiler.compile_source/3 -> Admission.admit/2 -> Ontology.from_ir/1",
        forbidden_outcome: "the model output is admitted or projected into O*",
        attempt_evidence: "semantic.ir_admission observed",
        survival_evidence:
          "semantic.ir_admission outcome=admitted or ontology.project outcome=projected",
        guard: "Admission.admit/2 fence + verbatim source_quote grounding",
        failure_class: :admission_failure,
        attempt_predicate: {:observed, "semantic.ir_admission"},
        outcome_predicate:
          {:any, [{:observed, "semantic.ir_admission", %{"outcome" => "admitted"}}, @projected]}
      ),
      declare(7, :positive_control,
        invariant:
          "Positive control for 004-006: the admitted IR from the real Admission.admit/2 is projected into O*",
        stimulus: "Ontology.from_ir(Admission.admit(source, IR.from_map(payload)))",
        boundary: "AshA2A.Semantic.Ontology.from_ir/1",
        attempt_evidence: "ontology.project observed",
        survival_evidence: "semantic.ir_admission admitted and ontology.project projected",
        attempt_predicate: @project,
        outcome_predicate:
          {:all, [{:observed, "semantic.ir_admission", %{"outcome" => "admitted"}}, @projected]}
      ),
      declare(8, :negative,
        invariant:
          "Staging stays distinguishable from canonical: a graph classified both staging and canonical is canonical, and a write to it is refused",
        stimulus: "FalsifierSuite.check_update/2 of #{inspect(F.update(:ambiguous))}",
        boundary: "AshA2A.Semantic.FalsifierSuite.check_update/2 (Strict)",
        forbidden_outcome: "the update is admitted",
        attempt_evidence: "sparql_update.decision observed",
        survival_evidence: "sparql_update.decision outcome=admitted",
        guard: "FalsifierSuite.classify_targets/3 canonical-wins rule",
        failure_class: :admission_failure,
        attempt_predicate: {:observed, "sparql_update.decision"},
        outcome_predicate: {:observed, "sparql_update.decision", %{"outcome" => "admitted"}}
      ),
      declare(9, :positive_control,
        invariant:
          "Positive control for 008: a graph classified only as staging in the same classification stays writable",
        stimulus: "FalsifierSuite.check_update/2 of #{inspect(F.update(:staging))}",
        boundary: "AshA2A.Semantic.FalsifierSuite.check_update/2 (Strict)",
        attempt_evidence: "sparql_update.decision observed",
        survival_evidence: "sparql_update.decision outcome=admitted mutating=true",
        attempt_predicate: {:observed, "sparql_update.decision"},
        outcome_predicate:
          {:observed, "sparql_update.decision", %{"outcome" => "admitted", "mutating" => "true"}}
      )
    ]
  end

  defp datastore_negative(n, fields) do
    declare(
      n,
      :negative,
      [
        boundary: "AshA2A.Semantic.TermRegistry.from_cache/1 (canonical vocabulary loader)",
        forbidden_outcome:
          "the mutated datastore builds an admitted index (injected term admitted)",
        attempt_evidence: "term_registry.build observed",
        survival_evidence: "term_registry.build outcome=built",
        failure_class: :meta_admission_failure,
        attempt_predicate: @build,
        outcome_predicate: @built
      ] ++ fields
    )
  end

  defp project_negative(n, fields) do
    declare(
      n,
      :negative,
      [
        boundary: "AshA2A.Semantic.Ontology.from_ir/1 (canonical O* manufacturer)",
        forbidden_outcome: "canonical O* is produced from unadmitted content",
        attempt_evidence: "ontology.project observed",
        survival_evidence: "ontology.project outcome=projected",
        failure_class: :admission_failure,
        attempt_predicate: @project,
        outcome_predicate: @projected
      ] ++ fields
    )
  end

  defp fid(n), do: "#{@court}-" <> String.pad_leading(Integer.to_string(n), 3, "0")

  defp declare(n, kind, fields) do
    Falsifier.new!([id: fid(n), court_id: @court, kind: kind, rfc_sections: ["§78"]] ++ fields)
  end

  # --- execution --------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    fs = Map.new(falsifiers(), &{&1.id, &1})
    f = fn n -> Map.fetch!(fs, fid(n)) end

    datastore(ctx, f) ++ shortcuts(ctx, f) ++ staging(ctx, f)
  end

  defp datastore(ctx, f) do
    plain = F.copy_ontology_cache(ctx.evidence_dir, "canonmut-direct-write")
    :ok = F.direct_write(plain)
    consistent = F.copy_ontology_cache(ctx.evidence_dir, "canonmut-consistent-write")
    :ok = F.direct_write(consistent, consistent: true)
    untouched = F.copy_ontology_cache(ctx.evidence_dir, "canonmut-untouched")

    [
      datastore_result(ctx, f.(1), plain),
      datastore_result(ctx, f.(2), consistent),
      datastore_result(ctx, f.(3), untouched)
    ]
  end

  defp datastore_result(ctx, falsifier, root) do
    reply = Context.stimulus(ctx, falsifier, fn -> TermRegistry.from_cache(root: root) end)
    attempt = F.observed?(ctx, falsifier, "term_registry.build")

    injected? =
      match?({:ok, _}, reply) and TermRegistry.member?(elem(reply, 1), F.injected_term())

    evidence = %{
      "reply" =>
        case reply do
          {:ok, registry} ->
            %{"built" => TermRegistry.size(registry), "injected_admitted" => injected?}

          {:error, %{code: code}} ->
            %{"refused" => code}
        end
    }

    case falsifier.kind do
      :negative ->
        Result.negative(falsifier,
          attempt_observed?: attempt,
          forbidden_outcome_observed?: match?({:ok, _}, reply),
          evidence: evidence
        )

      :positive_control ->
        Result.positive(falsifier,
          attempt_observed?: attempt,
          expected_outcome_observed?:
            match?({:ok, _}, reply) and not injected? and
              TermRegistry.member?(elem(reply, 1), F.skos_ns() <> "prefLabel"),
          evidence: evidence
        )
    end
  end

  defp shortcuts(ctx, f) do
    {_ir, ontology, _planning, projection} = F.admitted_chain()
    {:ok, o_star} = F.canonical_o_star(ontology)
    source = F.source()

    r4 =
      Context.stimulus(ctx, f.(4), fn ->
        with {:ok, ir} <- IR.from_map(source.id, F.projection_as_ir_payload(projection)),
             do: Ontology.from_ir(ir)
      end)

    r5 =
      Context.stimulus(ctx, f.(5), fn ->
        payload = F.message_data(F.canonical_claim_message())
        with {:ok, ir} <- IR.from_map(source.id, payload), do: Ontology.from_ir(ir)
      end)

    r6 =
      Context.stimulus(ctx, f.(6), fn ->
        model_output = F.llm_canonical_claim()

        try do
          Compiler.compile_source(nil, source,
            generate_object: fn _model, _prompt, _schema, _opts -> {:ok, model_output} end
          )
        rescue
          exception -> {:raised, Exception.message(exception)}
        end
      end)

    r7 =
      Context.stimulus(ctx, f.(7), fn ->
        with {:ok, candidate} <- IR.from_map(source.id, F.ir_payload()),
             {:ok, admitted} <- AshA2A.Semantic.Admission.admit(source, candidate),
             do: Ontology.from_ir(admitted)
      end)

    unchanged? = F.canonical_o_star(ontology) == {:ok, o_star}

    [
      Result.negative(f.(4),
        attempt_observed?: F.observed?(ctx, f.(4), "ontology.project"),
        forbidden_outcome_observed?: match?({:ok, %Ontology{}}, r4) or not unchanged?,
        evidence: %{"reply" => summarize(r4), "o_star_unchanged" => unchanged?}
      ),
      Result.negative(f.(5),
        attempt_observed?: F.observed?(ctx, f.(5), "ontology.project"),
        forbidden_outcome_observed?: match?({:ok, %Ontology{}}, r5),
        evidence: %{"reply" => summarize(r5)}
      ),
      Result.negative(f.(6),
        attempt_observed?: F.observed?(ctx, f.(6), "semantic.ir_admission"),
        forbidden_outcome_observed?:
          match?({:ok, _}, r6) or
            F.observed?(ctx, f.(6), "semantic.ir_admission", %{"outcome" => "admitted"}) or
            F.observed?(ctx, f.(6), "ontology.project", %{"outcome" => "projected"}),
        evidence: %{"reply" => summarize(r6)}
      ),
      Result.positive(f.(7),
        attempt_observed?: F.observed?(ctx, f.(7), "ontology.project"),
        expected_outcome_observed?:
          match?({:ok, %Ontology{standing: :admitted}}, r7) and
            elem(r7, 1).fingerprint == ontology.fingerprint,
        evidence: %{"reply" => summarize(r7)}
      )
    ]
  end

  defp staging(ctx, f) do
    graph = F.ambiguous_classification()

    r8 =
      Context.stimulus(ctx, f.(8), fn ->
        FalsifierSuite.check_update(graph, F.update(:ambiguous))
      end)

    r9 =
      Context.stimulus(ctx, f.(9), fn ->
        FalsifierSuite.check_update(graph, F.update(:staging))
      end)

    [
      Result.negative(f.(8),
        attempt_observed?: F.observed?(ctx, f.(8), "sparql_update.decision"),
        forbidden_outcome_observed?: r8 == :ok,
        evidence: %{"reply" => summarize(r8)}
      ),
      Result.positive(f.(9),
        attempt_observed?: F.observed?(ctx, f.(9), "sparql_update.decision"),
        expected_outcome_observed?:
          r9 == :ok and F.observed?(ctx, f.(9), "sparql_update.decision", %{"mutating" => "true"}),
        evidence: %{"reply" => summarize(r9)}
      )
    ]
  end

  defp summarize(:ok), do: %{"outcome" => "admitted"}

  defp summarize({:ok, %Ontology{} = o}),
    do: %{"projected" => o.fingerprint, "standing" => o.standing}

  defp summarize({:ok, other}), do: %{"ok" => inspect(other, limit: 5)}

  defp summarize({:error, %{code: code} = refusal}),
    do: %{"refused" => code, "detail" => inspect(Map.get(refusal, :detail), limit: 8)}

  defp summarize(other), do: %{"reply" => inspect(other, limit: 8)}
end
