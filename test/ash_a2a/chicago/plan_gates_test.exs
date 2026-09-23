defmodule AshA2A.Chicago.PlanGatesTest do
  @moduledoc """
  RFC-SA2A-002 Gate 4 Planning Candidate-Only (§35), Gate 5 Whole Bounded
  Plan Preflighted (§36), Plan Package Court (§58) and Planner Non-Authority
  Court (§59): the `CHI-PLAN-AUTH`, `CHI-PREFLIGHT` and `SA2A-PLAN` courts run
  end to end, plus narrow Chicago tests of the preflight boundary and the
  Strict §58 identity gate they forced.

  Real collaborators throughout: the real `AshA2A.Semantic.Admission`,
  `PlanProjection`, `PlanPackage`, `Select`, `Construct`,
  `AshA2A.Planning.Preflight`, the real `native/hddl_cli` solver,
  `AshA2A.CommandBus`, `AshA2A.Dispatcher`, `AshA2A.Agent`, real
  `AshA2A.ReceiptStore.Memory` and `AshA2A.Authority.Broker.InMemory`
  processes, ETS resources read back through `Ash.read!/1`, and the durable
  OCEL artifact read by the independent consumer. No Mock/Mox/:meck/patch.

  `async: false` -- the observer attributes every telemetry event emitted
  between a stimulus start and stop to that falsifier, and the A2A falsifiers
  point `:authority_broker` at an isolated broker for their stimulus.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo
  alias AshA2A.Chicago
  alias AshA2A.Chicago.{Query, Runner}
  alias AshA2A.Chicago.Courts.{PlanAuthority, PlanPackage, WholePlanPreflight}
  alias AshA2A.Chicago.Fixtures.Brce.Planned
  alias AshA2A.Chicago.Fixtures.PlanGates, as: Fx
  alias AshA2A.CommandBus
  alias AshA2A.Planning.{BoundedPlan, Preflight}
  alias AshA2A.Semantic.PlanPackage, as: Package
  alias AshA2A.Semantic.Refusal

  @moduletag :tmp_dir

  @courts [PlanAuthority, WholePlanPreflight, PlanPackage]

  @expected Map.merge(
              Map.new(1..5, &{"CHI-PLAN-AUTH-00#{&1}", :falsifier_killed}),
              %{
                "CHI-PLAN-AUTH-006" => :positive_control_passed,
                "CHI-PLAN-AUTH-007" => :positive_control_passed
              }
            )
            |> Map.merge(
              Map.new(1..12, fn n ->
                {"CHI-PREFLIGHT-" <> String.pad_leading("#{n}", 3, "0"), :falsifier_killed}
              end)
            )
            |> Map.put("CHI-PREFLIGHT-013", :positive_control_passed)
            |> Map.merge(
              Map.new(Enum.to_list(1..14) ++ [16], fn n ->
                {"SA2A-PLAN-" <> String.pad_leading("#{n}", 3, "0"), :falsifier_killed}
              end)
            )
            |> Map.merge(%{
              "SA2A-PLAN-015" => :positive_control_passed,
              "SA2A-PLAN-017" => :positive_control_passed
            })

  describe "CHI-PLAN-AUTH + CHI-PREFLIGHT + SA2A-PLAN end to end over the real SUT" do
    @tag timeout: 600_000
    test "every falsifier reaches its verdict and every pass is corroborated by the independent OCEL consumer",
         %{tmp_dir: dir} do
      assert {:ok, run} = Runner.run(courts: @courts, profile: :plan, evidence_dir: dir)

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})
      assert Enum.sort(Map.keys(by_id)) == Enum.sort(Map.keys(@expected))

      failures =
        for {id, verdict} <- Enum.sort(@expected),
            result = by_id[id],
            result.verdict != verdict or result.attempt_observed? != true or
              result.ocel_corroborated? != true do
          {id, result.verdict, result.detail, result.ocel_corroborated?, result.ocel_detail,
           result.evidence}
        end

      assert failures == [], inspect(failures, pretty: true, limit: :infinity)
      assert run.ocel.dropped == 0

      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))

      for gate <- [4, 5] do
        assert Enum.find(receipt["gates"], &(&1["gate"] == gate))["status"] == "PASSED"
      end

      refute receipt["standing"] == "NONCONFORMANT"

      # The independent consumer answers the Gate 4 question from the durable
      # artifact alone: the plan was SELECTED and CONSTRUCTED, the valid plan
      # was even preflight-verified at the boundary, and still nothing actuated.
      assert {:ok, index} = Query.load(Path.join(dir, "ocel.json"), run.ocel.sha256)

      for predicate <- [
            {:observed, "plan.select", %{"outcome" => "selected"}},
            {:observed, "plan.construct", %{"outcome" => "constructed"}},
            {:observed, "brce.preflight", %{"outcome" => "verified"}},
            {:observed, "brce.admission",
             %{"outcome" => "refused", "code" => "authority_required"}}
          ] do
        assert {true, _} = Query.eval(index, "CHI-PLAN-AUTH-001", predicate)
      end

      assert {false, _} = Query.eval(index, "CHI-PLAN-AUTH-001", Fx.actuation_predicate())

      # Gate 5: the mutated retry count is named by the refusal, before any claim.
      assert {true, _} =
               Query.eval(
                 index,
                 "CHI-PREFLIGHT-004",
                 {:observed, "brce.preflight",
                  %{
                    "outcome" => "refused",
                    "code" => "preflight_identity_mismatch",
                    "fields" => "retry_count"
                  }}
               )

      assert {false, _} = Query.eval(index, "CHI-PREFLIGHT-004", {:observed, "brce.claim"})
    end
  end

  describe "court declarations (§11, discovery)" do
    test "the three courts are discoverable SA2A-PLAN courts with fully declared falsifiers" do
      for court <- @courts do
        assert court in Chicago.courts_for(:plan)
        refute court in Chicago.courts_for(:logic)
      end

      assert PlanAuthority.gate() == 4
      assert WholePlanPreflight.gate() == 5
      assert PlanPackage.gate() == nil

      falsifiers = Enum.flat_map(@courts, & &1.falsifiers())
      assert Enum.sort(Enum.map(falsifiers, & &1.id)) == Enum.sort(Map.keys(@expected))

      for f <- falsifiers do
        assert f.attempt_predicate != nil, f.id
        assert f.outcome_predicate != nil, f.id
        assert :ok = Query.validate_predicate(f.attempt_predicate)
        assert :ok = Query.validate_predicate(f.outcome_predicate)
      end

      assert Enum.frequencies_by(falsifiers, & &1.kind) == %{negative: 32, positive_control: 5}
    end

    test "every BoundedPlan field is bound by the preflight identity" do
      assert Enum.sort(Preflight.bound_fields()) == WholePlanPreflight.plan_fields()
    end

    test "the new refusal codes are classified without editing the Refusal table" do
      assert Refusal.classify(:preflight_identity_mismatch) == :refused_identity
      assert Refusal.classify(:preflight_required) == :refused_bounds
      assert Refusal.classify(:plan_package_identity_missing) == :refused_plan
    end
  end

  describe "AshA2A.Planning.Preflight over a real planned candidate" do
    test "a preflighted plan's identity is stable and every bound field mutation changes it" do
      planned = Fx.planned()
      assert {:ok, again} = Preflight.preflight(planned.plan)
      assert again.preflight_digest == planned.preflight.preflight_digest

      for field <- WholePlanPreflight.plan_fields() do
        mutated = WholePlanPreflight.mutate(planned, field)

        assert {:error, %{code: :preflight_identity_mismatch, detail: %{fields: [^field]}}} =
                 Preflight.admit_step(planned.preflight, mutated, step_command(planned)),
               "#{field} is not bound"
      end
    end

    test "an unbounded whole plan is refused before any identity is issued" do
      planned = Fx.planned()

      assert {:error, %{code: :preflight_bound_exceeded, detail: %{fields: [:fan_out]}}} =
               Preflight.preflight(%{planned.plan | fan_out: 9})

      assert {:error, %{code: :preflight_bound_missing, detail: %{missing: [:retry_count]}}} =
               Preflight.preflight(%{planned.plan | retry_count: nil})

      assert {:error, %{code: :preflight_authority_ceiling_violated}} =
               Preflight.preflight(%{planned.plan | authority: :do})
    end

    test "CommandBus refuses a mutated plan step before claim and executes the preflighted one",
         %{tmp_dir: _dir} do
      planned = Fx.planned()
      [step | _] = planned.plan.steps
      name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
      start_supervised!({AshA2A.ReceiptStore.Memory, name: name})
      opts = [store_opts: [name: name], preflight: planned.preflight]

      assert {:error, %{code: :preflight_identity_mismatch}} =
               CommandBus.run(
                 Fx.step_command(step, authority: :granted),
                 Fx.step_message(step),
                 Planned,
                 opts ++ [plan: %BoundedPlan{planned.plan | retry_count: 1}]
               )

      assert Fx.consequence_rows(planned.token) == 0

      assert {:ok, receipt} =
               CommandBus.run(
                 Fx.step_command(step, authority: :granted),
                 Fx.step_message(step),
                 Planned,
                 opts ++ [plan: planned.plan]
               )

      assert receipt.plan_digest == planned.package.plan_digest
      assert Fx.consequence_rows(planned.token) == 1
    end
  end

  describe "§58 Strict identity gate" do
    test "a complete strict package builds; each withheld identity is refused" do
      {projection, _} = Fx.projection()
      token = Fx.token()
      assert {:ok, _} = Fx.package(projection, token)

      for overrides <- [
            [planning_domain_identity: nil],
            [action_identities: [], method_identities: []],
            [preconditions: [], effects: []]
          ] do
        assert {:error, %{code: :plan_package_identity_missing}} =
                 Fx.package(projection, token, overrides),
               inspect(overrides)
      end

      undeclared = token |> Fx.package_opts() |> Keyword.delete(:nondeterministic_outcomes)

      assert {:error, %{code: :plan_package_identity_missing, detail: %{missing: missing}}} =
               Package.from_projection(projection, Fx.planner_identity(), undeclared)

      assert :nondeterministic_outcomes in missing

      assert {:error,
              %{code: :plan_package_identity_missing, detail: %{missing: [:planner_identity]}}} =
               Package.from_projection(projection, "", Fx.package_opts(token))

      # Permissive stays permissive.
      assert {:ok, _} =
               Package.from_projection(
                 projection,
                 "",
                 Keyword.put(undeclared, :profile, :permissive)
               )
    end
  end

  defp step_command(planned) do
    [step | _] = planned.plan.steps
    Fx.step_command(step, authority: :granted)
  end
end
