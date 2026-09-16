defmodule AshA2A.Chicago.Courts.SparqlFalsifiers do
  @moduledoc """
  RFC-SA2A-002 §49 SPARQL falsifier court (RFC-SA2A-001 S18.2, S18.4, S61).

    * Mandatory graph-global falsifiers are executed as independent queries
      over the admitted candidate closure by the real `praxis-graphlaw` engine
      inside the real `AshA2A.Semantic.AdmissionPipeline` (its
      `sparql_falsifiers` stage reads the engine's N3_DENIAL verdict, computed
      after Datalog materialisation). A positive mandatory falsifier -- asserted
      or only derivable -- must block admission; a negative one must not.
    * The fourteen normative S61 falsifiers are driven through the real
      `AshA2A.Semantic.FalsifierSuite.admit/1` gate.
    * Direct SPARQL Update against canonical admitted state (S18.4) is driven
      through the real `AshA2A.Semantic.FalsifierSuite.check_update/2`, with the
      Strict classification graph, including adversarial encodings that an
      independent SPARQL 1.1 implementation (rdflib 7.6.0 `translateUpdate`)
      reads as default-graph writes.

  Attempt evidence comes from the boundaries' own telemetry
  (`[:ash_a2a, :semantic, :admission, ...]`,
  `[:ash_a2a, :semantic, :falsifier_suite, :admit]`,
  `[:ash_a2a, :semantic, :sparql_update, :decision]`).
  """

  use AshA2A.Chicago.Court

  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Fixtures.LogicSparql, as: F
  alias AshA2A.Chicago.Ocel.Mapping
  alias AshA2A.GraphLaw
  alias AshA2A.Semantic.{AdmissionPipeline, FalsifierSuite}

  @court "SA2A-SPARQL"

  @impl true
  def id, do: @court
  @impl true
  def title, do: "SPARQL graph-global falsifiers and canonical-state update refusal"
  @impl true
  def gate, do: nil
  @impl true
  def profile, do: :core
  @impl true
  def rfc_sections, do: ["§12", "§49", "§100", "RFC-SA2A-001 S18.2", "S18.4", "S61"]

  @impl true
  def ocel_mappings do
    [
      Mapping.new!(
        event: [:ash_a2a, :semantic, :falsifier_suite, :admit],
        activity: "falsifier_suite.admit",
        source: __MODULE__,
        attributes: fn _m, meta ->
          Map.take(meta, [:outcome, :code, :tripped, :falsifier_count])
        end
      ),
      Mapping.new!(
        event: [:ash_a2a, :semantic, :sparql_update, :decision],
        activity: "sparql_update.decision",
        source: __MODULE__,
        attributes: fn _m, meta ->
          Map.take(meta, [:outcome, :mutating, :form, :code, :target_kind])
        end
      )
    ]
  end

  # --- declarations -----------------------------------------------------------

  @pipeline_attempt {:observed, "admission.stage", %{"stage" => "sparql_falsifiers"}}
  @pipeline_forbidden {:any,
                       [
                         {:observed, "admission.stop", %{"outcome" => "admitted"}},
                         {:observed, "admission.stage",
                          %{"stage" => "sparql_falsifiers", "outcome" => "ok"}}
                       ]}
  @pipeline_expected {:all,
                      [
                        {:observed, "admission.stage",
                         %{"stage" => "sparql_falsifiers", "outcome" => "ok"}},
                        {:observed, "admission.stop", %{"outcome" => "admitted"}}
                      ]}

  @update_attempt {:observed, "sparql_update.decision"}
  @update_forbidden {:observed, "sparql_update.decision", %{"outcome" => "admitted"}}

  @impl true
  def falsifiers do
    [
      declare(1, :negative,
        invariant: "A positive mandatory graph-global falsifier blocks admission",
        stimulus:
          "AdmissionPipeline.admit/2 of a lawful candidate whose graph asserts ex:z a ex:Forbidden under `{ ?s a ex:Forbidden } => false`",
        boundary: "AshA2A.Semantic.AdmissionPipeline sparql_falsifiers stage (engine N3_DENIAL)",
        forbidden_outcome: "sparql_falsifiers stage ok, or admission admitted",
        attempt_evidence: "admission.stage stage=sparql_falsifiers",
        survival_evidence:
          "admission.stage sparql_falsifiers outcome=ok or admission.stop admitted",
        guard: "AdmissionPipeline.run_stage(:sparql_falsifiers) require_dialect N3_DENIAL",
        failure_class: :admission_failure,
        attempt_predicate: @pipeline_attempt,
        outcome_predicate: @pipeline_forbidden
      ),
      declare(2, :positive_control,
        invariant:
          "Positive control for 001: the same candidate without the violating fact is admitted",
        stimulus: "AdmissionPipeline.admit/2 of the lawful candidate under the same falsifier",
        boundary: "AshA2A.Semantic.AdmissionPipeline",
        attempt_evidence: "admission.stage stage=sparql_falsifiers",
        survival_evidence: "sparql_falsifiers ok and admission.stop admitted",
        attempt_predicate: @pipeline_attempt,
        outcome_predicate: @pipeline_expected
      ),
      declare(3, :negative,
        invariant:
          "The falsifier is evaluated over the closure: a violation only derivable by a rule still blocks admission",
        stimulus:
          "AdmissionPipeline.admit/2 where `{ ?x ex:dependsOn ?y } => { ?y a ex:Forbidden }` derives the violation from the lawful graph",
        boundary:
          "AshA2A.Semantic.AdmissionPipeline sparql_falsifiers stage (engine N3_DENIAL after materialisation)",
        forbidden_outcome: "sparql_falsifiers stage ok, or admission admitted",
        attempt_evidence: "admission.stage stage=sparql_falsifiers",
        survival_evidence:
          "admission.stage sparql_falsifiers outcome=ok or admission.stop admitted",
        guard: "engine check_denials after materialize + AdmissionPipeline require_dialect",
        failure_class: :admission_failure,
        attempt_predicate: @pipeline_attempt,
        outcome_predicate: @pipeline_forbidden
      ),
      declare(4, :positive_control,
        invariant:
          "Positive control for 003: a rule whose premise is absent derives nothing and the candidate is admitted",
        stimulus:
          "AdmissionPipeline.admit/2 with `{ ?x ex:blockedBy ?y } => { ?y a ex:Forbidden }`",
        boundary: "AshA2A.Semantic.AdmissionPipeline",
        attempt_evidence: "admission.stage stage=sparql_falsifiers",
        survival_evidence: "sparql_falsifiers ok and admission.stop admitted",
        attempt_predicate: @pipeline_attempt,
        outcome_predicate: @pipeline_expected
      ),
      declare(5, :negative,
        invariant:
          "S61.1 mandatory falsifier: a consequence without an authority requirement blocks admission",
        stimulus:
          "FalsifierSuite.admit/1 of a graph with sa:hasConsequence and no sa:requiresAuthority",
        boundary: "AshA2A.Semantic.FalsifierSuite.admit/1",
        forbidden_outcome: "admitted",
        attempt_evidence: "falsifier_suite.admit observed",
        survival_evidence: "falsifier_suite.admit outcome=admitted",
        guard: "FalsifierSuite.trips?(:consequence_without_authority_requirement)",
        failure_class: :admission_failure,
        attempt_predicate: {:observed, "falsifier_suite.admit"},
        outcome_predicate: {:observed, "falsifier_suite.admit", %{"outcome" => "admitted"}}
      ),
      declare(6, :positive_control,
        invariant:
          "Positive control for 005: the consequence with its authority requirement is admitted",
        stimulus: "FalsifierSuite.admit/1 of the same graph plus sa:requiresAuthority",
        boundary: "AshA2A.Semantic.FalsifierSuite.admit/1",
        attempt_evidence: "falsifier_suite.admit observed",
        survival_evidence: "falsifier_suite.admit outcome=admitted",
        attempt_predicate: {:observed, "falsifier_suite.admit"},
        outcome_predicate: {:observed, "falsifier_suite.admit", %{"outcome" => "admitted"}}
      ),
      update_negative(7, :canonical_insert_data,
        invariant: "S18.4: INSERT DATA into a graph classified sa:CanonicalGraph is refused",
        guard: "FalsifierSuite.classify_targets/3"
      ),
      declare(8, :positive_control,
        invariant:
          "Positive control for the S18.4 family: INSERT DATA into a staging graph is admitted",
        stimulus: "FalsifierSuite.check_update/2 of #{inspect(F.update(:staging_insert_data))}",
        boundary: "AshA2A.Semantic.FalsifierSuite.check_update/2",
        attempt_evidence: "sparql_update.decision observed",
        survival_evidence: "sparql_update.decision outcome=admitted mutating=true",
        attempt_predicate: @update_attempt,
        outcome_predicate:
          {:observed, "sparql_update.decision", %{"outcome" => "admitted", "mutating" => "true"}}
      ),
      update_negative(9, :prefixed_canonical,
        invariant: "S18.4: a canonical write target spelled as a prefixed name is refused",
        guard: "FalsifierSuite unresolvable-operand rule"
      ),
      update_negative(10, :move_default,
        invariant: "S18.4: MOVE DEFAULT TO <staging> destroys the default graph and is refused",
        guard: "FalsifierSuite keyword-operand rule"
      ),
      update_negative(11, :escaped_keyword,
        invariant:
          "S18.4: a codepoint-escaped keyword (\\u0049NSERT DATA, SPARQL 1.1 §19.2) is still a default-graph write and is refused",
        guard: "FalsifierSuite codepoint-escape decoding before analysis"
      ),
      update_negative(12, :escaped_default_operand,
        invariant:
          "S18.4: a codepoint-escaped DEFAULT operand (MOVE \\u0044EFAULT TO <staging>) is refused",
        guard: "FalsifierSuite codepoint-escape decoding before analysis"
      ),
      update_negative(13, :mixed_quad_data,
        invariant:
          "S18.4: INSERT DATA mixing a staging GRAPH block with bare triples writes the default graph and is refused",
        guard:
          "FalsifierSuite template-body analysis (every top-level quad must sit in a GRAPH <iri> block)"
      ),
      update_negative(14, :mixed_modify_template,
        invariant:
          "S18.4: an INSERT template mixing a staging GRAPH block with a bare triple pattern is refused",
        guard: "FalsifierSuite template-body analysis"
      ),
      update_negative(15, :with_scope_leak,
        invariant:
          "S18.4: WITH <staging> scopes only its own operation; a later bare template in the same request is refused",
        guard: "FalsifierSuite per-operation WITH scoping"
      ),
      update_negative(16, :comment_masked,
        invariant: "S18.4: a staging IRI inside a comment cannot authorise a default-graph write",
        guard: "FalsifierSuite scrub_update/1 before rule analysis"
      ),
      update_negative(18, :long_literal_desync,
        invariant:
          "S18.4: triple-quoted literals holding quotes and braces cannot make bare default-graph triples look scoped to staging",
        guard: "FalsifierSuite scrub_update/1 long-string state"
      ),
      declare(17, :positive_control,
        invariant:
          "Positive control for 015: a single WITH <staging> DELETE/INSERT operation stays admitted",
        stimulus: "FalsifierSuite.check_update/2 of #{inspect(F.update(:staging_modify_with))}",
        boundary: "AshA2A.Semantic.FalsifierSuite.check_update/2",
        attempt_evidence: "sparql_update.decision observed",
        survival_evidence: "sparql_update.decision outcome=admitted mutating=true",
        attempt_predicate: @update_attempt,
        outcome_predicate:
          {:observed, "sparql_update.decision", %{"outcome" => "admitted", "mutating" => "true"}}
      )
    ]
  end

  defp update_negative(n, attack, fields) do
    declare(
      n,
      :negative,
      Keyword.merge(
        [
          stimulus: "FalsifierSuite.check_update/2 of #{inspect(F.update(attack))}",
          boundary: "AshA2A.Semantic.FalsifierSuite.check_update/2 (Strict)",
          forbidden_outcome: "the update is admitted",
          attempt_evidence: "sparql_update.decision observed",
          survival_evidence: "sparql_update.decision outcome=admitted",
          failure_class: :admission_failure,
          attempt_predicate: @update_attempt,
          outcome_predicate: @update_forbidden,
          tags: [:sparql_update, attack]
        ],
        fields
      )
    )
  end

  defp fid(n), do: "#{@court}-" <> String.pad_leading(Integer.to_string(n), 3, "0")

  defp declare(n, kind, fields) do
    Falsifier.new!([id: fid(n), court_id: @court, kind: kind, rfc_sections: ["§49"]] ++ fields)
  end

  # --- execution --------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    fs = Map.new(falsifiers(), &{&1.id, &1})
    f = fn n -> Map.fetch!(fs, fid(n)) end

    pipeline_opts = [wasm_path: GraphLaw.wasm_path()]

    pipeline =
      case AshA2A.GraphLaw.Wasm.availability(pipeline_opts) do
        :ok ->
          # The host's admitted pipeline law (RFC-SA2A-001 S20/S21).
          pipeline_opts =
            Keyword.put(
              pipeline_opts,
              :root_manifest,
              F.law_manifest!(Path.join(ctx.evidence_dir, "sa2a-sparql"))
            )

          [
            pipeline_negative(
              ctx,
              f.(1),
              F.candidate(graph_ttl: F.graph_with_forbidden()),
              pipeline_opts
            ),
            pipeline_positive(ctx, f.(2), F.candidate(), pipeline_opts),
            pipeline_negative(
              ctx,
              f.(3),
              F.candidate(falsifiers: F.falsifiers(:derived)),
              pipeline_opts
            ),
            pipeline_positive(
              ctx,
              f.(4),
              F.candidate(falsifiers: F.falsifiers(:derived_absent)),
              pipeline_opts
            )
          ]

        {:error, reason} ->
          for n <- 1..4,
              do: Result.blocked(f.(n), "GraphLaw engine host unavailable: #{inspect(reason)}")
      end

    graph = F.update_classification()

    pipeline ++
      [
        suite(ctx, f.(5), F.s61_graph(:consequence_without_authority)),
        suite(ctx, f.(6), F.s61_graph(:consequence_with_authority)),
        update(ctx, f.(7), graph, :canonical_insert_data),
        update(ctx, f.(8), graph, :staging_insert_data),
        update(ctx, f.(9), graph, :prefixed_canonical),
        update(ctx, f.(10), graph, :move_default),
        update(ctx, f.(11), graph, :escaped_keyword),
        update(ctx, f.(12), graph, :escaped_default_operand),
        update(ctx, f.(13), graph, :mixed_quad_data),
        update(ctx, f.(14), graph, :mixed_modify_template),
        update(ctx, f.(15), graph, :with_scope_leak),
        update(ctx, f.(16), graph, :comment_masked),
        update(ctx, f.(17), graph, :staging_modify_with),
        update(ctx, f.(18), graph, :long_literal_desync)
      ]
  end

  defp pipeline_negative(ctx, falsifier, candidate, opts) do
    reply = Context.stimulus(ctx, falsifier, fn -> AdmissionPipeline.admit(candidate, opts) end)

    Result.negative(falsifier,
      attempt_observed?:
        seen?(ctx, falsifier, "admission.stage", %{"stage" => "sparql_falsifiers"}),
      forbidden_outcome_observed?:
        match?({:ok, _}, reply) or
          seen?(ctx, falsifier, "admission.stage", %{
            "stage" => "sparql_falsifiers",
            "outcome" => "ok"
          }),
      evidence: pipeline_evidence(reply)
    )
  end

  defp pipeline_positive(ctx, falsifier, candidate, opts) do
    reply = Context.stimulus(ctx, falsifier, fn -> AdmissionPipeline.admit(candidate, opts) end)

    Result.positive(falsifier,
      attempt_observed?:
        seen?(ctx, falsifier, "admission.stage", %{"stage" => "sparql_falsifiers"}),
      expected_outcome_observed?:
        match?({:ok, %{standing: :admitted, authority: :none}}, reply) and
          seen?(ctx, falsifier, "admission.stage", %{
            "stage" => "sparql_falsifiers",
            "outcome" => "ok"
          }),
      evidence: pipeline_evidence(reply)
    )
  end

  defp pipeline_evidence({:ok, result}),
    do: %{"standing" => result.standing, "admission_digest" => result.admission_digest}

  defp pipeline_evidence({:error, refusal}),
    do: %{"stage" => refusal.stage, "code" => refusal.code, "determinacy" => refusal.determinacy}

  defp suite(ctx, falsifier, graph) do
    reply = Context.stimulus(ctx, falsifier, fn -> FalsifierSuite.admit(graph) end)
    attempt = seen?(ctx, falsifier, "falsifier_suite.admit")

    evidence =
      case reply do
        :ok -> %{"outcome" => "admitted"}
        {:error, %{detail: detail}} -> %{"outcome" => "refused", "tripped" => detail.falsifiers}
      end

    case falsifier.kind do
      :negative ->
        Result.negative(falsifier,
          attempt_observed?: attempt,
          forbidden_outcome_observed?: reply == :ok,
          evidence: evidence
        )

      :positive_control ->
        Result.positive(falsifier,
          attempt_observed?: attempt,
          expected_outcome_observed?: reply == :ok,
          evidence: evidence
        )
    end
  end

  defp update(ctx, falsifier, graph, attack) do
    text = F.update(attack)
    reply = Context.stimulus(ctx, falsifier, fn -> FalsifierSuite.check_update(graph, text) end)
    attempt = seen?(ctx, falsifier, "sparql_update.decision")

    evidence =
      case reply do
        :ok ->
          %{"update" => text, "outcome" => "admitted"}

        {:error, %{code: code, detail: detail}} ->
          %{"update" => text, "code" => code, "reason" => detail.reason}
      end

    case falsifier.kind do
      :negative ->
        Result.negative(falsifier,
          attempt_observed?: attempt,
          forbidden_outcome_observed?: reply == :ok,
          evidence: evidence
        )

      :positive_control ->
        Result.positive(falsifier,
          attempt_observed?: attempt,
          expected_outcome_observed?:
            reply == :ok and
              seen?(ctx, falsifier, "sparql_update.decision", %{"mutating" => "true"}),
          evidence: evidence
        )
    end
  end

  defp seen?(ctx, falsifier, activity, attrs \\ %{}) do
    ctx
    |> Context.observed(falsifier)
    |> Enum.any?(fn record ->
      record.activity == activity and
        Enum.all?(attrs, fn {k, v} -> to_string(Map.get(record.attributes, k)) == to_string(v) end)
    end)
  end
end
