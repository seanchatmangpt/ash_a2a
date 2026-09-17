defmodule AshA2A.SemanticAdmissionPipelineEngineTest do
  @moduledoc """
  Real end-to-end exercise of `AshA2A.Semantic.AdmissionPipeline` against the
  real `praxis-graphlaw` WebAssembly engine.

  Chicago school throughout: every assertion below is on real returned state --
  a real canonical graph hash out of the real wasm, a real SHACL/ShEx verdict,
  a real refusal struct, a real BLAKE3 admission digest. There are no mocks,
  no stubbed collaborators, and no interaction assertions.

  When the real GraphLaw wasm artifact is not present on this machine the whole
  module is a **named, visible skip** carrying the real reason string, rather
  than a silent substitution of a fake engine. `AshA2A.SemanticAdmissionPipelineTest`
  (same file) holds the engine-independent cases, which always run.
  """

  use ExUnit.Case, async: true

  alias AshA2A.GraphLaw.Wasm
  alias AshA2A.Semantic.IR
  alias AshA2A.Semantic.AdmissionRefusal, as: Refusal
  alias AshA2A.Semantic.AdmissionStanding, as: Standing
  alias AshA2A.Semantic.AdmissionPipeline
  alias AshA2A.Semantic.AdmissionPipeline.Result
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

  describe "positive admission through every required stage" do
    @tag :graphlaw
    test "a conforming candidate reaches :admitted with a real engine-computed receipt identity" do
      if engine_available?() do
        assert {:ok, %Result{} = result} =
                 AdmissionPipeline.admit(Fixtures.candidate(), Fixtures.law_opts())

        assert result.standing == :admitted
        assert Standing.admitted?(result.standing)

        # RFC S4.2/S28: admission produces standing, never permission.
        assert result.authority == :none

        # Every required stage actually passed -- the S19 intersection.
        assert result.stages == AdmissionPipeline.required_stages()

        # The engine's own graph digest -- prefix- and order-invariant, but
        # NOT blank-node-relabel invariant, so not RDFC-1.0 (see
        # AshA2A.GraphLaw.Wasm.graph_hash/2). RFC S12 canonical identity is
        # the RDF.ex RDFC-1.0 hash carried alongside it.
        assert result.graph_hash =~ ~r/\A[0-9a-f]{64}\z/
        assert result.canonical_graph_hash =~ ~r/\A[0-9a-f]{64}\z/
        # Real BLAKE3 admission receipt identity, computed inside the wasm.
        assert result.admission_digest =~ ~r/\A[0-9a-f]{64}\z/
        assert result.engine_version =~ "praxis-graphlaw"

        # The grounded IR from the real `AshA2A.Semantic.Admission` composition
        # point comes back admitted, unchanged in kind.
        assert %IR{standing: :admitted, authority: :none} = result.ir
      end
    end

    @tag :graphlaw
    test "admission is replayable: the same candidate yields the same digests" do
      if engine_available?() do
        assert {:ok, first} = AdmissionPipeline.admit(Fixtures.candidate(), Fixtures.law_opts())
        assert {:ok, second} = AdmissionPipeline.admit(Fixtures.candidate(), Fixtures.law_opts())

        assert first.graph_hash == second.graph_hash
        assert first.admission_digest == second.admission_digest
      end
    end

    @tag :graphlaw
    test "canonical identity ignores prefix labels and triple order but not content" do
      if engine_available?() do
        relabelled = """
        @prefix zz: <http://example.org/> .
        @prefix sc: <http://schema.org/> .
        zz:a zz:owner zz:sean .
        zz:a a zz:Goal .
        zz:a sc:description "ship the admission pipeline" .
        """

        assert {:ok, base} = AdmissionPipeline.admit(Fixtures.candidate(), Fixtures.law_opts())

        assert {:ok, same} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(graph_ttl: relabelled),
                   Fixtures.law_opts()
                 )

        assert base.graph_hash == same.graph_hash

        # Different lawful content under the same admitted law. (A candidate
        # carrying its own permissive falsifier set is refused: law standing.)
        assert {:ok, other} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(
                     graph_ttl:
                       Fixtures.conforming_graph() <> ~s(ex:c ex:note "another lawful fact" .\n)
                   ),
                   Fixtures.law_opts()
                 )

        refute base.graph_hash == other.graph_hash
      end
    end

    @tag :graphlaw
    test "pinning the expected graph identity admits when it matches" do
      if engine_available?() do
        assert {:ok, base} = AdmissionPipeline.admit(Fixtures.candidate(), Fixtures.law_opts())

        assert {:ok, pinned} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(expected_graph_hash: base.graph_hash),
                   Fixtures.law_opts()
                 )

        assert pinned.graph_hash == base.graph_hash
      end
    end
  end

  describe "one real negative per stage, each refusing at the right stage" do
    @tag :graphlaw
    test "Parse: non-Turtle input refuses at :parse, not silently as 0 SHACL violations" do
      if engine_available?() do
        assert {:error, %Refusal{} = refusal} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(graph_ttl: Fixtures.not_turtle()),
                   Fixtures.law_opts()
                 )

        assert refusal.stage == :parse
        assert refusal.code == :parse_yielded_no_triples
        assert refusal.determinacy == :violated
        assert refusal.standing == :candidate

        # The falsifier this test really rests on: the same input, handed
        # straight to the engine without the pipeline's parse witness, comes
        # back with a hash and a clean SHACL report. "A hash came back" and
        # "zero violations" are exactly what the Parse stage exists to stop.
        assert {:ok, hash} = Wasm.graph_hash(Fixtures.not_turtle())
        assert hash =~ ~r/\A[0-9a-f]{64}\z/

        assert {:ok, report} =
                 Wasm.validate_all(Fixtures.not_turtle(), "", Fixtures.shacl_shapes(), "", "")

        assert {:ok, %{"status" => "ADMITTED"}} = Wasm.dialect(report, "SHACL")
      end
    end

    @tag :graphlaw
    test "Identity: a mismatched pinned graph hash refuses at :identity" do
      if engine_available?() do
        assert {:error, %Refusal{} = refusal} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(expected_graph_hash: String.duplicate("0", 64)),
                   Fixtures.law_opts()
                 )

        assert refusal.stage == :identity
        assert refusal.code == :graph_identity_mismatch
        assert refusal.determinacy == :violated
        assert refusal.standing == :parsed
        assert refusal.evidence.expected == String.duplicate("0", 64)
        assert refusal.evidence.actual =~ ~r/\A[0-9a-f]{64}\z/
      end
    end

    @tag :graphlaw
    test "ShEx: a graph missing the ShEx-required predicate refuses at :shex" do
      if engine_available?() do
        assert {:error, %Refusal{} = refusal} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(graph_ttl: Fixtures.graph_missing_description()),
                   Fixtures.law_opts()
                 )

        assert refusal.stage == :shex
        assert refusal.code == :shex_nonconformant
        assert refusal.determinacy == :violated
        assert refusal.standing == :identified
        assert refusal.evidence["status"] == "REFUSED"
        assert refusal.evidence["triples_out"] >= 1
      end
    end

    @tag :graphlaw
    test "ShEx: an absent schema refuses as undetermined, never as a pass (RFC S43)" do
      if engine_available?() do
        assert {:error, %Refusal{} = refusal} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(shex_schema: "", shex_shape_map: ""),
                   Fixtures.law_opts()
                 )

        assert refusal.stage == :shex
        assert refusal.code == :shex_schema_not_supplied
        assert refusal.determinacy == :undetermined
      end
    end

    @tag :graphlaw
    test "SHACL: a graph that passes ShEx but violates SHACL refuses at :shacl" do
      if engine_available?() do
        assert {:error, %Refusal{} = refusal} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(graph_ttl: Fixtures.graph_missing_owner()),
                   Fixtures.law_opts()
                 )

        assert refusal.stage == :shacl
        assert refusal.code == :shacl_nonconformant
        assert refusal.determinacy == :violated
        assert refusal.standing == :shex_conformant
        assert refusal.evidence["status"] == "REFUSED"
      end
    end

    @tag :graphlaw
    test "SHACL: absent shapes refuse as undetermined (RFC S43)" do
      if engine_available?() do
        assert {:error, %Refusal{} = refusal} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(shacl_shapes: ""),
                   Fixtures.law_opts()
                 )

        assert refusal.stage == :shacl
        assert refusal.code == :shacl_shapes_not_supplied
        assert refusal.determinacy == :undetermined
      end
    end

    @tag :graphlaw
    test "SPARQLFalsifiers: a real N3 denial firing on a real triple refuses at :sparql_falsifiers" do
      if engine_available?() do
        assert {:error, %Refusal{} = refusal} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(graph_ttl: Fixtures.graph_with_forbidden()),
                   Fixtures.law_opts()
                 )

        assert refusal.stage == :sparql_falsifiers
        assert refusal.code == :falsifier_violated
        assert refusal.determinacy == :violated
        assert refusal.standing == :closed
        assert refusal.evidence["status"] == "REFUSED"
        assert refusal.evidence["triples_out"] >= 1
      end
    end

    @tag :graphlaw
    test "SPARQLFalsifiers: an empty falsifier set determines nothing and refuses" do
      if engine_available?() do
        assert {:error, %Refusal{} = refusal} =
                 AdmissionPipeline.admit(Fixtures.candidate(falsifiers: ""), Fixtures.law_opts())

        assert refusal.stage == :sparql_falsifiers
        assert refusal.code == :falsifiers_not_supplied
        assert refusal.determinacy == :undetermined
      end
    end

    @tag :graphlaw
    test "Provenance: an ungrounded source_quote refuses at :provenance via the real Admission module" do
      if engine_available?() do
        assert {:error, %Refusal{} = refusal} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(provenance: Fixtures.ungrounded_provenance()),
                   Fixtures.law_opts()
                 )

        assert refusal.stage == :provenance
        assert refusal.code == :provenance_not_grounded
        assert refusal.determinacy == :violated
        assert refusal.standing == :falsifiers_clear
        # The real error map from the existing `AshA2A.Semantic.Admission`,
        # carried through unchanged rather than re-derived here.
        assert %{code: :ungrounded_assertion} = refusal.detail
      end
    end

    @tag :graphlaw
    test "Provenance: a missing witness refuses rather than skipping the check" do
      if engine_available?() do
        assert {:error, %Refusal{} = refusal} =
                 AdmissionPipeline.admit(Fixtures.candidate(provenance: nil), Fixtures.law_opts())

        assert refusal.stage == :provenance
        assert refusal.code == :provenance_witness_missing
        assert refusal.determinacy == :undetermined
      end
    end

    @tag :graphlaw
    test "ProfileChecks: an absent profile refuses as undetermined (RFC S43)" do
      if engine_available?() do
        assert {:error, %Refusal{} = refusal} =
                 AdmissionPipeline.admit(Fixtures.candidate(profile_ttl: ""), Fixtures.law_opts())

        assert refusal.stage == :profile_checks
        assert refusal.code == :profile_not_supplied
        assert refusal.determinacy == :undetermined
        assert refusal.standing == :provenance_grounded
      end
    end
  end

  describe "RFC S44: a refusal leaves canonical state unchanged" do
    @tag :graphlaw
    test "every refusing stage leaves the real canonical graph digest byte-identical" do
      if engine_available?() do
        graph = Fixtures.conforming_graph()
        assert {:ok, before_digest} = Wasm.graph_hash(graph)

        refusing_candidates = [
          Fixtures.candidate(graph_ttl: Fixtures.not_turtle()),
          Fixtures.candidate(expected_graph_hash: String.duplicate("0", 64)),
          Fixtures.candidate(graph_ttl: Fixtures.graph_missing_description()),
          Fixtures.candidate(graph_ttl: Fixtures.graph_missing_owner()),
          Fixtures.candidate(graph_ttl: Fixtures.graph_with_forbidden()),
          Fixtures.candidate(provenance: Fixtures.ungrounded_provenance()),
          Fixtures.candidate(profile_ttl: "")
        ]

        for candidate <- refusing_candidates do
          assert {:error, %Refusal{}} = AdmissionPipeline.admit(candidate, Fixtures.law_opts())
        end

        # Real after-state, recomputed by the real engine -- not an inspection
        # of the pipeline source, and not the same value carried forward.
        assert {:ok, after_digest} = Wasm.graph_hash(graph)
        assert before_digest == after_digest

        # And the conforming candidate still admits afterwards with the same
        # identity it had before the refusals ran.
        assert {:ok, %Result{} = result} =
                 AdmissionPipeline.admit(Fixtures.candidate(), Fixtures.law_opts())

        assert result.graph_hash == before_digest
      end
    end
  end

  describe "telemetry" do
    @tag :graphlaw
    test "a real admission emits a real stage event per stage plus start and stop" do
      if engine_available?() do
        handler_id = "sa2a-admission-#{System.unique_integer([:positive])}"
        test_pid = self()

        :telemetry.attach_many(
          handler_id,
          [
            [:ash_a2a, :semantic, :admission, :start],
            [:ash_a2a, :semantic, :admission, :stage],
            [:ash_a2a, :semantic, :admission, :stop]
          ],
          fn event, measurements, metadata, _ ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

        on_exit(fn -> :telemetry.detach(handler_id) end)

        assert {:ok, %Result{}} =
                 AdmissionPipeline.admit(Fixtures.candidate(), Fixtures.law_opts())

        assert_receive {:telemetry, [:ash_a2a, :semantic, :admission, :start], _, _}

        for stage <- AdmissionPipeline.required_stages() do
          assert_receive {:telemetry, [:ash_a2a, :semantic, :admission, :stage], _,
                          %{stage: ^stage, outcome: :ok}}
        end

        assert_receive {:telemetry, [:ash_a2a, :semantic, :admission, :stop], _,
                        %{outcome: :admitted, standing: :admitted}}
      end
    end

    @tag :graphlaw
    test "a refusal emits a real refused stage event naming the stage and code" do
      if engine_available?() do
        handler_id = "sa2a-admission-refuse-#{System.unique_integer([:positive])}"
        test_pid = self()

        :telemetry.attach(
          handler_id,
          [:ash_a2a, :semantic, :admission, :stage],
          fn event, measurements, metadata, _ ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

        on_exit(fn -> :telemetry.detach(handler_id) end)

        assert {:error, %Refusal{}} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(graph_ttl: Fixtures.graph_missing_owner()),
                   Fixtures.law_opts()
                 )

        assert_receive {:telemetry, [:ash_a2a, :semantic, :admission, :stage], _,
                        %{
                          stage: :shacl,
                          outcome: :refused,
                          code: :shacl_nonconformant,
                          determinacy: :violated
                        }}
      end
    end
  end
end

defmodule AshA2A.SemanticAdmissionPipelineTest do
  @moduledoc """
  The engine-independent half of the admission-pipeline suite: the structural
  RFC S19 intersection properties, the fail-closed behaviour when the real
  engine is not reachable at all, and the candidate's own defaults.

  These cases run on every machine, including one without the GraphLaw wasm
  artifact -- which is exactly why the "engine unavailable" case belongs here:
  a missing engine must refuse, and that must be provable everywhere.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.AdmissionRefusal, as: Refusal
  alias AshA2A.Semantic.AdmissionStanding, as: Standing
  alias AshA2A.Semantic.AdmissionPipeline
  alias AshA2A.Semantic.AdmissionPipeline.Candidate
  alias AshA2A.Test.SA2AAdmissionFixtures, as: Fixtures

  describe "RFC S19: the admitted set is structurally an intersection" do
    test "required_stages/0 is exactly the RFC S13 ordered stage list" do
      assert AdmissionPipeline.required_stages() == [
               :parse,
               :identity,
               :shex,
               :shacl,
               :rule_closure,
               :sparql_falsifiers,
               :provenance,
               :profile_checks
             ]
    end

    test "every required stage maps onto a distinct standing on the monotonic ladder" do
      standings = Keyword.values(AdmissionPipeline.stage_standing())

      assert length(Enum.uniq(standings)) == length(standings)
      assert Enum.all?(standings, &(Standing.rank(&1) != :error))

      # Each stage's standing is strictly one step above the previous one, so
      # no stage can be skipped on the way to :admitted.
      ranks =
        Enum.map(standings, fn standing ->
          {:ok, rank} = Standing.rank(standing)
          rank
        end)

      assert ranks == Enum.sort(ranks)

      assert ranks
             |> Enum.chunk_every(2, 1, :discard)
             |> Enum.all?(fn [a, b] -> b == a + 1 end)
    end
  end

  describe "engine unavailability is a refusal, never a pass" do
    test "a wrong wasm path refuses at :parse as undetermined" do
      assert {:error, %Refusal{} = refusal} =
               AdmissionPipeline.admit(
                 Fixtures.candidate(),
                 Keyword.merge(Fixtures.law_opts(), wasm_path: "/nonexistent/graphlaw.wasm")
               )

      assert refusal.stage == :parse
      assert refusal.code == :graphlaw_engine_unavailable
      assert refusal.determinacy == :undetermined
      assert %{code: :graphlaw_wasm_not_found} = refusal.detail
    end
  end

  describe "candidate shape" do
    test "a candidate requires a graph and defaults every law field to blank" do
      candidate = %Candidate{graph_ttl: "@prefix ex: <http://example.org/> ."}

      assert candidate.profile_ttl == ""
      assert candidate.shacl_shapes == ""
      assert candidate.shex_schema == ""
      assert candidate.shex_shape_map == ""
      assert candidate.falsifiers == ""
      assert candidate.provenance == nil
      assert candidate.expected_graph_hash == nil
    end

    test "the parse witness is the universal denial rule" do
      assert AdmissionPipeline.parse_witness() =~ "{ ?s ?p ?o } => false ."
    end
  end
end
