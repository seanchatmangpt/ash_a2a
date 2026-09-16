defmodule AshA2A.Semantic.ConstructTest do
  @moduledoc """
  RFC-SA2A-001 S26: CONSTRUCT manufactures an artifact from admitted
  semantics (`A = mu(O*)`), must identify admitted inputs, manufacturer
  identity + version, target profile, produced artifact digest, and a
  construction receipt -- and implies no authority.

  The headline test manufactures with the **real** `hddl_cli` binary: a real
  `System.cmd/3` subprocess over the real
  `test/support/hddl/freedom_gym_meeting/` domain and problem, via the
  repo's existing real `AshA2A.Planning.HddlSolver.solve/3`. The artifact
  digest asserted below is a digest of a plan a real solver actually
  produced. Nothing about the manufacturer is stubbed.

  If `native/hddl_cli/target/release/hddl_cli` is not built, the real-solver
  test is a **named, visible skip** (never a silent substitution of a canned
  plan) -- the Chicago-style degradation rule. The rest of the S26 surface
  is exercised with real, simple, hand-written manufacturer functions, which
  are real implementations with real behavior, not interaction-verifying
  mocks.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Planning.HddlSolver
  alias AshA2A.Semantic.{CanonicalDigest, Construct, PlanPackage}
  alias AshA2A.SemanticSubject
  alias AshA2A.Test.SA2APlanFixture, as: Fixture

  @manufacturer_opts [
    manufacturer_identity: "AshA2A.Planning.HddlSolver",
    manufacturer_version: "hddl_cli@release"
  ]

  defp built? do
    File.exists?(HddlSolver.cli_path())
  end

  defp package_and_projection(overrides \\ []) do
    {projection, _ontology} = Fixture.projection()

    {:ok, pkg} =
      PlanPackage.from_projection(
        projection,
        "AshA2A.Planning.HddlSolver",
        Fixture.strict_opts(overrides)
      )

    {pkg, projection}
  end

  # A real 1-arity function that genuinely shells out to the real solver.
  # Not a stub point: this is the production manufacturer shape.
  defp real_hddl_manufacturer do
    domain = File.read!(Path.join(Fixture.hddl_fixture_dir(), "domain.hddl"))
    problem = File.read!(Path.join(Fixture.hddl_fixture_dir(), "problem.hddl"))

    fn %PlanPackage{} -> HddlSolver.solve(domain, problem) end
  end

  describe "S26 -- A = mu(O*) with the real hddl_cli solver" do
    @tag :hddl_cli
    test "constructs a real plan artifact and identifies everything S26 requires" do
      if built?() do
        {pkg, projection} = package_and_projection()

        assert {:ok, construction} =
                 Construct.construct(
                   pkg,
                   projection,
                   real_hddl_manufacturer(),
                   @manufacturer_opts
                 )

        # The artifact is a REAL solver result, not a fabricated map.
        assert construction.artifact["solved"] == true
        assert is_list(construction.artifact["policy"])
        assert construction.artifact["policy"] != []

        # It really planned the freedom-gym phase chain.
        actions = Enum.map(construction.artifact["policy"], & &1["action"])
        assert Enum.any?(actions, &String.contains?(&1, "advance(open,trust-god)"))
        assert Enum.any?(actions, &String.contains?(&1, "advance(fellowship,close)"))

        # produced artifact digest
        assert construction.artifact_digest =~ ~r/\Asha256:[0-9a-f]{64}\z/
        assert construction.artifact_digest == CanonicalDigest.digest(construction.artifact)

        # manufacturer identity + version
        assert construction.manufacturer_identity == "AshA2A.Planning.HddlSolver"
        assert construction.manufacturer_version == "hddl_cli@release"

        # target profile
        assert construction.target_profile == :strict

        # admitted inputs
        assert construction.admitted_input_digests == [
                 projection.source_graph_digest,
                 projection.projection_digest,
                 pkg.plan_digest
               ]

        # construction receipt
        receipt = construction.construction_receipt
        assert receipt.kind == :construction_receipt
        assert receipt.artifact_digest == construction.artifact_digest
        assert receipt.plan_digest == pkg.plan_digest
        assert receipt.source_graph_digest == projection.source_graph_digest
        assert receipt.standing == :candidate
        assert receipt.authority == :none
        assert receipt.receipt_digest =~ ~r/\Asha256:[0-9a-f]{64}\z/
      else
        IO.puts(
          "\n  SKIPPED (real hddl_cli not built at #{HddlSolver.cli_path()}): " <>
            "real-solver CONSTRUCT test. Build with: cd native/hddl_cli && cargo build --release"
        )
      end
    end

    @tag :hddl_cli
    test "manufacturing the same plan twice yields the identical artifact digest" do
      if built?() do
        {pkg, projection} = package_and_projection()
        manufacturer = real_hddl_manufacturer()

        {:ok, a} = Construct.construct(pkg, projection, manufacturer, @manufacturer_opts)
        {:ok, b} = Construct.construct(pkg, projection, manufacturer, @manufacturer_opts)

        assert a.artifact_digest == b.artifact_digest
        assert a.construction_receipt.receipt_digest == b.construction_receipt.receipt_digest
      else
        IO.puts("\n  SKIPPED (real hddl_cli not built): repeat-manufacture determinism test.")
      end
    end
  end

  describe "S26 -- identity reuses AshA2A.SemanticSubject, not a fourth digest triple" do
    test "the construction carries a real SemanticSubject built by its own constructor" do
      {pkg, projection} = package_and_projection()

      assert {:ok, construction} =
               Construct.construct(
                 pkg,
                 projection,
                 fn _pkg -> {:ok, %{plan: "p"}} end,
                 @manufacturer_opts
               )

      subject = construction.semantic_subject
      assert %SemanticSubject{} = subject

      # `Ontology.fingerprint` is bare hex; `SemanticSubject` requires the
      # "sha256:" prefix. `Construct.normalize_digest/1` adapts at the
      # boundary rather than either side being loosened -- the bare-hex
      # ontology fingerprint is still recoverable from the subject.
      assert subject.graph_digest == "sha256:" <> projection.source_graph_digest

      assert {:ok, subject.graph_digest} ==
               Construct.normalize_digest(projection.source_graph_digest)

      # `plan_digest` is already produced by CanonicalDigest in prefixed form,
      # so it passes through untouched.
      assert subject.projection_digest == pkg.plan_digest

      assert subject.manufacturer_digest ==
               Construct.manufacturer_digest(
                 "AshA2A.Planning.HddlSolver",
                 "hddl_cli@release",
                 :strict
               )

      # SemanticSubject's own real format gate accepted it, so a command can
      # carry it for replay scoping without reformatting.
      assert {:ok, ^subject} =
               SemanticSubject.new(
                 graph_digest: subject.graph_digest,
                 projection_digest: subject.projection_digest,
                 manufacturer_digest: subject.manufacturer_digest
               )
    end

    test "manufacturer_digest is stable across inputs and varies with version" do
      a = Construct.manufacturer_digest("m", "1.0.0", :strict)
      b = Construct.manufacturer_digest("m", "1.0.0", :strict)
      c = Construct.manufacturer_digest("m", "1.0.1", :strict)
      d = Construct.manufacturer_digest("m", "1.0.0", :permissive)

      assert a == b
      refute a == c
      refute a == d
    end

    test "two different artifacts from the same manufacturer share a manufacturer digest" do
      {pkg, projection} = package_and_projection()

      {:ok, one} =
        Construct.construct(pkg, projection, fn _pkg -> {:ok, %{n: 1}} end, @manufacturer_opts)

      {:ok, two} =
        Construct.construct(pkg, projection, fn _pkg -> {:ok, %{n: 2}} end, @manufacturer_opts)

      assert one.semantic_subject.manufacturer_digest ==
               two.semantic_subject.manufacturer_digest

      refute one.artifact_digest == two.artifact_digest
    end
  end

  describe "S26 -- CONSTRUCT implies no authority" do
    test "the construction and its receipt are candidate-standing and authority-free" do
      {pkg, projection} = package_and_projection()

      {:ok, construction} =
        Construct.construct(pkg, projection, fn _pkg -> {:ok, :artifact} end, @manufacturer_opts)

      assert construction.standing == :candidate
      assert construction.authority == :none
      assert construction.construction_receipt.authority == :none
    end

    test "the compiled module's real import table reaches no consequence boundary" do
      path = :code.which(Construct)
      {:ok, {Construct, [imports: imports]}} = :beam_lib.chunks(path, [:imports])
      modules = imports |> Enum.map(fn {mod, _f, _a} -> mod end) |> Enum.uniq()

      assert AshA2A.SemanticSubject in modules

      forbidden = [
        AshA2A.CommandBus,
        AshA2A.ReceiptStore,
        AshA2A.ReceiptOutbox,
        AshA2A.Receipt,
        AshA2A.Authority,
        AshA2A.KillSwitch
      ]

      assert Enum.filter(forbidden, &(&1 in modules)) == []
    end

    test "a construction receipt is not an AshA2A.Receipt and cannot pass as one" do
      {pkg, projection} = package_and_projection()

      {:ok, construction} =
        Construct.construct(pkg, projection, fn _pkg -> {:ok, :artifact} end, @manufacturer_opts)

      receipt = construction.construction_receipt

      refute match?(%AshA2A.Receipt{}, receipt)
      refute Map.has_key?(receipt, :command_id)
      refute Map.has_key?(receipt, :principal_id)
      refute Map.has_key?(receipt, :execution_id)
      refute Map.has_key?(receipt, :consequence)
    end
  end

  describe "S26/S27 -- construction refuses unverifiable admitted inputs" do
    test "a hand-edited projection cannot manufacture a canonical artifact" do
      {pkg, projection} = package_and_projection()
      edited = %{projection | goals: ["a goal nobody admitted"]}

      assert {:error, %{code: :construct_projection_unverifiable, detail: detail}} =
               Construct.construct(
                 pkg,
                 edited,
                 fn _pkg -> {:ok, :artifact} end,
                 @manufacturer_opts
               )

      assert detail.code == :projection_manual_edit_not_canonical
    end

    test "a hand-edited package cannot manufacture" do
      {pkg, projection} = package_and_projection()

      assert {:error, %{code: :construct_package_unverifiable}} =
               Construct.construct(
                 %{pkg | max_depth: 999},
                 projection,
                 fn _pkg -> {:ok, :artifact} end,
                 @manufacturer_opts
               )
    end

    test "a package and a projection that do not belong together are refused" do
      {pkg, _projection} = package_and_projection()

      {_other_pkg, other_projection} =
        package_and_projection(planning_domain_identity: "unrelated-domain")

      # Same fixture, so build a genuinely different projection instead.
      {:ok, moved_ontology} = AshA2A.Semantic.Ontology.from_ir(Fixture.admitted_ir())

      moved_planning =
        AshA2A.Semantic.PlanningIR.with_observation(Fixture.planning_ir(), %{"k" => "v"})

      {:ok, moved_projection} =
        AshA2A.Semantic.PlanProjection.from_admitted(
          %{moved_planning | ontology_fingerprint: moved_ontology.fingerprint},
          moved_ontology
        )

      refute moved_projection.projection_digest == other_projection.projection_digest

      assert {:error, %{code: :construct_projection_package_mismatch, detail: detail}} =
               Construct.construct(
                 pkg,
                 moved_projection,
                 fn _pkg -> {:ok, :artifact} end,
                 @manufacturer_opts
               )

      assert detail.package_names == pkg.projection_digest
      assert detail.projection_is == moved_projection.projection_digest
    end

    test "a real manufacturer failure is surfaced verbatim, not swallowed" do
      {pkg, projection} = package_and_projection()

      assert {:error, %{code: :construct_manufacturer_failed, detail: detail}} =
               Construct.construct(
                 pkg,
                 projection,
                 fn _pkg -> {:error, %{code: :hddl_unsolved, solved: false}} end,
                 @manufacturer_opts
               )

      assert detail == %{code: :hddl_unsolved, solved: false}
    end

    test "a manufacturer returning a non-result shape is a typed refusal" do
      {pkg, projection} = package_and_projection()

      assert {:error, %{code: :construct_manufacturer_invalid_result, detail: :whatever}} =
               Construct.construct(pkg, projection, fn _pkg -> :whatever end, @manufacturer_opts)
    end

    @tag :hddl_cli
    test "a genuinely unsolvable real problem refuses instead of manufacturing" do
      if built?() do
        dir = Path.expand("../support/hddl/unsolvable_qualification", __DIR__)
        domain = File.read!(Path.join(dir, "domain.hddl"))
        problem = File.read!(Path.join(dir, "problem.hddl"))
        {pkg, projection} = package_and_projection()

        assert {:error, %{code: :construct_manufacturer_failed, detail: detail}} =
                 Construct.construct(
                   pkg,
                   projection,
                   fn _pkg -> HddlSolver.solve(domain, problem) end,
                   @manufacturer_opts
                 )

        # The real solver's own refusal, carried through untouched.
        assert detail[:code] in [:hddl_unsolved, :hddl_solve_error]
      else
        IO.puts("\n  SKIPPED (real hddl_cli not built): unsolvable-problem refusal test.")
      end
    end
  end
end
