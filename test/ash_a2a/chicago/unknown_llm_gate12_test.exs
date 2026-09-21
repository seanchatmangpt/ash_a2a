defmodule AshA2A.Chicago.UnknownLlmGate12Test do
  @moduledoc """
  Qualifies `CHI-KNOWN` (Gate 12), `SA2A-UNKNOWN`, `SA2A-LLM` and `SA2A-MX`
  (RFC-SA2A-002 §43, §79-§82, §134) end to end: real router, real solver
  subprocess, real UNKNOWN router/allocator/LLM boundary, real CommandBus over
  real ETS resources, real staged conformance corpus, and the durable OCEL
  artifact re-read by the independent consumer.

  `async: false`: the observer attributes every telemetry event between a
  stimulus start and stop to that falsifier.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.Chicago
  alias AshA2A.Chicago.{Context, Falsifier, Result, Runner}
  alias AshA2A.Chicago.Courts
  alias AshA2A.Chicago.Courts.InferenceMappings, as: M
  alias AshA2A.Chicago.Fixtures.UnknownLlm, as: Fx
  alias AshA2A.Planning.RequestRouter
  alias AshA2A.Semantic.{Allocator, Unknown}

  @moduletag :tmp_dir

  @courts [
    Courts.Known,
    Courts.Unknown,
    Courts.LlmBoundary,
    Courts.MachineExperience
  ]

  @expected %{
    "CHI-KNOWN-001" => :falsifier_killed,
    "CHI-KNOWN-002" => :falsifier_killed,
    "CHI-KNOWN-003" => :falsifier_killed,
    "CHI-KNOWN-004" => :positive_control_passed,
    "CHI-KNOWN-005" => :positive_control_passed,
    "CHI-KNOWN-006" => :falsifier_killed,
    "CHI-KNOWN-007" => :falsifier_killed,
    "CHI-KNOWN-008" => :positive_control_passed,
    "SA2A-UNKNOWN-001" => :falsifier_killed,
    "SA2A-UNKNOWN-002" => :falsifier_killed,
    "SA2A-UNKNOWN-003" => :falsifier_killed,
    "SA2A-UNKNOWN-004" => :positive_control_passed,
    "SA2A-UNKNOWN-005" => :positive_control_passed,
    "SA2A-UNKNOWN-006" => :falsifier_killed,
    "SA2A-UNKNOWN-007" => :falsifier_killed,
    "SA2A-UNKNOWN-008" => :falsifier_killed,
    "SA2A-UNKNOWN-009" => :positive_control_passed,
    "SA2A-LLM-001" => :falsifier_killed,
    "SA2A-LLM-002" => :positive_control_passed,
    "SA2A-LLM-003" => :falsifier_killed,
    "SA2A-LLM-004" => :falsifier_killed,
    "SA2A-LLM-005" => :falsifier_killed,
    "SA2A-LLM-006" => :positive_control_passed,
    "SA2A-LLM-007" => :falsifier_killed,
    "SA2A-LLM-008" => :positive_control_passed,
    "SA2A-LLM-009" => :falsifier_killed,
    "SA2A-LLM-010" => :falsifier_killed,
    "SA2A-LLM-011" => :falsifier_killed,
    "SA2A-LLM-012" => :positive_control_passed,
    "SA2A-LLM-013" => :positive_control_passed,
    "SA2A-MX-001" => :positive_control_passed,
    "SA2A-MX-002" => :falsifier_killed,
    "SA2A-MX-003" => :positive_control_passed,
    "SA2A-MX-004" => :falsifier_killed,
    "SA2A-MX-005" => :falsifier_killed,
    "SA2A-MX-006" => :falsifier_killed
  }

  describe "end-to-end qualification run" do
    test "every falsifier reaches its final verdict and every pass is OCEL-corroborated",
         %{tmp_dir: dir} do
      assert {:ok, run} = Runner.run(courts: @courts, profile: :strict, evidence_dir: dir)

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})
      assert Enum.sort(Map.keys(by_id)) == Enum.sort(Map.keys(@expected))

      failures =
        for {id, verdict} <- @expected,
            r = by_id[id],
            r.verdict != verdict or
              (Result.passing_verdict?(r) and r.ocel_corroborated? != true) do
          {id, r.verdict, r.detail, r.ocel_detail, r.evidence}
        end

      assert failures == [], inspect(failures, pretty: true, limit: :infinity)

      assert run.ocel.dropped == 0
      assert File.exists?(Path.join(dir, "ocel.json"))

      # Gate 12 is covered by a court at this profile.
      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      assert receipt["results"]["falsifiers_survived"] == 0
    end
  end

  describe "declarations" do
    test "courts are discoverable at :strict with exactly the assigned ids" do
      strict = Chicago.courts_for(:strict)
      for court <- @courts, do: assert(court in strict)

      assert Enum.map(@courts, & &1.id()) == ["CHI-KNOWN", "SA2A-UNKNOWN", "SA2A-LLM", "SA2A-MX"]
      assert Courts.Known.gate() == 12
      refute Courts.Known in Chicago.courts_for(:do)
    end

    test "every falsifier is fully declared with attempt and outcome predicates" do
      falsifiers = Enum.flat_map(@courts, & &1.falsifiers())
      ids = Enum.map(falsifiers, & &1.id)

      assert length(ids) == length(Enum.uniq(ids))

      for %Falsifier{} = f <- falsifiers do
        assert String.starts_with?(f.id, f.court_id <> "-")
        assert f.attempt_predicate, "#{f.id} has no attempt predicate"
        assert f.outcome_predicate, "#{f.id} has no outcome predicate"
      end

      kinds = Enum.frequencies_by(falsifiers, & &1.kind)
      assert kinds[:negative] >= 20
      assert kinds[:positive_control] >= 12
    end
  end

  # --- §22 anti-vacuity and §134 regression: the court machinery must detect
  # a non-executing reflex and a reintroduced inference call. Test-only courts
  # reuse CHI-KNOWN's own exported predicates.

  defmodule NonExecutingKnown do
    @moduledoc "Reuses CHI-KNOWN predicates over a request that never reaches the reflex."
    use AshA2A.Chicago.Court, discoverable: false

    alias AshA2A.Chicago.Courts.InferenceMappings, as: M

    def id, do: "CHI-KNOWNVAC"
    def title, do: "non-executing KNOWN reflex"
    def gate, do: 12
    def profile, do: :strict
    def rfc_sections, do: ["§43"]
    def ocel_mappings, do: [M.llm_invoke(), M.planner_invoke(), M.router_tier_refused()]

    def falsifiers do
      [
        Falsifier.new!(
          id: "CHI-KNOWNVAC-001",
          court_id: "CHI-KNOWNVAC",
          kind: :negative,
          invariant: "zero tokens without execution is not a pass",
          stimulus: "RequestRouter.route of a message with no input",
          boundary: "RequestRouter",
          forbidden_outcome: "llm.invoke",
          attempt_evidence: "router decided and machinery ran",
          survival_evidence: "llm.invoke",
          guard: "CHI-KNOWN attempt predicate",
          attempt_predicate: Courts.Known.router_decided_and_ran_predicate(),
          outcome_predicate: Courts.Known.llm_allocated_predicate()
        ),
        Falsifier.new!(
          id: "CHI-KNOWNVAC-002",
          court_id: "CHI-KNOWNVAC",
          kind: :positive_control,
          invariant: "positive execution is required",
          stimulus: "same",
          boundary: "RequestRouter",
          attempt_evidence: "router.tier_refused",
          attempt_predicate: {:observed, "router.tier_refused"},
          outcome_predicate: Courts.Known.known_reflex_predicate()
        )
      ]
    end

    def run(ctx) do
      [neg, pos] = falsifiers()
      empty = A2A.Message.new_user([A2A.Part.Data.new(%{})])

      for f <- [neg, pos] do
        Context.stimulus(ctx, f, fn -> RequestRouter.route(Fx.gate(), empty) end)
      end

      [
        # Claims a kill: the independent consumer must refuse to corroborate it.
        Result.negative(neg, attempt_observed?: true, forbidden_outcome_observed?: false),
        Result.positive(pos,
          attempt_observed?: M.seen?(ctx, pos, "router.tier_refused"),
          expected_outcome_observed?:
            M.seen?(ctx, pos, "planner.invoke", %{"outcome" => "solved"})
        )
      ]
    end
  end

  defmodule RegressedKnown do
    @moduledoc "The KNOWN phrase with its compiled template missing: inference reintroduced."
    use AshA2A.Chicago.Court, discoverable: false

    alias AshA2A.Chicago.Courts.InferenceMappings, as: M

    def id, do: "CHI-KNOWNREG"
    def title, do: "machine-experience regression"
    def gate, do: 12
    def profile, do: :strict
    def rfc_sections, do: ["§134"]
    def ocel_mappings, do: [M.llm_invoke(), M.planner_invoke()]

    def falsifiers do
      [
        Falsifier.new!(
          id: "CHI-KNOWNREG-001",
          court_id: "CHI-KNOWNREG",
          kind: :negative,
          invariant: "a KNOWN phrase allocates no LLM",
          stimulus: "RequestRouter.route of the KNOWN phrase with the compiled template removed",
          boundary: "RequestRouter.route_text/3",
          forbidden_outcome: "llm.invoke",
          attempt_evidence: "router decided and machinery ran",
          survival_evidence: "llm.invoke",
          guard: "compiled phrase template (removed)",
          failure_class: :planning_failure,
          attempt_predicate: Courts.Known.router_decided_and_ran_predicate(),
          outcome_predicate: Courts.Known.llm_allocated_predicate()
        )
      ]
    end

    def run(ctx) do
      [f] = falsifiers()

      Context.stimulus(ctx, f, fn ->
        RequestRouter.route(Fx.gate(), Fx.text_message(Fx.known_phrase()),
          phrase_templates: [],
          generate_object: Fx.tripwire_model()
        )
      end)

      [
        Result.negative(f,
          attempt_observed?:
            M.seen?(ctx, f, "router.tier_selected") and M.seen?(ctx, f, "llm.invoke"),
          forbidden_outcome_observed?: M.seen?(ctx, f, "llm.invoke")
        )
      ]
    end
  end

  defmodule SkippedMachinery do
    @moduledoc "SA2A-MX-002's stimulus with the compiled store withheld (step 1 guard deleted)."
    use AshA2A.Chicago.Court, discoverable: false

    alias AshA2A.Chicago.Courts.InferenceMappings, as: M

    def id, do: "SA2A-MXMUT"
    def title, do: "compiled route bypassed"
    def gate, do: nil
    def profile, do: :strict
    def rfc_sections, do: ["§22"]
    def ocel_mappings, do: [M.allocation(), M.allocator_decision(), M.llm_boundary_candidate()]

    def falsifiers do
      [mx2] = Enum.filter(Courts.MachineExperience.falsifiers(), &(&1.id == "SA2A-MX-002"))
      [%{mx2 | id: "SA2A-MXMUT-001", court_id: "SA2A-MXMUT"}]
    end

    def run(ctx) do
      [f] = falsifiers()
      budget = Allocator.new!([inference_calls: 1], issued_by: {:host, :mutation})

      Context.stimulus(ctx, f, fn ->
        Unknown.route("chicago.mx.mutation", Courts.MachineExperience.preserved_fixture(),
          budget: budget,
          resolver: {:llm, fn _ -> {:ok, %{"template" => "^x$"}} end}
        )
      end)

      [
        Result.negative(f,
          attempt_observed?: M.seen?(ctx, f, "semantic.allocation"),
          forbidden_outcome_observed?:
            M.seen?(ctx, f, "semantic.allocation", %{"resolver" => "llm"})
        )
      ]
    end
  end

  describe "permanent guards for the defects SA2A-LLM found" do
    test "SA2A-LLM-010: CommandBus refuses a model-sourced Authority before any actuation" do
      Fx.with_store(fn store_opts ->
        label = "guard-model-authority-#{Fx.unique()}"

        assert {:error, %{code: :model_authority_refused}} =
                 AshA2A.CommandBus.run(
                   Fx.ledger_command(label, Fx.ledger_authority(:model)),
                   Fx.ledger_message(label),
                   Fx.ledger(),
                   store_opts: store_opts
                 )

        refute label in Fx.ledger_labels()
        assert AshA2A.Semantic.Refusal.classify(:model_authority_refused) == :refused_authority
      end)
    end

    test "SA2A-LLM-003: admission refuses a model-invented namespace term, admits admitted/local ones" do
      text = "The operator opened the north gate."
      source = AshA2A.Semantic.Source.new(text)

      entity = fn type ->
        %{
          "entities" => [
            %{
              "id" => "e1",
              "kind" => "entity",
              "type" => type,
              "label" => "the north gate",
              "source_quote" => "the north gate"
            }
          ]
        }
      end

      admit = fn overrides ->
        {:ok, ir} = AshA2A.Semantic.IR.from_map(source.id, Fx.ir_proposal(text, overrides))
        AshA2A.Semantic.Admission.admit(source, ir)
      end

      assert {:error, %{code: :ontology_term_not_admitted, detail: %{term: "acme:Widget"}}} =
               admit.(entity.("acme:Widget"))

      assert {:error, %{code: :ontology_term_not_admitted}} =
               admit.(entity.("https://evil.example/vocab#Widget"))

      assert {:ok, %{standing: :admitted}} = admit.(entity.("schema:Thing"))
      assert {:ok, %{standing: :admitted}} = admit.(entity.("organization"))

      assert AshA2A.Semantic.Refusal.classify(:ontology_term_not_admitted) == :refused_namespace
    end
  end

  describe "anti-vacuity (§12, §22) and machine-experience regression (§134)" do
    test "a KNOWN run that never executed the reflex never passes", %{tmp_dir: dir} do
      {:ok, run} = Runner.run(courts: [NonExecutingKnown], profile: :strict, evidence_dir: dir)
      by_id = Map.new(run.results, &{&1.falsifier_id, &1})

      assert by_id["CHI-KNOWNVAC-001"].verdict == :unknown
      refute Result.counts_as_pass?(by_id["CHI-KNOWNVAC-001"])
      assert by_id["CHI-KNOWNVAC-002"].verdict == :positive_control_failed
      refute Result.counts_as_pass?(by_id["CHI-KNOWNVAC-002"])
    end

    test "reintroducing inference on the KNOWN route is detected as a regression",
         %{tmp_dir: dir} do
      {:ok, run} = Runner.run(courts: [RegressedKnown], profile: :strict, evidence_dir: dir)
      [result] = run.results

      assert result.verdict == :falsifier_survived
      assert result.ocel_corroborated? == true
      assert result.failure_class == :planning_failure
    end

    test "bypassing compiled machinery makes SA2A-MX-002's predicates survive", %{tmp_dir: dir} do
      {:ok, run} = Runner.run(courts: [SkippedMachinery], profile: :strict, evidence_dir: dir)
      [result] = run.results

      assert result.verdict == :falsifier_survived
      assert result.ocel_corroborated? == true
    end
  end
end
