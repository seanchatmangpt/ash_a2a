defmodule AshA2A.Semantic.PlanPipelineTest do
  @moduledoc """
  The whole RFC-SA2A-001 planning chain in one real run:

      real source text
        -> real Admission.admit/2                      (admitted O*)
        -> real Ontology.from_ir/1                     (authoritative graph)
        -> real PlanningIR.from_ir/2
        -> PlanProjection.from_admitted/2              (S23: P = pi_plan(O*))
        -> PlanPackage.from_projection/3               (S24, :strict profile)
        -> Select.select/3                             (S25)
        -> Construct.construct/4 via real hddl_cli     (S26: A = mu(O*))

  Every hop is a real call producing real state. The manufacturer is a real
  `System.cmd/3` subprocess running the real `native/hddl_cli` binary over
  the real `test/support/hddl/freedom_gym_meeting/` domain and problem. The
  final assertions are on a plan a real solver actually emitted.

  Degrades to a named, visible skip (never a canned plan) when the binary is
  not built.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Planning.HddlSolver

  alias AshA2A.Semantic.{
    Admission,
    Construct,
    Ontology,
    PlanningIR,
    PlanPackage,
    PlanProjection,
    Select
  }

  alias AshA2A.Test.SA2APlanFixture, as: Fixture

  @tag :hddl_cli
  test "the full S23 -> S24 -> S25 -> S26 chain runs end to end on real machinery" do
    if File.exists?(HddlSolver.cli_path()) do
      # --- admitted semantics (real admission over real source text) -------
      source = Fixture.source()
      assert {:ok, ir} = Admission.admit(source, Fixture.candidate_ir())
      assert ir.standing == :admitted
      assert ir.authority == :none

      assert {:ok, ontology} = Ontology.from_ir(ir)
      assert {:ok, planning} = PlanningIR.from_ir(ir, ontology)

      # --- S23: the derived planning projection ----------------------------
      assert {:ok, projection} = PlanProjection.from_admitted(planning, ontology)
      assert projection.standing == :derived
      assert projection.source_graph_digest == ontology.fingerprint
      assert {:ok, ^projection} = PlanProjection.verify(projection, ontology)

      # --- S24: two real strict plan packages, differing only in bounds ----
      assert {:ok, tight} =
               PlanPackage.from_projection(
                 projection,
                 "AshA2A.Planning.HddlSolver",
                 Fixture.strict_opts(max_depth: 6)
               )

      assert {:ok, loose} =
               PlanPackage.from_projection(
                 projection,
                 "AshA2A.Planning.HddlSolver",
                 Fixture.strict_opts(max_depth: 12)
               )

      assert :ok = PlanPackage.enforce_profile(tight)
      refute tight.plan_digest == loose.plan_digest

      # --- S25: SELECT, under a strict profile demand ----------------------
      assert {:ok, selection} =
               Select.select([loose, tight], & &1.max_depth,
                 profile: :strict,
                 selector_identity: "PlanPipelineTest"
               )

      assert selection.chosen_digest == tight.plan_digest
      assert selection.rejected_digests == [loose.plan_digest]
      assert selection.authority == :none

      # --- S26: CONSTRUCT with the REAL hddl_cli subprocess ----------------
      domain = File.read!(Path.join(Fixture.hddl_fixture_dir(), "domain.hddl"))
      problem = File.read!(Path.join(Fixture.hddl_fixture_dir(), "problem.hddl"))

      assert {:ok, construction} =
               Construct.construct(
                 selection.chosen,
                 projection,
                 fn %PlanPackage{} -> HddlSolver.solve(domain, problem) end,
                 manufacturer_identity: "AshA2A.Planning.HddlSolver",
                 manufacturer_version: "native/hddl_cli@release"
               )

      # The artifact is a real plan from a real solver run.
      assert construction.artifact["solved"] == true

      actions = Enum.map(construction.artifact["policy"], & &1["action"])
      assert length(actions) == 6

      assert Enum.filter(actions, &String.contains?(&1, "htn:exec:")) == [
               "htn:exec:r.m1.t1:advance(open,trust-god)",
               "htn:exec:r.m1.t2:advance(trust-god,clean-house)",
               "htn:exec:r.m1.t3:advance(clean-house,help-others)",
               "htn:exec:r.m1.t4:advance(help-others,fellowship)",
               "htn:exec:r.m1.t5:advance(fellowship,close)"
             ]

      # --- the identity chain holds end to end -----------------------------
      receipt = construction.construction_receipt
      assert receipt.source_graph_digest == ontology.fingerprint
      assert receipt.projection_digest == projection.projection_digest
      assert receipt.plan_digest == selection.chosen_digest
      assert receipt.artifact_digest == construction.artifact_digest
      assert receipt.manufacturer_version == "native/hddl_cli@release"

      # --- and nothing anywhere in the chain acquired authority ------------
      assert ir.authority == :none
      assert ontology.authority == :none
      assert planning.authority == :none
      assert projection.authority == :none
      assert selection.chosen.authority == :none
      assert selection.authority == :none
      assert construction.authority == :none
      assert receipt.authority == :none
    else
      IO.puts(
        "\n  SKIPPED (real hddl_cli not built at #{HddlSolver.cli_path()}): " <>
          "full S23->S26 pipeline test. Build with: cd native/hddl_cli && cargo build --release"
      )
    end
  end

  @tag :hddl_cli
  test "S27 breaks the chain: an edited projection cannot reach CONSTRUCT" do
    if File.exists?(HddlSolver.cli_path()) do
      {projection, ontology} = Fixture.projection()

      {:ok, pkg} =
        PlanPackage.from_projection(projection, "planner", Fixture.strict_opts())

      # Somebody edits the projection to widen the goal after the fact.
      edited = %{projection | goals: ["do anything at all"]}

      assert {:error, %{code: :projection_manual_edit_not_canonical}} =
               PlanProjection.verify(edited, ontology)

      assert {:error, %{code: :plan_package_projection_unverifiable}} =
               PlanPackage.from_projection(edited, "planner", Fixture.strict_opts())

      domain = File.read!(Path.join(Fixture.hddl_fixture_dir(), "domain.hddl"))
      problem = File.read!(Path.join(Fixture.hddl_fixture_dir(), "problem.hddl"))

      # And even with an already-built valid package, the edited projection
      # is refused at manufacture time -- the real solver is never reached.
      assert {:error, %{code: :construct_projection_unverifiable}} =
               Construct.construct(
                 pkg,
                 edited,
                 fn %PlanPackage{} -> HddlSolver.solve(domain, problem) end,
                 manufacturer_identity: "AshA2A.Planning.HddlSolver",
                 manufacturer_version: "native/hddl_cli@release"
               )
    else
      IO.puts("\n  SKIPPED (real hddl_cli not built): S27 chain-break test.")
    end
  end
end
