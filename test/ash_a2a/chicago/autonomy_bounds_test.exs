defmodule AshA2A.Chicago.AutonomyBoundsTest do
  @moduledoc """
  Qualifies the Gate 6 autonomous-execution court (`CHI-AUTO`) and the
  resource-bounds court (`SA2A-BOUNDS`, incl. Benchmark B4) end to end, plus
  narrow tests of the episode executor and ledger they attack.

  Chicago style throughout: the real `AshA2A.Semantic.Episode` executor and
  ledger, real admission over real source text, the real `hddl_cli`
  subprocess, the real CommandBus, a real receipt store and authority broker,
  the real ETS `Step` resource, and a real OCEL artifact read back from disk
  by the independent consumer.

  `async: false` -- the observer attributes telemetry to the active stimulus.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Chicago
  alias AshA2A.Chicago.{Query, Result, Runner, StandingReceipt}
  alias AshA2A.Chicago.Courts.{AutonomousExecution, ResourceBounds}
  alias AshA2A.Chicago.Fixtures.AutonomyBounds, as: F
  alias AshA2A.Planning.HddlSolver
  alias AshA2A.Semantic.{BoundedProduction, Episode, Refusal}
  alias AshA2A.Semantic.Episode.Ledger

  @moduletag :tmp_dir

  @planner_dependent ["CHI-AUTO-001", "SA2A-BOUNDS-020"]

  @expected %{
    "CHI-AUTO-001" => :positive_control_passed,
    "CHI-AUTO-002" => :falsifier_killed,
    "CHI-AUTO-003" => :falsifier_killed,
    "CHI-AUTO-004" => :falsifier_killed,
    "CHI-AUTO-005" => :falsifier_killed,
    "CHI-AUTO-006" => :positive_control_passed,
    "SA2A-BOUNDS-001" => :falsifier_killed,
    "SA2A-BOUNDS-002" => :falsifier_killed,
    "SA2A-BOUNDS-003" => :falsifier_killed,
    "SA2A-BOUNDS-004" => :falsifier_killed,
    "SA2A-BOUNDS-005" => :falsifier_killed,
    "SA2A-BOUNDS-006" => :falsifier_killed,
    "SA2A-BOUNDS-007" => :falsifier_killed,
    "SA2A-BOUNDS-008" => :falsifier_killed,
    "SA2A-BOUNDS-009" => :falsifier_killed,
    "SA2A-BOUNDS-010" => :falsifier_killed,
    "SA2A-BOUNDS-011" => :falsifier_killed,
    "SA2A-BOUNDS-012" => :falsifier_killed,
    "SA2A-BOUNDS-013" => :falsifier_killed,
    "SA2A-BOUNDS-014" => :falsifier_killed,
    "SA2A-BOUNDS-015" => :positive_control_passed,
    "SA2A-BOUNDS-016" => :falsifier_killed,
    "SA2A-BOUNDS-017" => :falsifier_killed,
    "SA2A-BOUNDS-018" => :positive_control_passed,
    "SA2A-BOUNDS-019" => :positive_control_passed,
    "SA2A-BOUNDS-020" => :measured
  }

  describe "end-to-end Chicago run of CHI-AUTO and SA2A-BOUNDS" do
    test "every falsifier reaches its verdict and every pass is corroborated from the OCEL on disk",
         %{tmp_dir: dir} do
      planner? = File.exists?(HddlSolver.cli_path())

      unless planner?,
        do:
          IO.puts(
            "\n  [sa2a] hddl_cli not built: #{inspect(@planner_dependent)} expected BLOCKED"
          )

      assert {:ok, run} =
               Runner.run(
                 courts: [AutonomousExecution, ResourceBounds],
                 profile: :do,
                 evidence_dir: dir
               )

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})
      assert Enum.sort(Map.keys(by_id)) == Enum.sort(Map.keys(@expected))

      for {id, verdict} <- @expected do
        result = by_id[id]

        if id in @planner_dependent and not planner? do
          assert result.verdict == :blocked
        else
          assert result.verdict == verdict,
                 "#{id}: #{result.verdict} detail=#{result.detail} ocel=#{result.ocel_detail} " <>
                   "evidence=#{inspect(result.evidence)}"

          assert result.ocel_corroborated? == true, "#{id}: #{result.ocel_detail}"
          assert Result.counts_as_pass?(result)
        end
      end

      assert run.ocel.dropped == 0

      # Exhaustion is typed per dimension and never passes the admitted ceiling.
      for {id, resource} <- [
            {"SA2A-BOUNDS-001", :executions},
            {"SA2A-BOUNDS-008", :external_requests},
            {"SA2A-BOUNDS-009", :money_micros},
            {"SA2A-BOUNDS-010", :tokens}
          ] do
        ev = by_id[id].evidence
        assert ev["episode_outcome"] == :resource_exhausted
        assert ev["episode_resource"] == resource
        assert ev["committed"] == 2 and ev["step_rows"] == 2
      end

      assert by_id["SA2A-BOUNDS-004"].evidence["max_in_flight"] <= 2
      assert by_id["SA2A-BOUNDS-004"].evidence["max_actuation_overlap"] <= 2
      assert by_id["SA2A-BOUNDS-007"].evidence["retries"] == 2
      assert by_id["SA2A-BOUNDS-014"].evidence["token_limit"] == 2_000
      assert by_id["SA2A-BOUNDS-014"].evidence["tokens_consumed"] == 1_000

      delegation = by_id["SA2A-BOUNDS-011"].evidence
      assert delegation["from_parent"] == "bounds_delegation_not_narrowing"
      assert delegation["from_stale"] == "bounds_delegation_not_narrowing"
      assert delegation["forged_run"] == "refused:episode_envelope_unknown"
      assert delegation["fresh_run"] == "refused:episode_envelope_not_delegated"

      authority = by_id["SA2A-BOUNDS-012"].evidence
      assert authority["with_authority"] == "bounds_authority_not_delegable"
      assert authority["with_principal"] == "bounds_authority_not_delegable"
      assert authority["widened_capabilities"] == "bounds_delegation_not_narrowing"
      assert authority["limited_subplan"] == "refused:authority_required"

      edges = by_id["SA2A-BOUNDS-016"].evidence
      assert edges["tokens"] == "episode_envelope_ceiling_overflow"
      assert edges["fan_out"] == "episode_envelope_ceiling_overflow"
      assert edges["executions"] == "bounds_resource_invalid"
      assert edges["parallelism"] == "bounds_ceiling_invalid"

      if planner? do
        b4 = by_id["SA2A-BOUNDS-020"].measurements
        assert b4["planner_invocation_us"]["n"] == 3
        assert b4["planning_projection_us"]["n"] == 3
        assert b4["plan_admission_us"]["n"] == 3
        assert b4["plan_size"] == 5 and b4["planner_plan_size"] == 5
        assert b4["authority_decision_us"]["n"] == 5 and b4["do_us"]["n"] == 5
        assert b4["planning_events_carry_command"] == false
        assert b4["planning_precedes_first_actuation"] == true
        assert b4["effective_bounds"]["executions"] == 64

        auto = by_id["CHI-AUTO-001"].evidence
        assert length(auto["planned_actions"]) == 5
        assert auto["envelope_executions"].consumed == 5
      end

      # The independent consumer reads the durable artifact.
      assert {:ok, index} = Query.load(Path.join(dir, "ocel.json"), run.ocel.sha256)

      assert {true, _} =
               Query.eval(
                 index,
                 "CHI-AUTO-006",
                 {:precedes, "episode.transition.start", "brce.actuate.start", "command"}
               )

      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      assert :ok = StandingReceipt.verify_digest(receipt)
      assert receipt["results"]["falsifiers_survived"] == 0
    end
  end

  describe "discovery, mappings and refusal classification" do
    test "CHI-AUTO is a gate-6 DO court and SA2A-BOUNDS a PLAN court" do
      assert AutonomousExecution in Chicago.courts_for(:do)
      refute AutonomousExecution in Chicago.courts_for(:plan)
      assert ResourceBounds in Chicago.courts_for(:plan)
      refute ResourceBounds in Chicago.courts_for(:logic)
      assert AutonomousExecution.gate() == 6 and ResourceBounds.gate() == 6
    end

    test "every falsifier declares both OCEL predicates and the episode mappings are admitted once" do
      for court <- [AutonomousExecution, ResourceBounds], f <- court.falsifiers() do
        assert f.attempt_predicate != nil and f.outcome_predicate != nil, f.id
      end

      shared =
        [AutonomousExecution, ResourceBounds]
        |> Runner.ocel_mappings()
        |> Enum.filter(&match?([:ash_a2a, :episode | _], &1.event))

      assert length(shared) == length(F.mappings())
    end

    test "every refusal code the executor and ledger introduce classifies without editing the table" do
      codes = Map.merge(Episode.__sa2a_refusal_codes__(), Ledger.__sa2a_refusal_codes__())

      for {code, class} <- codes do
        assert Refusal.classify(code) == class
        refute class == :blocked_unknown
      end
    end
  end

  describe "episode executor and ledger (real collaborators)" do
    test "an envelope missing a dimension is refused, never defaulted" do
      spec = Keyword.delete(F.envelope_spec(), :memory_bytes)

      assert {:error, %{code: :episode_envelope_incomplete, detail: %{missing: [:memory_bytes]}}} =
               Episode.issue({:host, :test}, spec)
    end

    test "a model cannot issue an envelope" do
      assert {:error, %{code: :model_issued_budget_refused}} =
               Episode.issue({:model, "m"}, F.envelope_spec())
    end

    test "concurrent delegations of the last execution admit exactly one" do
      parent = F.envelope!(executions: 1)

      results =
        1..16
        |> Task.async_stream(fn _ -> Episode.delegate(parent, executions: 1) end,
          max_concurrency: 16
        )
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert {:ok, %{executions: %{remaining: 0}}} = Episode.snapshot(parent)
    end

    test "an episode without a control contract is refused, not run unbounded" do
      F.with_env(fn env ->
        package = F.static_package!(F.projection(), 1)

        result =
          F.run!(package, F.envelope!(), env,
            bind: F.bind(&F.record("unit-#{env.nonce}", &1)),
            control: nil
          )

        assert {result.outcome, result.code} == {:refused, :unbounded_production_operation}
        assert F.rows("unit-#{env.nonce}") == []
      end)
    end

    test "BoundedProduction bound refusals carry the state reached" do
      {:ok, contract} =
        BoundedProduction.contract("unit",
          max_steps: 3,
          max_wall_time_ms: 5_000,
          termination: fn _ -> false end
        )

      assert {:error, %{code: :bound_reached, bound: :max_steps, state: 3}} =
               BoundedProduction.run(contract, &(&1 + 1), 0)
    end
  end
end
