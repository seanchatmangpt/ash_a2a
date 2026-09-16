defmodule AshA2A.Chicago.HooksCascadeTest do
  @moduledoc """
  Qualifies the Knowledge Hook (`SA2A-HOOK`) and Reactive Cascade
  (`SA2A-CASCADE`) courts end to end, plus narrow tests of the reactor pieces
  they attack. Chicago style throughout: the real praxis-graphlaw wasm (in an
  in-BEAM Wasmtime session), the real CommandBus, a real receipt store, a
  real authority broker, the real ETS `Signal` resource, and a real OCEL
  artifact read back from disk by the independent consumer.

  `async: false` -- the observer attributes telemetry to the active stimulus.
  Tagged `:graphlaw`: excluded, with a printed reason, where the wasm or its
  host is absent (see `test/test_helper.exs`).
  """

  use ExUnit.Case, async: false

  alias AshA2A.Chicago
  alias AshA2A.Chicago.{Query, Result, Runner, StandingReceipt}
  alias AshA2A.Chicago.Courts.{KnowledgeHooks, ReactiveCascade}
  alias AshA2A.Chicago.Fixtures.HooksCascade, as: F
  alias AshA2A.Chicago.Observer.NonAuthority
  alias AshA2A.Chicago.Ocel.Mapping
  alias AshA2A.Semantic.{HookReactor, Refusal}
  alias AshA2A.Semantic.HookReactor.{Engine, Hook, Intent}

  @moduletag :tmp_dir
  @moduletag :graphlaw

  @expected %{
    "SA2A-HOOK-001" => :falsifier_killed,
    "SA2A-HOOK-002" => :falsifier_killed,
    "SA2A-HOOK-003" => :falsifier_killed,
    "SA2A-HOOK-004" => :falsifier_killed,
    "SA2A-HOOK-005" => :falsifier_killed,
    "SA2A-HOOK-006" => :positive_control_passed,
    "SA2A-HOOK-007" => :falsifier_killed,
    "SA2A-HOOK-008" => :falsifier_killed,
    "SA2A-HOOK-009" => :falsifier_killed,
    "SA2A-HOOK-010" => :falsifier_killed,
    "SA2A-HOOK-011" => :falsifier_killed,
    "SA2A-HOOK-012" => :falsifier_killed,
    "SA2A-CASCADE-001" => :falsifier_killed,
    "SA2A-CASCADE-002" => :falsifier_killed,
    "SA2A-CASCADE-003" => :falsifier_killed,
    "SA2A-CASCADE-004" => :falsifier_killed,
    "SA2A-CASCADE-005" => :falsifier_killed,
    "SA2A-CASCADE-006" => :falsifier_killed,
    "SA2A-CASCADE-007" => :positive_control_passed,
    "SA2A-CASCADE-008" => :positive_control_passed,
    "SA2A-CASCADE-009" => :measured,
    "SA2A-CASCADE-010" => :measured,
    "SA2A-CASCADE-011" => :measured,
    "SA2A-CASCADE-012" => :measured,
    "SA2A-CASCADE-013" => :measured,
    "SA2A-CASCADE-014" => :measured
  }

  setup_all do
    {:ok, runtime} = Engine.open()
    on_exit(fn -> Engine.close(runtime) end)
    %{runtime: runtime}
  end

  describe "end-to-end Chicago run of SA2A-HOOK and SA2A-CASCADE" do
    test "every falsifier reaches its verdict and every pass is corroborated from the OCEL on disk",
         %{tmp_dir: dir} do
      assert {:ok, run} =
               Runner.run(
                 courts: [KnowledgeHooks, ReactiveCascade],
                 profile: :logic,
                 evidence_dir: dir
               )

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})
      assert Enum.sort(Map.keys(by_id)) == Enum.sort(Map.keys(@expected))

      for {id, verdict} <- @expected do
        result = by_id[id]

        assert result.verdict == verdict,
               "#{id}: #{result.verdict} detail=#{result.detail} ocel=#{result.ocel_detail} " <>
                 "evidence=#{inspect(result.evidence)}"

        assert result.ocel_corroborated? == true, "#{id}: #{result.ocel_detail}"
        assert Result.counts_as_pass?(result)
      end

      assert run.ocel.dropped == 0

      # Hook ≠ DO: the no-grant reflex built a candidate intent but nothing actuated.
      no_grant = by_id["SA2A-HOOK-001"].evidence
      assert no_grant["signal_rows"] == 0
      assert [_intent_id] = no_grant["intent_ids"]
      assert no_grant["route_outcomes"] == ["refused:authority_required"]

      # Replay and reordering produced one intent identity and one consequence.
      for id <- ["SA2A-HOOK-007", "SA2A-HOOK-008"] do
        [first, second] = by_id[id].evidence["intent_ids"]
        assert first == second and first != []
        assert by_id[id].evidence["signal_rows"] == 1
      end

      # Bounded termination of the self-triggering cycle.
      cycle = by_id["SA2A-CASCADE-001"].evidence
      assert cycle["cascade_code"] == :bounds_depth_exceeded
      assert cycle["depth_reached"] == 3
      assert cycle["signal_rows"] == 3

      assert by_id["SA2A-CASCADE-005"].evidence["max_in_flight"] <= 2
      assert by_id["SA2A-CASCADE-005"].evidence["max_actuation_overlap"] <= 2

      # B3: counts come from observer records.
      b3 = by_id["SA2A-CASCADE-011"].measurements["multi_match"]
      assert b3["hooks_fired"] == 3
      assert b3["intent_count"] == 3
      assert b3["delta_size"] == 1
      assert b3["hook_evaluation_latency_us"]["n"] == 3
      assert b3["idempotency_check_latency_us"]["n"] == 3

      replay = by_id["SA2A-CASCADE-012"].measurements
      assert replay["first_delivery"]["route_outcomes"] == %{"committed" => 1}
      assert replay["replayed_delivery"]["route_outcomes"] == %{"replayed" => 1}
      assert replay["replayed_delivery"]["idempotency_outcomes"] == %{"seen" => 1}

      assert by_id["SA2A-CASCADE-009"].measurements["no_match"]["intent_count"] == 0

      # B6: the cycle-inducing fixture is cut exactly at each admitted depth.
      b6 = by_id["SA2A-CASCADE-014"].measurements

      for {label, depth} <- [{"depth_1", 1}, {"depth_2", 2}, {"depth_4", 4}] do
        assert b6[label]["cascade_depth"] == depth
        assert b6[label]["receipts_produced"] == depth
        assert b6[label]["terminal_code"] == "bounds_depth_exceeded"
      end

      tree = by_id["SA2A-CASCADE-013"].measurements

      for p <- [1, 2] do
        run_p = tree["parallelism_#{p}"]
        assert run_p["fan_out_per_depth"] == %{"1" => 2, "2" => 4}
        assert run_p["receipts_produced"] == 6
        assert run_p["parallelism_max_in_flight"] <= p
      end

      # The independent consumer reads the durable artifact: one hook activity
      # per SUT event even though both courts declared the mapping.
      assert {:ok, index} = Query.load(Path.join(dir, "ocel.json"), run.ocel.sha256)

      assert {true, _} =
               Query.eval(index, "SA2A-HOOK-006", {:count, "hook.intent.constructed", :eq, 1})

      assert {true, _} =
               Query.eval(
                 index,
                 "SA2A-HOOK-006",
                 {:precedes, "hook.intent.constructed", "brce.actuate.start", "command"}
               )

      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      assert :ok = StandingReceipt.verify_digest(receipt)
      assert receipt["results"]["falsifiers_survived"] == 0
    end
  end

  describe "discovery and refusal classification" do
    test "both courts are discoverable LOGIC courts and not CORE courts" do
      assert KnowledgeHooks in Chicago.courts_for(:logic)
      assert ReactiveCascade in Chicago.courts_for(:logic)
      refute KnowledgeHooks in Chicago.courts_for(:core)
    end

    test "the reactor mappings both courts declare are admitted once, still distinct per activity" do
      shared = F.mappings()
      assert KnowledgeHooks.ocel_mappings() == shared
      assert ReactiveCascade.ocel_mappings() == shared

      reactor =
        [KnowledgeHooks, ReactiveCascade]
        |> Runner.ocel_mappings()
        |> Enum.filter(&match?([:ash_a2a, :hook_reactor | _], &1.event))

      # One admitted mapping per reactor activity: one emission, one record.
      assert length(reactor) == length(shared)

      assert reactor |> Enum.map(&{&1.event, &1.activity}) |> Enum.uniq() |> length() ==
               length(shared)

      assert Mapping.digest(Runner.ocel_mappings([KnowledgeHooks, ReactiveCascade])) ==
               Mapping.digest(Runner.ocel_mappings([ReactiveCascade, KnowledgeHooks]))

      # The non-authority proof still reaches the closures the observer applies.
      assert {F, [mappings: 0]} in NonAuthority.default_scope(reactor)
    end

    test "every refusal code the reactor introduces classifies without editing the table" do
      for {code, class} <- HookReactor.__sa2a_refusal_codes__() do
        assert Refusal.classify(code) == class
        refute class == :blocked_unknown and code != :hook_engine_unexpected
      end
    end
  end

  describe "Hook meta-admission (structural)" do
    test "condition identity, provenance, shape and authority are checked" do
      hook = F.hook("h-unit", "Pulse", "Pulse", "unit")
      assert :ok = Hook.validate(hook)

      mutated = %{hook | trigger: F.condition("{ ?s a h:Other }")}
      assert {:error, %{code: :hook_condition_identity_mismatch}} = Hook.validate(mutated)
      refute Hook.digest(mutated) == Hook.digest(hook)

      assert {:error, %{code: :hook_provenance_missing}} =
               Hook.validate(%{hook | provenance: %{source: "x"}})

      planted =
        F.hook("h-planted", "A", "B", "unit",
          trigger: "<urn:x> a <urn:A> .\n{ ?s a <urn:A> } => false ."
        )

      assert {:error, %{code: :hook_condition_invalid}} = Hook.validate(planted)

      authority = AshA2A.Authority.new(AshA2A.Identity.principal("p"), F.capability())

      smuggled =
        F.hook("h-smuggle", "A", "B", "unit", intent_extra: %{input: %{"nested" => [authority]}})

      assert {:error, %{code: :hook_authority_forbidden}} = Hook.validate(smuggled)
    end

    test "the real engine refuses a condition that does not match its own witness", %{
      runtime: runtime
    } do
      hook = F.hook("h-witness", "Pulse", "Pulse", "unit", witness: "<urn:w> a <urn:NotPulse> .")

      assert %{admission: admission, refused: [%{code: :hook_condition_witness_failed}]} =
               HookReactor.admit([hook], runtime: runtime)

      refute HookReactor.Admission.admitted?(admission, hook)

      good = F.hook("h-good", "Pulse", "Pulse", "unit")
      %{admission: admission, refused: []} = HookReactor.admit([good], runtime: runtime)
      assert HookReactor.Admission.admitted?(admission, good)
    end
  end

  describe "Engine and Intent identity" do
    test "canonical delta identity ignores order, prefixes and blank-node labels; bad Turtle is refused" do
      ns = F.ns()

      {:ok, a} =
        Engine.canonical_delta(
          "@prefix h: <#{ns}> .\n<urn:z> a h:X ; h:p \"v\" .\n_:b h:q <urn:z> .\n"
        )

      {:ok, b} =
        Engine.canonical_delta(
          "@prefix k: <#{ns}> .\n_:other k:q <urn:z> .\n<urn:z> k:p \"v\" .\n<urn:z> a k:X .\n"
        )

      assert a.digest == b.digest
      assert a.size == 3
      assert {:error, %{code: :hook_delta_unparseable}} = Engine.canonical_delta("@@@ nope")
    end

    test "the real engine decides a denial-body match", %{runtime: runtime} do
      {:ok, delta} = Engine.canonical_delta(F.typed_delta("Pulse", "urn:sa2a:unit"))

      assert {:ok, true} =
               Engine.matches?(runtime, delta.ntriples, F.condition("{ ?s a h:Pulse }"))

      assert {:ok, false} =
               Engine.matches?(runtime, delta.ntriples, F.condition("{ ?s a h:Other }"))

      assert {:ok, false} = Engine.matches?(runtime, "", F.condition("{ ?s a h:Pulse }"))
    end

    test "intent identity is deterministic, generation-independent, and carries no authority" do
      hook = F.hook("h-intent", "Pulse", "Pulse", "unit")
      digest = Hook.digest(hook)
      one = Intent.build(hook, digest, "delta-digest", 1)
      two = Intent.build(hook, digest, "delta-digest", 3)
      other = Intent.build(hook, digest, "other-delta", 1)

      assert one.intent_id == two.intent_id
      refute one.intent_id == other.intent_id
      assert one.standing == :candidate
      refute Map.has_key?(one, :authority)
      assert one.input["cause"] == one.intent_id
      assert Intent.command_id(one) == "hook-intent-" <> one.intent_id
    end
  end

  describe "HookReactor options" do
    test "an episode without admitted bounds is refused, not run unbounded", %{runtime: runtime} do
      assert {:error, %{code: :hook_reactor_invalid_options, detail: {:missing, :bounds}}} =
               HookReactor.run(F.typed_delta("Pulse", "urn:sa2a:unit"),
                 runtime: runtime,
                 resource_or_domain: F.Signal,
                 principal: "p"
               )
    end
  end
end
