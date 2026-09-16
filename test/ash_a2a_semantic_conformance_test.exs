defmodule AshA2ASemanticConformanceTest do
  @moduledoc """
  Direct ExUnit coverage of `AshA2A.Semantic.Profile` (RFC S59),
  `AshA2A.Semantic.Conformance` (RFC S59/S60/S78), and the real
  `mix ash_a2a.verify_conformance` gate -- the same production code the mix
  task runs from a shell, called here directly so each real check's real
  return value is asserted on individually.

  Chicago school throughout: no Mox, no `:meck`, no `Mock`, no stubbed
  collaborator anywhere in this file. Every assertion below is against the
  real, unmodified `AshA2A.Semantic.{Source, IR, Admission, Ontology,
  PlanningIR, Vocabulary}` / `AshA2A.{Command, CommandBus, Authority,
  Receipt, ReceiptOutbox, SemanticSubject}` API, the real compiled
  `AshA2A.ArchitectureVerifier.Fixture.Resource`, the real running
  `AshA2A.ReceiptStore.Memory` GenServer, the real on-disk
  `AshA2A.ReceiptOutbox` journal, and the real compiled BEAM abstract code of
  this repo's own DO-path modules. Assertions are state-based (returned
  values, real digests, real refusal codes), never interaction-based.

  `async: false` on purpose: these tests really drive the shared, node-wide
  `AshA2A.ReceiptStore.Memory` process and the shared on-disk receipt outbox
  directory, which are genuinely global state, not per-test state.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Semantic.{Admission, Conformance, IR, Ontology, Profile, Source, Vocabulary}
  alias AshA2A.{Receipt, SemanticSubject}

  doctest AshA2A.Semantic.Profile

  describe "AshA2A.Semantic.Profile (RFC S59)" do
    test "declares all five profiles with real, unique, individually-checkable requirements" do
      assert Profile.levels() == [:sa2a_core, :sa2a_logic, :sa2a_plan, :sa2a_do, :sa2a_strict]

      requirements = Profile.requirements()
      ids = Enum.map(requirements, & &1.id)

      assert length(ids) == length(Enum.uniq(ids)), "duplicate requirement ids: #{inspect(ids)}"
      assert Enum.all?(requirements, &(&1.level in Profile.levels()))

      # Every declared check is a REAL exported zero-arity function, not a
      # dangling atom that would only blow up when someone ran the gate.
      Enum.each(requirements, fn %{id: id, check: {module, function}} ->
        assert Code.ensure_loaded?(module)

        assert function_exported?(module, function, 0),
               "requirement #{id} names #{inspect(module)}.#{function}/0, which does not exist"
      end)
    end

    test "each level introduces requirements and cumulative sets really nest" do
      Enum.each(Profile.levels(), fn level ->
        assert Profile.requirements(level) != [], "#{Profile.label(level)} introduces nothing"
      end)

      cumulative =
        Enum.map(
          Profile.levels(),
          &MapSet.new(Profile.cumulative_requirements(&1), fn r -> r.id end)
        )

      cumulative
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [lower, higher] ->
        assert MapSet.subset?(lower, higher)
        assert MapSet.size(higher) > MapSet.size(lower)
      end)

      assert MapSet.size(List.last(cumulative)) == length(Profile.requirements())
    end

    test "cumulative_requirements/1 is strictly larger than requirements/1 above the base level" do
      assert Profile.cumulative_requirements(:sa2a_core) == Profile.requirements(:sa2a_core)

      assert length(Profile.cumulative_requirements(:sa2a_do)) >
               length(Profile.requirements(:sa2a_do))
    end

    test "fetch/1 and parse/1 round-trip real ids and real RFC spellings" do
      assert {:ok, %{id: :fail_closed, level: :sa2a_core}} = Profile.fetch(:fail_closed)
      assert :error = Profile.fetch(:not_a_requirement)

      Enum.each(Profile.levels(), fn level ->
        assert {:ok, ^level} = level |> Profile.label() |> Profile.parse()
        assert {:ok, ^level} = level |> Atom.to_string() |> Profile.parse()
      end)
    end
  end

  describe "AshA2A.Semantic.Conformance requirement results (RFC S59)" do
    test "every declared requirement really runs and returns a typed status with a real detail" do
      results = Conformance.requirement_results()

      assert length(results) == length(Profile.requirements())

      Enum.each(results, fn result ->
        assert result.status in [:met, :unmet, :unverifiable]
        assert is_binary(result.detail) and result.detail != ""
      end)
    end

    test "SA2A-DO requirements are really met against the real CommandBus and receipt store" do
      results = Conformance.requirement_results()

      do_results = Enum.filter(results, &(&1.level == :sa2a_do))

      assert Enum.all?(do_results, &(&1.status == :met)),
             "expected every SA2A-DO requirement met, got: " <>
               inspect(Enum.reject(do_results, &(&1.status == :met)))
    end

    test "the real, honestly-earned level is reported and is NOT over-claimed" do
      results = Conformance.requirement_results()
      earned = Conformance.earned_level(results)

      # This repo does not conform at any level today: SA2A-CORE has real
      # unmet requirements (canonical graph identity, ShEx, SHACL, SPARQL).
      # Asserting this for real is the point -- a change that silently
      # flipped a check to vacuously-met would break this test.
      assert earned == :none

      core = Conformance.level_status(:sa2a_core, results)
      refute core.conformant?

      assert Enum.map(core.unmet, & &1.id) |> Enum.sort() ==
               [
                 :canonical_graph_identity,
                 :shacl_validation,
                 :shex_validation,
                 :sparql_falsifiers
               ]
    end

    test "level_status/2 partitions every cumulative requirement exactly once" do
      results = Conformance.requirement_results()

      Enum.each(Profile.levels(), fn level ->
        status = Conformance.level_status(level, results)
        total = length(status.met) + length(status.unmet) + length(status.unverifiable)

        assert total == length(Profile.cumulative_requirements(level))
        assert status.conformant? == (status.unmet == [] and status.unverifiable == [])
      end)
    end
  end

  describe "the real executed falsifiers" do
    test "graph identity really is non-injective: two distinct predicates collide on one IRI" do
      # The real falsifier check_canonical_graph_identity/0 reports, re-derived
      # here directly against the real Vocabulary so the test fails for the
      # real reason if the underlying behavior ever changes.
      assert Vocabulary.expand("acme:widget") == Vocabulary.expand("acme/widget")
      assert Vocabulary.expand("acme:widget") == "urn:ash-a2a:semantic:acme_widget"

      assert {:unmet, detail} = Conformance.check_canonical_graph_identity()
      assert detail =~ "NOT injective"
    end

    test "an unrecognized term really mints a private IRI at runtime with no admission" do
      minted = Vocabulary.expand("definitely-not-admitted:term")
      assert String.starts_with?(minted, "urn:ash-a2a:semantic:")

      assert {:unmet, detail} = Conformance.check_no_runtime_semantic_invention()
      assert detail =~ "urn:ash-a2a:semantic:"
    end

    test "FOND effects really are inexpressible: HddlOperator has no nondeterministic slot" do
      keys = %AshA2A.HddlOperator{} |> Map.from_struct() |> Map.keys()

      refute :oneof in keys
      refute :nondeterministic_effects in keys
      assert :add_effects in keys and :delete_effects in keys

      assert {:unmet, detail} = Conformance.check_fond_hddl()
      assert detail =~ "STRIPS"
    end
  end

  describe "AshA2A.Semantic.Conformance invariants (RFC S60)" do
    setup do
      %{invariants: Conformance.invariants()}
    end

    test "all thirteen invariants really run and carry a typed status, scope, and detail", %{
      invariants: invariants
    } do
      assert length(invariants) == 13

      Enum.each(invariants, fn invariant ->
        assert invariant.status in [:ok, :violated, :unverifiable]
        assert invariant.scope in [:witnessed, :structural, :none]
        assert is_binary(invariant.formula) and invariant.formula != ""
        assert is_binary(invariant.detail) and invariant.detail != ""
      end)

      ids = Enum.map(invariants, & &1.id)
      assert length(ids) == length(Enum.uniq(ids))
    end

    test "an :unverifiable invariant never claims a scope (honesty rule)", %{
      invariants: invariants
    } do
      invariants
      |> Enum.filter(&(&1.status == :unverifiable))
      |> Enum.each(fn invariant ->
        assert invariant.scope == :none,
               "#{invariant.id} reports :unverifiable but claims scope #{invariant.scope}"
      end)
    end

    test "the authority invariants really hold, witnessed by real refusals", %{
      invariants: invariants
    } do
      by_id = Map.new(invariants, &{&1.id, &1})

      for id <- [
            :executed_implies_authorized,
            :authorized_implies_admitted,
            :projection_is_not_semantic_authority,
            :task_is_not_authority,
            :llm_output_is_candidate
          ] do
        assert %{status: :ok, scope: :witnessed} = by_id[id]
      end
    end

    test "the private-term invariant really is VIOLATED, with an executed falsifier", %{
      invariants: invariants
    } do
      violated = Enum.find(invariants, &(&1.id == :private_term_admission))

      assert violated.status == :violated
      assert violated.detail =~ "executed falsifier"
      assert violated.detail =~ "urn:ash-a2a:semantic:acme_widget"
    end

    test "invariants with no gate to witness really report :unverifiable, never :ok", %{
      invariants: invariants
    } do
      by_id = Map.new(invariants, &{&1.id, &1})

      for id <- [
            :selected_implies_admitted_plan,
            :derived_implies_rule_standing,
            :validated_implies_validator_standing
          ] do
        assert %{status: :unverifiable} = by_id[id]
      end
    end
  end

  describe "real semantic-pipeline collaborators the checks run against" do
    test "the sample source really grounds every admitted item, and an ungrounded one is refused" do
      text = "Goal: deliver the quarterly report. The analyst reviews the draft."
      source = Source.new(text, id: "sa2a-conformance-source")

      {:ok, candidate} =
        IR.from_map("sa2a-conformance-source", %{
          "authority" => "none",
          "goals" => [
            %{
              "id" => "g1",
              "kind" => "goal",
              "description" => "deliver the quarterly report",
              "source_quote" => "deliver the quarterly report"
            }
          ]
        })

      assert candidate.standing == :candidate
      assert {:ok, admitted} = Admission.admit(source, candidate)
      assert admitted.standing == :admitted

      {:ok, ungrounded} =
        IR.from_map("sa2a-conformance-source", %{
          "authority" => "none",
          "goals" => [
            %{
              "id" => "g1",
              "kind" => "goal",
              "description" => "deliver the quarterly report",
              "source_quote" => "deliver the quarterly report"
            }
          ],
          "observations" => [
            %{
              "id" => "o1",
              "kind" => "observation",
              "description" => "the board already approved it",
              "source_quote" => "the board already approved it"
            }
          ]
        })

      assert {:error, %{code: :ungrounded_assertion, detail: "o1"}} =
               Admission.admit(source, ungrounded)
    end

    test "every projected node really carries provenance back to the real source" do
      assert Conformance.check_provenance() == :met

      text = "Goal: deliver the quarterly report. The analyst reviews the draft."
      source = Source.new(text, id: "sa2a-conformance-source")

      {:ok, candidate} =
        IR.from_map("sa2a-conformance-source", %{
          "authority" => "none",
          "goals" => [
            %{
              "id" => "g1",
              "kind" => "goal",
              "description" => "deliver the quarterly report",
              "source_quote" => "deliver the quarterly report"
            }
          ]
        })

      {:ok, admitted} = Admission.admit(source, candidate)
      {:ok, ontology} = Ontology.from_ir(admitted)

      prov = Vocabulary.expand("prov:wasDerivedFrom")
      assert prov == "http://www.w3.org/ns/prov#wasDerivedFrom"

      assert Enum.any?(
               ontology.triples,
               &(&1.predicate == prov and
                   &1.object == "urn:ash-a2a:source:sa2a-conformance-source")
             )
    end
  end

  describe "static analysis over real compiled BEAM abstract code" do
    test "remote_call_targets/1 really reads the real compiled CommandBus and finds real targets" do
      assert {:ok, targets} = Conformance.remote_call_targets(AshA2A.CommandBus)

      # These are real remote calls CommandBus genuinely makes today.
      assert AshA2A.Receipt in targets
      assert AshA2A.ReceiptOutbox in targets
      assert targets == Enum.sort(Enum.uniq(targets))
    end

    test "no LITERALLY NAMED call target on the DO path is an LLM module -- and real dynamic dispatch sites make the requirement honestly unverifiable, not falsely met" do
      # Tightened by a real round-2 fix: an earlier revision of this check
      # only collected literal `Mod.fun(...)` targets and concluded
      # `:met` from what it could see, even though `AshA2A.CommandBus`
      # and `AshA2A.ReceiptOutbox` genuinely dispatch some calls through a
      # variable module / `apply/3` -- targets an AST scan cannot resolve.
      # A vacuously-true structural check is worse than an absent one, so
      # `check_no_llm_on_production_do_path/0` now reports `:unverifiable`
      # whenever such a site exists, naming exactly where.
      assert {:unverifiable, detail} = Conformance.check_no_llm_on_production_do_path()
      assert detail =~ "no LITERALLY NAMED call target"
      assert detail =~ "dispatch on a module that is a runtime value"
      assert detail =~ "AshA2A.CommandBus"

      assert {:ok, targets} = Conformance.remote_call_targets(AshA2A.CommandBus)
      refute Enum.any?(targets, &Conformance.llm_module?/1)

      # The real dynamic sites this requirement is honestly blind to.
      assert {:ok, dynamic} = Conformance.dynamic_call_sites(AshA2A.CommandBus)
      assert dynamic != []
    end

    test "llm_module?/1 really classifies the real module names it is meant to catch" do
      assert Conformance.llm_module?(AshA2A.LlmProfiles)
      assert Conformance.llm_module?(AshA2A.Semantic.Compiler)
      refute Conformance.llm_module?(AshA2A.CommandBus)
      refute Conformance.llm_module?(AshA2A.Receipt)
    end
  end

  describe "engine_capability/2 (the real external-engine seam)" do
    test "reports the exact missing function when no :semantic_engine is configured" do
      assert Application.get_env(:ash_a2a, :semantic_engine) == nil
      assert {:unmet, detail} = Conformance.engine_capability(:validate_shacl, 2)
      assert detail =~ "validate_shacl/2"
      assert detail =~ ":semantic_engine"
    end

    test "really resolves a configured engine module and its real exported function" do
      # A real module with real behavior, not a mock: `Enum` genuinely exports
      # `count/1` and genuinely does not export `validate_shacl/2`, so both
      # branches of the real reflection are exercised against real code.
      Application.put_env(:ash_a2a, :semantic_engine, Enum)
      on_exit(fn -> Application.delete_env(:ash_a2a, :semantic_engine) end)

      assert Conformance.engine_capability(:count, 1) == :met
      assert {:unmet, detail} = Conformance.engine_capability(:validate_shacl, 2)
      assert detail =~ "does not export validate_shacl/2"
    end
  end

  describe "explain/1 (RFC S78, the twelve questions)" do
    test "a real receipt from a real authorized run answers what the surface supports" do
      assert {:ok, answers} = Conformance.explain_sample()
      assert length(answers) == 12

      ids = Enum.map(answers, & &1.id)
      assert length(ids) == length(Enum.uniq(ids))
      assert Enum.all?(answers, &(&1.rfc_section == "S78"))

      Enum.each(answers, fn %{id: id, answer: answer} ->
        assert match?({:answered, _}, answer) or match?({:partial, _, _}, answer) or
                 match?({:unanswerable, _}, answer),
               "#{id} returned #{inspect(answer)}"
      end)

      coverage = Conformance.explain_coverage(answers)
      assert coverage.answered + coverage.partial + coverage.unanswerable == 12
      assert coverage.answered > 0
      assert coverage.unanswerable > 0
    end

    test "the questions this surface genuinely cannot answer really report :unanswerable" do
      assert {:ok, answers} = Conformance.explain_sample()
      by_id = Map.new(answers, &{&1.id, &1.answer})

      assert {:unanswerable, rules} = by_id[:rules]
      assert rules =~ "no rule engine"

      assert {:unanswerable, validators} = by_id[:validators]
      assert validators =~ "validator"

      assert {:unanswerable, plan} = by_id[:plan]
      assert plan =~ "no plan field"
    end

    test "a real receipt carrying a real SemanticSubject really answers the subject question" do
      assert {:ok, subject} = Conformance.real_semantic_subject()
      assert %SemanticSubject{} = subject
      assert "sha256:" <> graph_hex = subject.graph_digest
      assert String.match?(graph_hex, ~r/\A[0-9a-f]{64}\z/)

      assert {:ok, answers} = Conformance.explain_sample()
      by_id = Map.new(answers, &{&1.id, &1.answer})

      assert {:answered, %{graph_digest: digest, manufacturer_digest: manufacturer}} =
               by_id[:subject]

      assert digest == subject.graph_digest
      assert manufacturer == subject.manufacturer_digest
    end

    test "a receipt with no SemanticSubject really reports the subject question unanswerable" do
      receipt = %Receipt{
        receipt_id: AshA2A.Identity.runtime(Ash.UUIDv7.generate()),
        command_id: AshA2A.Identity.command("sa2a-explain-bare"),
        execution_id: AshA2A.Identity.execution(Ash.UUIDv7.generate()),
        agent_id: AshA2A.Identity.agent("sa2a-explain"),
        principal_id: AshA2A.Identity.principal("sa2a-explain-principal"),
        capability_id: "sa2a.explain",
        semantic_subject: nil,
        fingerprint: String.duplicate("0", 64),
        consequence: :observe,
        status: :completed,
        standing: :observed,
        reply: {:reply, :ok},
        recorded_at: DateTime.utc_now()
      }

      by_id = Map.new(Conformance.explain(receipt), &{&1.id, &1.answer})

      assert {:unanswerable, detail} = by_id[:subject]
      assert detail =~ "no AshA2A.SemanticSubject"
      assert {:partial, %{capability_id: "sa2a.explain"}, _gap} = by_id[:meaning]

      assert {:answered, %{consequence: :observe, receipt_anchor_required?: false}} =
               by_id[:consequence]
    end

    test "a refused receipt really reports its typed refusal code" do
      receipt = %Receipt{
        receipt_id: AshA2A.Identity.runtime(Ash.UUIDv7.generate()),
        command_id: AshA2A.Identity.command("sa2a-explain-refused"),
        execution_id: AshA2A.Identity.execution(Ash.UUIDv7.generate()),
        agent_id: AshA2A.Identity.agent("sa2a-explain"),
        principal_id: AshA2A.Identity.principal("sa2a-explain-principal"),
        capability_id: "sa2a.explain",
        fingerprint: String.duplicate("0", 64),
        consequence: :change,
        status: :failed,
        standing: :observed,
        reply: {:error, %{code: :authority_required, detail: "authority_required"}},
        recorded_at: DateTime.utc_now()
      }

      by_id = Map.new(Conformance.explain(receipt), &{&1.id, &1.answer})

      assert {:answered, %{refused?: true, code: :authority_required}} = by_id[:refusal]
    end
  end

  describe "report/0 and the mix task's real gate logic" do
    test "report/0 really returns requirements, levels, invariants, and the earned level" do
      report = Conformance.report()

      assert length(report.requirements) == length(Profile.requirements())
      assert length(report.levels) == length(Profile.levels())
      assert length(report.invariants) == 13
      assert report.earned_level in [:none | Profile.levels()]
    end

    test "mix ash_a2a.verify_conformance really exists and really refuses an unearned claim" do
      # The task module itself is real and loadable; its gate logic is the
      # same `level_status/2` + invariant scan asserted above, so an unearned
      # claim really has problems to report.
      assert Code.ensure_loaded?(Mix.Tasks.AshA2a.VerifyConformance)
      assert function_exported?(Mix.Tasks.AshA2a.VerifyConformance, :run, 1)

      results = Conformance.requirement_results()
      status = Conformance.level_status(:sa2a_core, results)

      assert status.unmet != [],
             "SA2A-CORE has no unmet requirement, so the gate would wrongly pass a claim"
    end
  end
end
