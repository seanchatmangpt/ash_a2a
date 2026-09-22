defmodule AshA2A.Chicago.CanonicalIdentityProjectionTest do
  @moduledoc """
  SA2A-CANON, SA2A-NS, SA2A-PROJECTION and SA2A-CANONMUT end to end over the
  real SUT, plus narrow Chicago-style tests for the boundary repairs those
  courts forced: `CanonicalGraph.verify_pin/1` + `RootManifest.load/2`,
  `Iri.resolve/2` steps 3-4, `PlanProjection.verify/2`, `PlanPackage.verify/1`,
  `OntologyCache.manifest/1` and `FalsifierSuite.check_update/2`.

  `async: false`: the observer attributes every telemetry event between a
  stimulus start and stop to that falsifier.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo
  alias AshA2A.Chicago.Courts.{
    CanonicalGraphIdentity,
    CanonicalMutation,
    GeneratedProjection,
    PublicSemanticsNamespace
  }

  alias AshA2A.Chicago.Fixtures.CanonicalIdentity, as: F
  alias AshA2A.Chicago.{Result, Runner, StandingReceipt}

  alias AshA2A.Semantic.{
    CanonicalGraph,
    FalsifierSuite,
    Iri,
    OntologyCache,
    PlanPackage,
    PlanProjection,
    Refusal,
    RootManifest,
    TermRegistry
  }

  alias AshA2A.Semantic.RootManifest.ConformanceCorpus

  @moduletag :tmp_dir

  @courts [
    CanonicalGraphIdentity,
    PublicSemanticsNamespace,
    GeneratedProjection,
    CanonicalMutation
  ]

  describe "the courts over the real SUT" do
    @tag timeout: 600_000
    @tag :graphlaw_engine
    test "every falsifier reaches its final verdict and every pass is OCEL-corroborated",
         %{tmp_dir: dir} do
      assert {:ok, run} = Runner.run(courts: @courts, profile: :strict, evidence_dir: dir)

      declared = Enum.flat_map(@courts, & &1.falsifiers())
      by_id = Map.new(run.results, &{&1.falsifier_id, &1})

      assert map_size(by_id) == length(declared) and length(declared) == 51

      mismatches =
        for falsifier <- declared,
            result = Map.fetch!(by_id, falsifier.id),
            expected = expected_verdict(falsifier),
            result.verdict != expected or result.ocel_corroborated? != true or
              not Result.counts_as_pass?(result) do
          "#{falsifier.id}: #{result.verdict} (expected #{expected}) corroborated=#{inspect(result.ocel_corroborated?)} " <>
            "#{inspect(result.detail)} #{inspect(result.ocel_detail)} #{inspect(result.evidence, limit: 12)}"
        end

      assert mismatches == [], Enum.join(mismatches, "\n")

      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      assert :ok = StandingReceipt.verify_digest(receipt)
      assert receipt["results"]["falsifiers_survived"] == 0
      assert receipt["results"]["survived_ids"] == []
      assert receipt["results"]["unresolved_ids"] == []
      assert run.ocel.dropped == 0

      assert by_id["SA2A-PROJECTION-001"].evidence["rederived_ontology_matches"] == true
      assert by_id["SA2A-CANONMUT-004"].evidence["o_star_unchanged"] == true
      assert by_id["SA2A-CANONMUT-003"].evidence["reply"]["injected_admitted"] == false
    end

    test "the four courts are discoverable with their assigned ids, profiles and full declarations" do
      courts = AshA2A.Chicago.courts()

      assert Enum.map(@courts, &{&1.id(), &1.profile()}) == [
               {"SA2A-CANON", :core},
               {"SA2A-NS", :core},
               {"SA2A-PROJECTION", :plan},
               {"SA2A-CANONMUT", :strict}
             ]

      for court <- @courts do
        assert court in courts
        ids = Enum.map(court.falsifiers(), & &1.id)
        assert ids == Enum.uniq(ids)

        for f <- court.falsifiers() do
          assert String.starts_with?(f.id, court.id() <> "-")
          assert f.attempt_predicate != nil and f.outcome_predicate != nil
        end
      end

      refute CanonicalMutation in AshA2A.Chicago.courts_for(:do)
      refute GeneratedProjection in AshA2A.Chicago.courts_for(:logic)
    end

    test "every refusal family has a positive control" do
      for court <- @courts do
        kinds = court.falsifiers() |> Enum.map(& &1.kind) |> Enum.uniq()
        assert :negative in kinds and :positive_control in kinds, court.id()
      end
    end
  end

  describe "canonicalization pin (SA2A-CANON-012..015 repair)" do
    test "the committed Root Manifest pins exactly the executing identity" do
      assert {:ok, manifest} = RootManifest.load(nil, require_engine: false)
      assert :ok = CanonicalGraph.verify_pin(manifest.canonicalization)

      for {key, value} <- CanonicalGraph.identity() do
        assert manifest.canonicalization[key] == value, key
      end

      assert manifest.hash_algorithms["graph_identity"] == CanonicalGraph.hash_function()
    end

    test "every drifted pin is refused with the drifted field named", %{tmp_dir: dir} do
      for drift <- [:algorithm, :hash_function, :implementation] do
        {:ok, path} = F.drifted_manifest(dir, drift)

        assert {:error, %{code: :REFUSED_MANIFEST_CANONICALIZATION_DRIFT, detail: detail}} =
                 RootManifest.load(path, F.manifest_load_opts())

        assert %{code: :refused_canonicalization_pin_drift, field: field} = detail
        assert is_binary(field)
      end

      pinned = CanonicalGraph.identity()

      assert {:error, %{code: :refused_canonicalization_pin_drift, field: "library"}} =
               CanonicalGraph.verify_pin(Map.delete(pinned, "library"))

      assert {:error, %{code: :refused_canonicalization_pin_drift}} =
               CanonicalGraph.verify_pin(:not_a_pin)
    end

    @tag :graphlaw_engine
    test "the committed manifest is still reproduced by its lawful manufacturer" do
      {:ok, rebuilt} = ConformanceCorpus.build()
      committed = ConformanceCorpus.manifest_path() |> File.read!() |> JSON.decode!()
      assert rebuilt.digest == committed["digest"]
    end
  end

  describe "namespace repairs (SA2A-NS-003..006)" do
    setup do
      {:ok, index} = TermRegistry.from_cache()
      %{index: index}
    end

    test "a textual equivalent is a candidate, not an identity", %{index: index} do
      assert {:error, %{code: :equivalent_requires_admitted_mapping, detail: detail}} =
               Iri.resolve("customer class", index: index)

      assert detail =~ "http://www.w3.org/2000/01/rdf-schema#Class"
    end

    test "a mapping without a receipt does not select an equivalent", %{index: index} do
      [target | _] = TermRegistry.search_equivalent(index, "Concept")

      assert {:error, %{code: :equivalent_requires_admitted_mapping}} =
               Iri.resolve("Concept",
                 index: index,
                 sufficient?: false,
                 mappings: [%{target: target, kind: :close_match}]
               )
    end

    test "composition refuses a mapping lacking an admission receipt", %{index: index} do
      assert {:error, %{code: :composition_mapping_unadmitted}} =
               Iri.resolve("Concept",
                 index: index,
                 sufficient?: false,
                 accept_equivalent?: false,
                 composition: [F.skos_concept(), F.owl_class()],
                 mappings: [
                   %{
                     target: F.skos_concept(),
                     kind: :exact_match,
                     admission_receipt: F.receipt("a")
                   },
                   %{target: F.owl_class(), kind: :close_match}
                 ]
               )
    end
  end

  describe "projection repairs (SA2A-PROJECTION-002, 003, 006)" do
    test "graph witness refuses content the graph does not carry, per field" do
      {_ir, ontology, _planning, projection} = F.admitted_chain()

      for {field, value} <- [
            goals: ["forged goal"],
            constraints: ["forged constraint"],
            task_candidates: [],
            nondeterminism: projection.nondeterminism ++ projection.nondeterminism,
            exclusions: ["no phase may be skipped", "forged"],
            objects: [%{"id" => "room", "type" => "schema:Person", "label" => "the room"}],
            predicates: [
              %{"subject" => "room", "predicate" => "schema:agent", "object" => "facilitator"}
            ]
          ] do
        forged = Map.put(projection, field, value)
        forged = %{forged | projection_digest: PlanProjection.content_digest(forged)}

        assert {:error, %{code: :projection_not_witnessed_by_graph, detail: %{field: ^field}}} =
                 PlanProjection.verify(forged, ontology),
               "#{field} forgery verified"
      end
    end

    test "a forged fence is refused by verify/2 and verify_self/1" do
      {_ir, ontology, _planning, projection} = F.admitted_chain()

      for forged <- [%{projection | standing: :admitted}, %{projection | authority: :full}] do
        assert {:error, %{code: :projection_manual_edit_not_canonical}} =
                 PlanProjection.verify(forged, ontology)

        assert {:error, %{code: :projection_manual_edit_not_canonical}} =
                 PlanProjection.verify_self(forged)
      end
    end

    test "a re-digested package with a forged fence is refused" do
      {_ir, _ontology, _planning, projection} = F.admitted_chain()
      {:ok, package} = PlanPackage.from_projection(projection, "hddl_cli", F.package_opts())

      assert {:error, %{code: :plan_package_manual_edit_not_canonical}} =
               PlanPackage.verify(F.forged_package(package))

      assert {:ok, ^package} = PlanPackage.verify(package)
    end
  end

  describe "canonical mutation repairs (SA2A-CANONMUT-002, 008)" do
    test "a rewritten cache manifest is not admitted, an unmodified copy is", %{tmp_dir: dir} do
      forged = F.copy_ontology_cache(dir, "forged")
      :ok = F.direct_write(forged, consistent: true)

      assert {:error, %{code: :ontology_manifest_unadmitted}} = OntologyCache.manifest(forged)

      assert {:error, %{code: :ontology_manifest_unadmitted}} =
               OntologyCache.load(F.skos_ns(), root: forged)

      untouched = F.copy_ontology_cache(dir, "untouched")
      assert {:ok, entries} = OntologyCache.manifest(untouched)
      assert length(entries) == 4
    end

    test "canonical classification wins over staging" do
      graph = F.ambiguous_classification()

      assert {:error, %{code: :refused_sparql_update_on_canonical, detail: detail}} =
               FalsifierSuite.check_update(graph, F.update(:ambiguous))

      assert detail.reason =~ "canonical"
      assert :ok = FalsifierSuite.check_update(graph, F.update(:staging))
    end
  end

  test "every new refusal code is classified without editing the Refusal table" do
    for module <- [CanonicalGraph, Iri, PlanProjection, OntologyCache],
        {code, class} <- module.__sa2a_refusal_codes__() do
      assert Refusal.classify(code) == class
    end
  end

  defp expected_verdict(%{kind: :negative}), do: :falsifier_killed
  defp expected_verdict(%{kind: :positive_control}), do: :positive_control_passed
end
