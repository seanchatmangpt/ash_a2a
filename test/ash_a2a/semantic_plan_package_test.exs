defmodule AshA2A.Semantic.PlanPackageTest do
  @moduledoc """
  RFC-SA2A-001 S24 (the Plan Package and its required PRODUCTION bounds)
  plus the S23 gate that a package can only be built from an admitted
  projection.

  Real admission, real projection, real digests. No mocks.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{PlanPackage, PlanProjection}
  alias AshA2A.Test.SA2APlanFixture, as: Fixture

  defp package(overrides \\ []) do
    {projection, _ontology} = Fixture.projection()

    PlanPackage.from_projection(
      projection,
      "AshA2A.Planning.HddlSolver",
      Fixture.strict_opts(overrides)
    )
  end

  describe "S24 -- every required field is carried" do
    test "a strict package carries every field RFC S24 enumerates" do
      assert {:ok, pkg} = package()

      # semantic goal
      assert pkg.semantic_goal == "advance the room through every phase until it can close"
      # initial admitted state identity
      assert pkg.initial_state_identity == Fixture.planning_ir().fingerprint
      # planning-domain identity
      assert pkg.planning_domain_identity == "freedom-gym-meeting"
      # method / action identities
      assert pkg.method_identities == ["m-run-meeting"]
      assert pkg.action_identities == ["advance"]
      # preconditions / effects (the real HddlOperator fact shape)
      assert pkg.preconditions == [{:"current-phase", [:open]}]
      assert pkg.effects == [{:"current-phase", [:close]}]
      # nondeterministic outcomes where applicable
      assert pkg.nondeterministic_outcomes == []
      # consequence class
      assert pkg.consequence_class == :change
      # required capabilities
      assert pkg.required_capabilities == ["advance"]
      # bounds
      assert pkg.max_fan_out == 4
      assert pkg.max_depth == 8
      assert pkg.max_parallelism == 1
      # resource envelope
      assert pkg.resource_envelope.max_wall_ms == 5_000
      assert pkg.resource_envelope.max_memory_bytes == 64_000_000
      assert pkg.resource_envelope.max_invocations == 16
      # authority requirements (described, never granted)
      assert pkg.authority_requirements == [
               %{capability_id: "advance", mode: :required, scope: "meeting"}
             ]

      # receipt obligations
      assert pkg.receipt_obligations == [:construction_receipt, :do_receipt]
      # planner identity
      assert pkg.planner_identity == "AshA2A.Planning.HddlSolver"
      # plan digest
      assert pkg.plan_digest =~ ~r/\Asha256:[0-9a-f]{64}\z/
    end

    test "a package is candidate-standing and authority-free, unconditionally" do
      assert {:ok, pkg} = package()
      assert pkg.standing == :candidate
      assert pkg.authority == :none
    end

    test "the plan digest is a value-level digest: map field order does not change it" do
      {:ok, a} =
        package(resource_envelope: %{max_wall_ms: 1, max_memory_bytes: 2, max_invocations: 3})

      # Same map, built by inserting the keys in the opposite order.
      reordered =
        %{}
        |> Map.put(:max_invocations, 3)
        |> Map.put(:max_memory_bytes, 2)
        |> Map.put(:max_wall_ms, 1)

      {:ok, b} = package(resource_envelope: reordered)

      assert a.plan_digest == b.plan_digest
    end

    test "any content change changes the plan digest" do
      {:ok, base} = package()
      {:ok, deeper} = package(max_depth: 9)

      refute base.plan_digest == deeper.plan_digest
    end
  end

  describe "S24 -- the Strict profile MUST reject a plan missing PRODUCTION bounds" do
    test "every production bound is individually required" do
      for bound <- PlanPackage.production_bounds() do
        assert {:error, %{code: :plan_package_production_bounds_missing, detail: detail}} =
                 package([{bound, nil}]),
               "expected :strict to reject a plan missing #{inspect(bound)}"

        assert bound in detail.missing
        assert detail.profile == :strict
      end
    end

    test "the refusal names EVERY missing bound at once, not just the first" do
      assert {:error, %{code: :plan_package_production_bounds_missing, detail: detail}} =
               package(max_fan_out: nil, max_depth: nil, receipt_obligations: [])

      assert :max_fan_out in detail.missing
      assert :max_depth in detail.missing
      assert :receipt_obligations in detail.missing
    end

    test "an empty list is not a satisfied bound" do
      assert {:error, %{code: :plan_package_production_bounds_missing, detail: detail}} =
               package(required_capabilities: [])

      assert :required_capabilities in detail.missing
    end

    test "a present-but-incomplete resource envelope is refused separately" do
      assert {:error, %{code: :plan_package_resource_envelope_incomplete, detail: detail}} =
               package(resource_envelope: %{max_wall_ms: 5_000})

      assert :max_memory_bytes in detail.missing
      assert :max_invocations in detail.missing
      refute :max_wall_ms in detail.missing
    end

    test "a non-positive bound is refused as invalid, not accepted as present" do
      assert {:error, %{code: :plan_package_invalid_bound, detail: %{fields: fields}}} =
               package(max_parallelism: 0)

      assert :max_parallelism in fields
    end

    test "the permissive profile admits the same bound-free plan the strict one refuses" do
      unbounded =
        Fixture.strict_opts(
          max_fan_out: nil,
          max_depth: nil,
          max_parallelism: nil,
          resource_envelope: nil,
          consequence_class: nil,
          required_capabilities: [],
          authority_requirements: [],
          receipt_obligations: []
        )

      {projection, _ontology} = Fixture.projection()

      assert {:error, %{code: :plan_package_production_bounds_missing}} =
               PlanPackage.from_projection(projection, "planner", unbounded)

      assert {:ok, permissive} =
               PlanPackage.from_projection(
                 projection,
                 "planner",
                 Keyword.put(unbounded, :profile, :permissive)
               )

      assert permissive.profile == :permissive
    end

    test "a permissive package can never be mistaken for a strict one" do
      {:ok, strict} = package(profile: :strict)
      {:ok, permissive} = package(profile: :permissive)

      # Identical in every other field, yet distinguishable by digest --
      # a permissive plan cannot be replayed as a strict one.
      refute strict.plan_digest == permissive.plan_digest

      assert %{strict | profile: :permissive, plan_digest: nil} == %{
               permissive
               | plan_digest: nil
             }
    end

    test "a strict receiver refuses a permissively-built package without rebuilding it" do
      {:ok, permissive} =
        PlanPackage.from_projection(
          elem(Fixture.projection(), 0),
          "planner",
          Fixture.strict_opts(profile: :permissive, max_depth: nil)
        )

      assert :ok = PlanPackage.enforce_profile(permissive)

      assert {:error, %{code: :plan_package_production_bounds_missing, detail: detail}} =
               PlanPackage.enforce_profile(%{permissive | profile: :strict})

      assert :max_depth in detail.missing
    end
  end

  describe "S23 -- construction is gated on an admitted projection" do
    test "there is no constructor that takes raw input" do
      exported = PlanPackage.__info__(:functions) |> Keyword.keys() |> Enum.uniq()

      refute :new in exported
      refute :from_map in exported
      assert :from_projection in exported
    end

    test "from_projection/3 rejects anything that is not a PlanProjection struct" do
      # `apply/3` rather than a direct call: Elixir's set-theoretic type
      # checker rejects the direct call at COMPILE time (the same reason
      # `test/ash_a2a/semantic_planning_ir_test.exs` uses `apply/3` for its
      # own FunctionClauseError case). The compile-time rejection is itself
      # the S23 gate working; this asserts the runtime half of it too.
      assert_raise FunctionClauseError, fn ->
        apply(PlanPackage, :from_projection, [
          %{goals: ["forged"]},
          "planner",
          Fixture.strict_opts()
        ])
      end
    end

    test "a hand-edited projection cannot be laundered into a package (S27 upstream)" do
      {projection, _ontology} = Fixture.projection()
      edited = %{projection | goals: ["a goal nobody admitted"]}

      assert {:error, %{code: :plan_package_projection_unverifiable, detail: detail}} =
               PlanPackage.from_projection(edited, "planner", Fixture.strict_opts())

      assert detail.code == :projection_manual_edit_not_canonical
    end

    test "a projection with no goal cannot be packaged" do
      {projection, _ontology} = Fixture.projection()
      goalless = %{projection | goals: []}
      goalless = %{goalless | projection_digest: PlanProjection.content_digest(goalless)}

      assert {:error, %{code: :plan_package_semantic_goal_missing}} =
               PlanPackage.from_projection(goalless, "planner", Fixture.strict_opts())
    end

    test "the package carries the graph and projection identity forward" do
      {projection, ontology} = Fixture.projection()
      {:ok, pkg} = package()

      assert pkg.source_graph_digest == ontology.fingerprint
      assert pkg.projection_digest == projection.projection_digest
    end
  end

  describe "package tamper detection" do
    test "verify/1 admits an untouched package and refuses an edited one" do
      {:ok, pkg} = package()

      assert {:ok, ^pkg} = PlanPackage.verify(pkg)

      assert {:error, %{code: :plan_package_manual_edit_not_canonical, detail: detail}} =
               PlanPackage.verify(%{pkg | max_depth: 9_999})

      assert detail.recorded == pkg.plan_digest
      refute detail.recomputed == detail.recorded
    end
  end
end
