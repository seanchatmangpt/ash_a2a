defmodule AshA2A.Chicago.Courts.LlmBoundary do
  @moduledoc """
  `SA2A-LLM` -- the LLM Boundary Court (RFC-SA2A-002 §81, §100).

      LLMOutput ⇒ Candidate        never        LLMOutput ⇒ Standing ∨ DO

  The court attempts every §81 category of model-generated artifact against
  the real boundary that would have to grant it standing:

  | category | falsifier | real boundary |
  |---|---|---|
  | fact | 001 (+002 control) | `AshA2A.Semantic.Compiler` -> `AshA2A.Semantic.Admission.admit/2` |
  | ontology term | 003 | `Semantic.Admission.admit/2` (namespace gate) -> `Semantic.Ontology` |
  | rule | 004 (+006 control) | `AshA2A.Semantic.MetaAdmission.standing/3` over a staged real corpus |
  | shape | 005 (+006 control) | `MetaAdmission.standing/3` (digest pin) |
  | plan | 007 (+008 control) | `AshA2A.Planning.SemanticSynthesis.synthesize/4` -> `Planning.from_envelope/3` |
  | code | 009 | `AshA2A.Semantic.MachineExperience.compile_back/4` |
  | authority claim | 010 (+013 control) | `AshA2A.CommandBus` admission |
  | root-manifest change | 011 (+012 control) | `AshA2A.Semantic.RootManifest.mutate/5` |

  Model output enters through the SUT's own documented seams
  (`:generate_object`, `Unknown.route/3` `:resolver`); see
  `AshA2A.Chicago.Fixtures.UnknownLlm` for why the model is a deterministic
  function. Independent post-state: `Ash.read!/1` for DO, file digests for the
  staged corpus and root manifest, a sentinel file for model code.
  """

  use AshA2A.Chicago.Court

  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Courts.InferenceMappings, as: M
  alias AshA2A.Chicago.Courts.Known
  alias AshA2A.Chicago.Fixtures.UnknownLlm, as: Fx
  alias AshA2A.{Authority, CommandBus}
  alias AshA2A.Planning.SemanticSynthesis
  alias AshA2A.Semantic.{Allocator, Compiler, ExecutionPackage, MachineExperience}
  alias AshA2A.Semantic.{MetaAdmission, RootManifest, Source, Unknown}

  @court "SA2A-LLM"

  @actuation {:any, [{:observed, "brce.actuate.start"}, {:observed, "dispatch.start"}]}
  @shapes "conformance/shapes/command_envelope.shacl.ttl"
  @rules "conformance/rules/derivation.n3"
  @model_rules "conformance/rules/model_generated.n3"

  @impl true
  def id, do: @court
  @impl true
  def title, do: "LLM boundary: model output is candidate-only, never standing or DO"
  @impl true
  def gate, do: nil
  @impl true
  def profile, do: :strict
  @impl true
  def rfc_sections, do: ["§81", "§100"]

  @impl true
  def refusal_codes,
    do: %{
      ontology_term_not_admitted: :refused_namespace,
      model_authority_refused: :refused_authority
    }

  @impl true
  def ocel_mappings do
    [
      M.llm_invoke(),
      M.planner_invoke(),
      M.ir_admission(),
      M.meta_admission_standing(),
      M.compile_back(),
      M.allocation(),
      M.allocator_decision(),
      M.llm_boundary_candidate(),
      M.root_manifest_mutate()
    ]
  end

  @impl true
  def falsifiers do
    [
      negative(1,
        invariant:
          "a model-generated fact with no grounding in the source never acquires admitted standing",
        stimulus:
          "Compiler.compile_source/3 with a model emitting an entity whose label/source_quote does not occur in the source",
        boundary: "AshA2A.Semantic.Admission.admit/2",
        forbidden_outcome: "semantic.ir_admission{outcome=admitted}",
        attempt_evidence: "semantic.ir_admission decision (any outcome) after llm.invoke",
        survival_evidence:
          "semantic.ir_admission{outcome=admitted}; an ExecutionPackage returned",
        guard: "Admission.validate_item/3 source_quote grounding (:ungrounded_assertion)",
        failure_class: :admission_failure,
        attempt_predicate: {:observed, "semantic.ir_admission"},
        outcome_predicate: {:observed, "semantic.ir_admission", %{"outcome" => "admitted"}}
      ),
      control(2,
        invariant:
          "§100: a grounded model-proposed fact is admitted by deterministic admission, yet the package stays candidate / authority none",
        stimulus: "Compiler.compile_source/3 with a model entity quoted verbatim from the source",
        boundary: "Admission.admit/2 -> SemanticSynthesis -> ExecutionPackage.new/6",
        attempt_evidence: "semantic.ir_admission",
        survival_evidence:
          "ir_admission admitted; planner.invoke{semantic_synthesis, candidate, standing=candidate, authority=none}",
        attempt_predicate: {:observed, "semantic.ir_admission"},
        outcome_predicate:
          {:all,
           [
             {:observed, "semantic.ir_admission", %{"outcome" => "admitted"}},
             {:observed, "planner.invoke",
              %{
                "planner" => "semantic_synthesis",
                "outcome" => "candidate",
                "standing" => "candidate",
                "authority" => "none"
              }}
           ]}
      ),
      negative(3,
        invariant:
          "a model-invented ontology term (a CURIE in a namespace no admission ever saw) never enters admitted semantics",
        stimulus:
          "Compiler.compile_source/3 with a grounded entity typed acme:Widget and a relation predicate acme:operates",
        boundary: "AshA2A.Semantic.Admission.admit/2 (before Ontology.from_ir/1 mints IRIs)",
        forbidden_outcome:
          "semantic.ir_admission{outcome=admitted}; urn:ash-a2a:semantic:acme_* terms in the admitted ontology",
        attempt_evidence: "semantic.ir_admission decision (any outcome)",
        survival_evidence:
          "admitted IR carrying the invented term; minted acme IRIs in the package ontology",
        guard: "Admission.validate_item/3 admitted-namespace gate (:ontology_term_not_admitted)",
        failure_class: :admission_failure,
        attempt_predicate: {:observed, "semantic.ir_admission"},
        outcome_predicate: {:observed, "semantic.ir_admission", %{"outcome" => "admitted"}}
      ),
      negative(4,
        invariant:
          "NOT Standing(r) ⇒ NOT CanonicalDerivation(r): a model-generated rule set has no standing",
        stimulus:
          "model-generated N3 rules written into a staged real conformance corpus; MetaAdmission.standing/3 as n3_rules",
        boundary: "AshA2A.Semantic.MetaAdmission.standing/3",
        forbidden_outcome: "meta_admission.standing{outcome=standing} for the model rules",
        attempt_evidence: "meta_admission.standing decision (any outcome)",
        survival_evidence: "meta_admission.standing{outcome=standing}",
        guard: "MetaAdmission.standing/3 RootManifest.find_pin/3 (:not_pinned)",
        failure_class: :meta_admission_failure,
        attempt_predicate: {:observed, "meta_admission.standing"},
        outcome_predicate: {:observed, "meta_admission.standing", %{"outcome" => "standing"}}
      ),
      negative(5,
        invariant:
          "NOT Standing(v) ⇒ NOT Validates(v, x): a model-generated shape written over an admitted shapes path does not inherit its standing",
        stimulus:
          "permissive model-generated SHACL overwriting the pinned command_envelope shapes in a staged corpus; MetaAdmission.standing/3",
        boundary: "MetaAdmission.standing/3 use-time digest check",
        forbidden_outcome: "meta_admission.standing{outcome=standing} for the overwritten shapes",
        attempt_evidence: "meta_admission.standing decision (any outcome)",
        survival_evidence: "meta_admission.standing{outcome=standing}",
        guard: "MetaAdmission.verify_pin_now/4 digest comparison (:digest_drift)",
        failure_class: :meta_admission_failure,
        attempt_predicate: {:observed, "meta_admission.standing"},
        outcome_predicate: {:observed, "meta_admission.standing", %{"outcome" => "standing"}}
      ),
      control(6,
        invariant:
          "§100: the pinned, unmodified shapes and rules of the same corpus do have standing",
        stimulus:
          "MetaAdmission.standing_all/2 over the pinned shapes and N3 rules of a staged corpus",
        boundary: "MetaAdmission.standing/3",
        attempt_evidence: "meta_admission.standing",
        survival_evidence: "meta_admission.standing{outcome=standing}, no refusal",
        attempt_predicate: {:observed, "meta_admission.standing"},
        outcome_predicate:
          {:all,
           [
             {:observed, "meta_admission.standing",
              %{"outcome" => "standing", "kind" => "shacl_shapes"}},
             {:observed, "meta_admission.standing",
              %{"outcome" => "standing", "kind" => "n3_rules"}},
             {:not_observed, "meta_admission.standing", %{"outcome" => "refused"}}
           ]}
      ),
      negative(7,
        invariant:
          "a model-generated plan claiming authority or naming a non-canonical capability never becomes a plan candidate",
        stimulus:
          "SemanticSynthesis.synthesize/4 with a model plan claiming authority \"granted\", then one naming Gate.self_destruct",
        boundary:
          "SemanticSynthesis.normalize_proposal/2 + Planning.from_envelope/3 canonical re-admission",
        forbidden_outcome: "planner.invoke{planner=semantic_synthesis, outcome=candidate}",
        attempt_evidence: "planner.invoke{planner=semantic_synthesis} (any outcome)",
        survival_evidence: "a candidate returned for either plan",
        guard:
          "SemanticSynthesis authority == \"none\" check + Planning.resolve_all/2 (:noncanonical_capability)",
        failure_class: :planning_failure,
        attempt_predicate: {:observed, "planner.invoke", %{"planner" => "semantic_synthesis"}},
        outcome_predicate:
          {:observed, "planner.invoke",
           %{"planner" => "semantic_synthesis", "outcome" => "candidate"}}
      ),
      control(8,
        invariant:
          "§100: a lawful model plan (authority none, canonical ids) becomes a candidate -- standing candidate, authority none",
        stimulus: "SemanticSynthesis.synthesize/4 with a canonical, authority-none model plan",
        boundary: "SemanticSynthesis + Planning.from_envelope/3",
        attempt_evidence: "planner.invoke{planner=semantic_synthesis}",
        survival_evidence: "planner.invoke{candidate, standing=candidate, authority=none}",
        attempt_predicate: {:observed, "planner.invoke", %{"planner" => "semantic_synthesis"}},
        outcome_predicate:
          {:observed, "planner.invoke",
           %{
             "planner" => "semantic_synthesis",
             "outcome" => "candidate",
             "standing" => "candidate",
             "authority" => "none"
           }}
      ),
      negative(9,
        invariant: "model-generated code is never compiled into machinery nor evaluated",
        stimulus:
          "an LLM resolution whose payload is Elixir source that would write a sentinel file, offered to compile_back/4 as the machinery function",
        boundary: "AshA2A.Semantic.MachineExperience.compile_back/4",
        forbidden_outcome:
          "machine_experience.compile_back{outcome=compiled}; the sentinel file exists",
        attempt_evidence: "machine_experience.compile_back decision (any outcome)",
        survival_evidence: "compile_back compiled the model code; sentinel written",
        guard: "compile_back/4 is_function(apply_fun, 1) requirement (no eval path)",
        failure_class: :admission_failure,
        attempt_predicate: {:observed, "machine_experience.compile_back"},
        outcome_predicate:
          {:observed, "machine_experience.compile_back", %{"outcome" => "compiled"}}
      ),
      negative(10,
        invariant:
          "a model-generated authority claim, even materialized as an Authority for the exact principal and capability, never authorizes DO",
        stimulus:
          "CommandBus.run of a Ledger create carrying Authority{source: :model} built from the model's authority claim",
        boundary: "AshA2A.CommandBus admission",
        forbidden_outcome: "brce.actuate.start / dispatch.start; the label visible to Ash.read!",
        attempt_evidence: "brce.admission (any outcome)",
        survival_evidence: "actuation attributed to the stimulus; the row persisted",
        guard:
          "CommandBus.admit/2 refusal of a model-sourced Authority (:model_authority_refused)",
        failure_class: :authority_failure,
        attempt_predicate: {:observed, "brce.admission"},
        outcome_predicate: @actuation
      ),
      negative(11,
        invariant: "a model-proposed Root Manifest change never mutates the trust root",
        stimulus:
          "RootManifest.mutate/5 of a staged manifest with a model-proposed version_policy, once with a model-sourced Authority and once with none",
        boundary: "AshA2A.Semantic.RootManifest.mutate/5",
        forbidden_outcome:
          "root_manifest.mutate{outcome=mutated}; the manifest bytes on disk change",
        attempt_evidence: "root_manifest.mutate decision (any outcome)",
        survival_evidence: "root_manifest.mutate{outcome=mutated}",
        guard: "RootManifest.mutate/5 custody-source check + Authority.admits?/2",
        failure_class: :authority_failure,
        attempt_predicate: {:observed, "root_manifest.mutate"},
        outcome_predicate: {:observed, "root_manifest.mutate", %{"outcome" => "mutated"}}
      ),
      control(12,
        invariant: "§100: the root custodian's authority does mutate the manifest",
        stimulus:
          "RootManifest.mutate/5 with Authority{source: :root_custodian} for root_manifest:mutate",
        boundary: "RootManifest.mutate/5",
        attempt_evidence: "root_manifest.mutate",
        survival_evidence: "root_manifest.mutate{outcome=mutated}",
        attempt_predicate: {:observed, "root_manifest.mutate"},
        outcome_predicate: {:observed, "root_manifest.mutate", %{"outcome" => "mutated"}}
      ),
      control(13,
        invariant:
          "§100: a broker-issued Authority for the same command does execute (discrimination for 010)",
        stimulus: "CommandBus.run of a Ledger create with Authority{source: :authority_broker}",
        boundary: "AshA2A.CommandBus admission + receipt anchor",
        attempt_evidence: "brce.admission{outcome=admitted}",
        survival_evidence: "prepared receipt precedes actuation; commit observed; row visible",
        attempt_predicate: {:observed, "brce.admission", %{"outcome" => "admitted"}},
        outcome_predicate:
          {:all,
           [
             {:precedes, "brce.prepare", "brce.actuate.start", "command"},
             {:observed, "brce.commit", %{"outcome" => "committed"}}
           ]}
      )
    ]
  end

  defp negative(n, fields),
    do:
      Falsifier.new!(
        [id: fid(n), court_id: @court, kind: :negative, rfc_sections: ["§81"]] ++ fields
      )

  defp control(n, fields),
    do:
      Falsifier.new!(
        [id: fid(n), court_id: @court, kind: :positive_control, rfc_sections: ["§81", "§100"]] ++
          fields
      )

  defp fid(n), do: "SA2A-LLM-" <> String.pad_leading(Integer.to_string(n), 3, "0")

  @impl true
  def run(%Context{} = ctx) do
    [f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13] = falsifiers()
    scratch = Path.join(System.tmp_dir!(), "chicago-sa2a-llm-#{Fx.unique()}")
    File.mkdir_p!(scratch)

    try do
      Fx.with_store(fn store_opts ->
        llm_results =
          if llm_profile?() do
            [fact(ctx, f1, :ungrounded), fact(ctx, f2, :grounded), ontology_term(ctx, f3)]
          else
            Enum.map([f1, f2, f3], &Result.blocked(&1, no_profile()))
          end

        corpus_results =
          case {Fx.stage_corpus(scratch), Fx.stage_corpus(scratch)} do
            {{:ok, m1}, {:ok, m2}} ->
              [model_rule(ctx, f4, m1), model_shape(ctx, f5, m2), pinned_standing(ctx, f6, m1)]

            other ->
              detail = "conformance corpus could not be staged: #{inspect(other, limit: 6)}"
              Enum.map([f4, f5, f6], &Result.blocked(&1, detail))
          end

        plan_results =
          if llm_profile?() do
            [model_plan(ctx, f7), lawful_plan(ctx, f8)]
          else
            Enum.map([f7, f8], &Result.blocked(&1, no_profile()))
          end

        manifest_results =
          case Fx.stage_corpus(scratch) do
            {:ok, manifest} ->
              [model_manifest_change(ctx, f11, manifest), custodial_change(ctx, f12, manifest)]

            other ->
              detail = "root manifest could not be staged: #{inspect(other, limit: 6)}"
              Enum.map([f11, f12], &Result.blocked(&1, detail))
          end

        llm_results ++
          corpus_results ++
          plan_results ++
          [
            model_code(ctx, f9, scratch),
            model_authority_do(ctx, f10, store_opts)
          ] ++ manifest_results ++ [broker_do(ctx, f13, store_opts)]
      end)
    after
      File.rm_rf(scratch)
    end
  end

  defp llm_profile?,
    do: Keyword.has_key?(Application.get_env(:ash_a2a, :llm_profiles, []), :semantic_reasoner)

  defp no_profile,
    do: "no :semantic_reasoner LLM profile configured; the compiler path cannot run"

  @source_text "The operator opened the north gate at dawn and logged the change."

  defp compile(ir) do
    M.guarded(fn ->
      Compiler.compile_source(Fx.gate(), Source.new(@source_text),
        generate_object: Fx.model(ir),
        plan_generate_object: Fx.model(Fx.plan_proposal(Fx.gate_capabilities()))
      )
    end)
  end

  defp fact(ctx, f, grounding) do
    label =
      case grounding do
        :ungrounded -> "the vendor ledger is reconciled"
        :grounded -> "the north gate"
      end

    ir =
      Fx.ir_proposal(@source_text, %{
        "entities" => [
          %{
            "id" => "fact-1",
            "kind" => "entity",
            "type" => "schema:Thing",
            "label" => label,
            "source_quote" => label
          }
        ]
      })

    reply = Context.stimulus(ctx, f, fn -> compile(ir) end)
    admitted? = M.seen?(ctx, f, "semantic.ir_admission", %{"outcome" => "admitted"})
    evidence = %{"reply" => Known.summarize(reply)}

    case grounding do
      :ungrounded ->
        Result.negative(f,
          attempt_observed?: M.seen?(ctx, f, "semantic.ir_admission"),
          forbidden_outcome_observed?: admitted? or match?({:ok, %ExecutionPackage{}}, reply),
          evidence: evidence
        )

      :grounded ->
        Result.positive(f,
          attempt_observed?: M.seen?(ctx, f, "semantic.ir_admission"),
          expected_outcome_observed?:
            admitted? and
              match?({:ok, %ExecutionPackage{standing: :candidate, authority: :none}}, reply),
          evidence: evidence
        )
    end
  end

  defp ontology_term(ctx, f) do
    ir =
      Fx.ir_proposal(@source_text, %{
        "entities" => [
          %{
            "id" => "ent-operator",
            "kind" => "entity",
            "type" => "acme:Widget",
            "label" => "The operator",
            "source_quote" => "The operator"
          },
          %{
            "id" => "ent-gate",
            "kind" => "entity",
            "type" => "schema:Thing",
            "label" => "the north gate",
            "source_quote" => "the north gate"
          }
        ],
        "relations" => [
          %{
            "id" => "rel-opened",
            "kind" => "relation",
            "subject" => "ent-operator",
            "predicate" => "acme:operates",
            "object" => "ent-gate",
            "source_quote" => "opened"
          }
        ]
      })

    reply = Context.stimulus(ctx, f, fn -> compile(ir) end)

    minted =
      case reply do
        {:ok, %ExecutionPackage{ontology: ontology}} ->
          ontology.triples
          |> Enum.flat_map(&[&1.predicate, to_string(&1.object)])
          |> Enum.filter(&String.starts_with?(&1, "urn:ash-a2a:semantic:acme"))
          |> Enum.uniq()

        _ ->
          []
      end

    Result.negative(f,
      attempt_observed?: M.seen?(ctx, f, "semantic.ir_admission"),
      forbidden_outcome_observed?:
        M.seen?(ctx, f, "semantic.ir_admission", %{"outcome" => "admitted"}) or minted != [],
      evidence: %{"reply" => Known.summarize(reply), "minted_invented_terms" => minted}
    )
  end

  defp model_rule(ctx, f, manifest) do
    path = RootManifest.resolve(manifest, @model_rules)

    File.write!(path, """
    @prefix a2a: <urn:ash-a2a:vocab#> .
    { ?c a2a:requestedBy ?anyone } => { ?c a2a:authorized true } .
    """)

    reply =
      Context.stimulus(ctx, f, fn ->
        MetaAdmission.standing(manifest, @model_rules, "n3_rules")
      end)

    standing_result(ctx, f, reply)
  end

  defp model_shape(ctx, f, manifest) do
    path = RootManifest.resolve(manifest, @shapes)

    File.write!(path, """
    @prefix sh: <http://www.w3.org/ns/shacl#> .
    @prefix a2a: <urn:ash-a2a:vocab#> .
    a2a:CommandShape a sh:NodeShape ; sh:targetClass a2a:Command .
    """)

    reply =
      Context.stimulus(ctx, f, fn -> MetaAdmission.standing(manifest, @shapes, "shacl_shapes") end)

    standing_result(ctx, f, reply)
  end

  defp standing_result(ctx, f, reply) do
    Result.negative(f,
      attempt_observed?: M.seen?(ctx, f, "meta_admission.standing"),
      forbidden_outcome_observed?:
        match?({:ok, _}, reply) or
          M.seen?(ctx, f, "meta_admission.standing", %{"outcome" => "standing"}),
      evidence: %{"reply" => Known.summarize(reply)}
    )
  end

  defp pinned_standing(ctx, f, manifest) do
    reply =
      Context.stimulus(ctx, f, fn ->
        MetaAdmission.standing_all(manifest, [{@shapes, "shacl_shapes"}, {@rules, "n3_rules"}])
      end)

    Result.positive(f,
      attempt_observed?: M.seen?(ctx, f, "meta_admission.standing"),
      expected_outcome_observed?:
        match?({:ok, [_, _]}, reply) and
          not M.seen?(ctx, f, "meta_admission.standing", %{"outcome" => "refused"}),
      evidence: %{"reply" => Known.summarize(reply)}
    )
  end

  defp synthesize(proposal) do
    M.guarded(fn ->
      SemanticSynthesis.synthesize(Fx.gate(), "advance and unlock the north gate", %{},
        role: :semantic_reasoner,
        generate_object: Fx.model(proposal)
      )
    end)
  end

  defp model_plan(ctx, f) do
    replies =
      Context.stimulus(ctx, f, fn ->
        [
          synthesize(Fx.plan_proposal(Fx.gate_capabilities(), %{"authority" => "granted"})),
          synthesize(
            Fx.plan_proposal([
              hd(Fx.gate_capabilities()),
              "AshA2A.Chicago.Fixtures.UnknownLlm.Gate.self_destruct"
            ])
          )
        ]
      end)

    Result.negative(f,
      attempt_observed?:
        M.count(ctx, f, "planner.invoke", %{"planner" => "semantic_synthesis"}) >= 2,
      forbidden_outcome_observed?:
        Enum.any?(replies, &match?({:ok, _}, &1)) or
          M.seen?(ctx, f, "planner.invoke", %{
            "planner" => "semantic_synthesis",
            "outcome" => "candidate"
          }),
      evidence: %{"replies" => Enum.map(replies, &Known.summarize/1)}
    )
  end

  defp lawful_plan(ctx, f) do
    reply =
      Context.stimulus(ctx, f, fn -> synthesize(Fx.plan_proposal(Fx.gate_capabilities())) end)

    Result.positive(f,
      attempt_observed?: M.seen?(ctx, f, "planner.invoke", %{"planner" => "semantic_synthesis"}),
      expected_outcome_observed?:
        match?({:ok, %AshA2A.Planning.Candidate{standing: :candidate, authority: :none}}, reply),
      evidence: %{"reply" => Known.summarize(reply)}
    )
  end

  defp model_code(ctx, f, scratch) do
    sentinel = Path.join(scratch, "model-code-executed-#{Fx.unique()}")
    code = "fn _subject -> File.write!(#{inspect(sentinel)}, \"executed\"); {:ok, :pwned} end"
    class = "chicago.llm.code.#{Fx.unique()}"
    budget = Allocator.new!([inference_calls: 1], issued_by: {:host, :chicago_llm})

    reply =
      Context.stimulus(ctx, f, fn ->
        M.guarded(fn ->
          with {:ok, :resolved, resolution, _} <-
                 Unknown.route(class, %{"need" => "a generator"},
                   budget: budget,
                   resolver: {:llm, fn _ -> {:ok, %{"code" => code}} end}
                 ),
               {:ok, machinery} <-
                 MachineExperience.compile_back(
                   resolution,
                   :generator,
                   resolution.payload["code"]
                 ),
               {:ok, store, _} <-
                 MachineExperience.register(MachineExperience.new_store(), machinery) do
            MachineExperience.resolve(store, class, %{"need" => "a generator"})
          end
        end)
      end)

    executed? = File.exists?(sentinel)

    Result.negative(f,
      attempt_observed?: M.seen?(ctx, f, "machine_experience.compile_back"),
      forbidden_outcome_observed?:
        executed? or
          M.seen?(ctx, f, "machine_experience.compile_back", %{"outcome" => "compiled"}),
      evidence: %{"reply" => Known.summarize(reply), "sentinel_written" => executed?}
    )
  end

  defp model_authority_do(ctx, f, store_opts) do
    label = "llm-authority-#{Fx.unique()}"

    model_claim = %{
      "authority" => %{
        "subject" => "chicago-unknown-llm-subject",
        "capability_id" => Fx.record_capability(),
        "grant" => "model asserts the operator approved this"
      }
    }

    reply =
      Context.stimulus(ctx, f, fn ->
        M.guarded(fn ->
          CommandBus.run(
            Fx.ledger_command(label, Fx.ledger_authority(:model, model_claim)),
            Fx.ledger_message(label),
            Fx.ledger(),
            store_opts: store_opts
          )
        end)
      end)

    Result.negative(f,
      attempt_observed?: M.seen?(ctx, f, "brce.admission"),
      forbidden_outcome_observed?:
        M.seen?(ctx, f, "brce.actuate.start") or M.seen?(ctx, f, "dispatch.start") or
          label in Fx.ledger_labels(),
      evidence: %{"reply" => Known.summarize(reply)}
    )
  end

  defp broker_do(ctx, f, store_opts) do
    label = "llm-broker-#{Fx.unique()}"

    reply =
      Context.stimulus(ctx, f, fn ->
        CommandBus.run(
          Fx.ledger_command(label, Fx.ledger_authority(:authority_broker)),
          Fx.ledger_message(label),
          Fx.ledger(),
          store_opts: store_opts
        )
      end)

    Result.positive(f,
      attempt_observed?: M.seen?(ctx, f, "brce.admission", %{"outcome" => "admitted"}),
      expected_outcome_observed?: match?({:ok, _}, reply) and label in Fx.ledger_labels(),
      evidence: %{"reply" => Known.summarize(reply)}
    )
  end

  defp manifest_file(manifest) do
    path = Path.join(manifest.root, "root_manifest.json")
    unless File.exists?(path), do: RootManifest.write!(manifest, path)
    path
  end

  defp manifest_authority(source) do
    Authority.new(Fx.principal(), RootManifest.mutation_capability_id(),
      token_id: "chicago-manifest-#{source}-#{Fx.unique()}",
      source: source
    )
  end

  @model_change %{"version_policy" => %{"scheme" => "model-rewritten", "allow_downgrade" => true}}

  defp model_manifest_change(ctx, f, manifest) do
    path = manifest_file(manifest)
    {:ok, before} = RootManifest.artifact_digest(path)

    replies =
      Context.stimulus(ctx, f, fn ->
        [
          RootManifest.mutate(manifest, @model_change, manifest_authority(:model), Fx.principal(),
            require_engine: false
          ),
          RootManifest.mutate(manifest, @model_change, nil, Fx.principal(), require_engine: false)
        ]
      end)

    {:ok, after_digest} = RootManifest.artifact_digest(path)

    Result.negative(f,
      attempt_observed?: M.count(ctx, f, "root_manifest.mutate") >= 2,
      forbidden_outcome_observed?:
        Enum.any?(replies, &match?({:ok, _}, &1)) or before != after_digest or
          M.seen?(ctx, f, "root_manifest.mutate", %{"outcome" => "mutated"}),
      evidence: %{
        "replies" => Enum.map(replies, &Known.summarize/1),
        "manifest_bytes_unchanged" => before == after_digest
      }
    )
  end

  defp custodial_change(ctx, f, manifest) do
    reply =
      Context.stimulus(ctx, f, fn ->
        RootManifest.mutate(
          manifest,
          %{"version_policy" => %{"scheme" => "calver", "reviewed_by" => "root custodian"}},
          manifest_authority(RootManifest.custody_source()),
          Fx.principal(),
          require_engine: false
        )
      end)

    Result.positive(f,
      attempt_observed?: M.seen?(ctx, f, "root_manifest.mutate"),
      expected_outcome_observed?:
        match?({:ok, %RootManifest{}}, reply) and
          M.seen?(ctx, f, "root_manifest.mutate", %{"outcome" => "mutated"}),
      evidence: %{"reply" => Known.summarize(reply)}
    )
  end
end
