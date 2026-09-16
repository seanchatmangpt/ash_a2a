defmodule AshA2A.SemanticAdmissionVacuityTest do
  @moduledoc """
  Regression tests for the two reproduced admission defects in which a law
  document that asserts **nothing** produced `standing: :admitted` --
  `Unknown(Valid(x)) => Admitted(x)`, which RFC S43 forbids.

  Every case below drives the real `AshA2A.Semantic.AdmissionPipeline` against
  the real `praxis-graphlaw` wasm with the verifier's own minimal reproducing
  input, and asserts on the real returned `AshA2A.Semantic.AdmissionRefusal`
  struct. Nothing is mocked; there is no double anywhere in this file. When the
  real wasm is absent the module is a named, visible skip rather than a silent
  substitution -- the same posture
  `AshA2A.SemanticAdmissionPipelineEngineTest` already takes.

  Each defect is written as a **pair**: the vacuous candidate must refuse, and
  the corresponding real-law candidate over the same graph must reach the
  verdict the engine really produces. A test that only asserted the refusal
  would pass just as well if the pipeline had started refusing everything.
  """

  use ExUnit.Case, async: true

  alias AshA2A.GraphLaw.Wasm
  alias AshA2A.Semantic.AdmissionPipeline
  alias AshA2A.Semantic.AdmissionPipeline.Result
  alias AshA2A.Semantic.AdmissionRefusal, as: Refusal
  alias AshA2A.Test.SA2AAdmissionFixtures, as: Fixtures

  @graphlaw_availability AshA2A.GraphLaw.Wasm.availability()

  case @graphlaw_availability do
    :ok ->
      @moduletag :graphlaw

    {:error, detail} ->
      @moduletag skip:
                   "real GraphLaw wasm unavailable (#{inspect(detail)}) -- " <>
                     "these cases run the real engine and are never mocked"
  end

  defp engine_available?, do: Wasm.availability() == :ok

  describe "DEFECT 1: a required stage whose failure still yielded standing" do
    @tag :graphlaw
    test "the verifier's minimal repro -- a lawful candidate with garbage profile_ttl" do
      if engine_available?() do
        # Measured before the fix: this exact candidate returned
        # {:ok, %Result{standing: :admitted}} with
        # profile_hash == "af1349b9...", i.e. BLAKE3 of the empty string --
        # the engine had parsed zero profile axioms and reported OWL_RL
        # ADMITTED, and the pipeline's blankness guard read that as a pass.
        garbage = Fixtures.candidate(profile_ttl: "@@@ not turtle at all ;;; <<<")

        assert {:error, %Refusal{} = refusal} = AdmissionPipeline.admit(garbage)

        assert refusal.stage == :profile_checks
        assert refusal.code == :turtle_not_parseable
        assert refusal.determinacy == :undetermined
        assert refusal.detail.reason =~ "Turtle scanner error"
      end
    end

    @tag :graphlaw
    test "a profile that parses but declares no OWL/RDFS axiom is equally undetermined" do
      if engine_available?() do
        for vacuous <- ["#", "@prefix ex: <http://example.org/> .", "   \n\n  "] do
          assert {:error, %Refusal{stage: :profile_checks} = refusal} =
                   AdmissionPipeline.admit(Fixtures.candidate(profile_ttl: vacuous))

          assert refusal.code in [:profile_vacuous, :profile_not_supplied]
          assert refusal.determinacy == :undetermined
        end
      end
    end

    @tag :graphlaw
    test "the same candidate with the real profile still reaches :admitted" do
      if engine_available?() do
        assert {:ok, %Result{standing: :admitted} = result} =
                 AdmissionPipeline.admit(Fixtures.candidate())

        # The real profile is not the empty-graph digest.
        refute result.profile_hash ==
                 "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"
      end
    end
  end

  describe "DEFECT 2: Unknown(Valid(x)) => Admitted(x) (RFC S43)" do
    @tag :graphlaw
    test "the verifier's minimal repro -- a positively-refused candidate with falsifiers \"#\"" do
      if engine_available?() do
        # The engine POSITIVELY refuses this graph under the real falsifier
        # set: ex:b a ex:Forbidden fires { ?s a ex:Forbidden } => false .
        assert {:error, %Refusal{stage: :sparql_falsifiers} = determined} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(graph_ttl: Fixtures.graph_with_forbidden())
                 )

        assert determined.code == :falsifier_violated
        assert determined.determinacy == :violated

        # Change the falsifiers to a lone comment and nothing else. Measured
        # before the fix: {:ok, %Result{standing: :admitted}} -- the very graph
        # the law refuses, admitted, because zero rules found zero violations.
        assert {:error, %Refusal{stage: :sparql_falsifiers} = vacuous} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(graph_ttl: Fixtures.graph_with_forbidden(), falsifiers: "#")
                 )

        assert vacuous.code == :falsifiers_vacuous
        assert vacuous.determinacy == :undetermined
      end
    end

    @tag :graphlaw
    test "second instance -- a SHACL-nonconformant candidate with shacl_shapes \"#\"" do
      if engine_available?() do
        assert {:error, %Refusal{stage: :shacl} = determined} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(graph_ttl: Fixtures.graph_missing_owner())
                 )

        assert determined.code == :shacl_nonconformant
        assert determined.determinacy == :violated

        assert {:error, %Refusal{stage: :shacl} = vacuous} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(
                     graph_ttl: Fixtures.graph_missing_owner(),
                     shacl_shapes: "#"
                   )
                 )

        assert vacuous.code == :shacl_shapes_vacuous
        assert vacuous.determinacy == :undetermined
      end
    end

    @tag :graphlaw
    test "third instance -- a ShEx schema declaring zero shapes" do
      if engine_available?() do
        assert {:error, %Refusal{stage: :shex} = vacuous} =
                 AdmissionPipeline.admit(Fixtures.candidate(shex_schema: ~s({"shapes":[]})))

        assert vacuous.code == :shex_schema_vacuous
        assert vacuous.determinacy == :undetermined

        assert {:error, %Refusal{stage: :shex} = empty_map} =
                 AdmissionPipeline.admit(Fixtures.candidate(shex_shape_map: "[]"))

        assert empty_map.code == :shex_shape_map_vacuous
      end
    end

    @tag :graphlaw
    test "the three instances compose: vacuous law everywhere never yields standing" do
      if engine_available?() do
        # All three at once, over the graph the real law positively refuses.
        assert {:error, %Refusal{determinacy: :undetermined}} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(
                     graph_ttl: Fixtures.graph_with_forbidden(),
                     profile_ttl: "#",
                     shacl_shapes: "#",
                     falsifiers: "#"
                   )
                 )
      end
    end
  end

  describe "RFC S12 canonical identity comes from RDF.ex, not the wasm export" do
    @tag :graphlaw
    test "an admitted result carries a real RDFC-1.0 canonical hash alongside the engine digest" do
      if engine_available?() do
        assert {:ok, %Result{} = result} = AdmissionPipeline.admit(Fixtures.candidate())

        assert result.canonical_graph_hash =~ ~r/\A[0-9a-f]{64}\z/

        {:ok, graph} = RDF.Turtle.read_string(Fixtures.conforming_graph())
        assert result.canonical_graph_hash == RDF.Graph.canonical_hash(graph)
      end
    end

    @tag :graphlaw
    test "the canonical hash is blank-node-relabel invariant where the wasm digest is not" do
      if engine_available?() do
        b1 = "_:b1 <http://example.org/p> <http://example.org/o> ."
        zzz = "_:zzz9 <http://example.org/p> <http://example.org/o> ."

        {:ok, wasm_b1} = Wasm.graph_hash(b1)
        {:ok, wasm_zzz} = Wasm.graph_hash(zzz)

        {:ok, g1} = RDF.Turtle.read_string(b1)
        {:ok, g2} = RDF.Turtle.read_string(zzz)

        # Measured engine fact, asserted rather than described: the wasm
        # export is NOT blank-node-relabel invariant, so it is not RDFC-1.0.
        refute wasm_b1 == wasm_zzz

        # RDF.ex's RDFC-1.0 implementation is.
        assert RDF.Graph.canonical_hash(g1) == RDF.Graph.canonical_hash(g2)
      end
    end
  end
end
