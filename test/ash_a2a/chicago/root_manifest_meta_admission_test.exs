defmodule AshA2A.Chicago.RootManifestMetaAdmissionTest do
  @moduledoc """
  Meta-Admission (`SA2A-META`, RFC-SA2A-002 §52, §136, §137) and Root Manifest
  (`SA2A-ROOT`, §53) courts run end to end through the real
  `AshA2A.Chicago.Runner`: the real `AshA2A.Semantic.AdmissionPipeline` over the
  real `praxis-graphlaw` wasm, real `AshA2A.Semantic.LogicClosure`, SPARQL.ex,
  `hddl_cli`, receipt stores, Root Manifests over real files, real nested
  qualification runs, the real observer and the durable OCEL artifact read back
  by the independent consumer. No mocks, no stubs.

  `async: false` -- the observer attributes every telemetry event between a
  stimulus start and stop to that falsifier.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo
  alias AshA2A.Chicago
  alias AshA2A.Chicago.{CourtManifest, Result, Runner, StandingReceipt, Subject}
  alias AshA2A.Chicago.Courts.{MetaAdmission, RootManifest}
  alias AshA2A.Chicago.Fixtures.RootManifestMeta, as: F
  alias AshA2A.Semantic.{Refusal, RootManifest.ConformanceCorpus}

  @moduletag :tmp_dir

  @engine_unavailable (case AshA2A.GraphLaw.Wasm.availability() do
                         :ok -> nil
                         {:error, detail} -> "real GraphLaw wasm unavailable: #{inspect(detail)}"
                       end)

  @meta_expected Map.new(1..19, fn n ->
                   id = "SA2A-META-" <> String.pad_leading("#{n}", 3, "0")
                   {id, if(n in 16..19, do: :positive_control_passed, else: :falsifier_killed)}
                 end)

  @root_expected Map.new(1..15, fn n ->
                   id = "SA2A-ROOT-" <> String.pad_leading("#{n}", 3, "0")
                   {id, if(n in 14..15, do: :positive_control_passed, else: :falsifier_killed)}
                 end)

  describe "end to end over the real runner" do
    @tag :graphlaw
    if @engine_unavailable, do: @tag(skip: @engine_unavailable)

    test "every falsifier reaches its verdict, OCEL-corroborated, under the admitted court manifest",
         %{tmp_dir: dir} do
      assert {:ok, run} =
               Runner.run(
                 courts: [MetaAdmission, RootManifest],
                 profile: :strict,
                 evidence_dir: dir
               )

      verdicts = Map.new(run.results, &{&1.falsifier_id, &1.verdict})
      assert verdicts == Map.merge(@meta_expected, @root_expected)

      for result <- run.results do
        assert result.ocel_corroborated? == true,
               "#{result.falsifier_id} #{result.verdict}: #{result.ocel_detail} / #{result.detail}"

        assert result.attempt_observed? == true, result.falsifier_id
      end

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})

      # §52 pipeline law: each substitute is refused by law standing at the
      # stage whose law it replaced, with canonical state unchanged.
      for {id, stage} <- [
            {"SA2A-META-001", "shex"},
            {"SA2A-META-002", "shacl"},
            {"SA2A-META-003", "rule_closure"},
            {"SA2A-META-004", "profile_checks"}
          ] do
        evidence = by_id[id].evidence
        assert evidence["refusal"] =~ "stage=#{stage} code=law_without_standing", id
        assert evidence["canonical_unchanged"] == true, id
      end

      # §52 gate kinds: the substitute's real machinery really produced a
      # positive apparent result, the artifact is not pinned, and the gate
      # still refused it -- the kill is not vacuous.
      for n <- 5..11 do
        evidence = by_id["SA2A-META-0" <> String.pad_leading("#{n}", 2, "0")].evidence
        assert evidence["apparent_positive"] == true, evidence["kind"]
        assert evidence["artifact_pinned"] == false, evidence["kind"]
        assert evidence["reply"] =~ "REFUSED_META_RIGOR", evidence["kind"]
        assert evidence["reply"] =~ "not_pinned", evidence["kind"]
      end

      assert by_id["SA2A-META-012"].evidence["reply"] =~ "semantic_mapping_receipt_unbound"
      assert by_id["SA2A-META-012"].evidence["receipt_held_by_store"] == true

      # §137: the nested runs record the exact drift, and the clean one is crowned.
      for {id, drift} <- [
            {"SA2A-META-013", "court:SA2A-METAFIX-G1:falsifier_corpus_digest"},
            {"SA2A-META-014", "ocel_validator"},
            {"SA2A-META-015", "court:SA2A-METAFIX-G3:unadmitted"}
          ] do
        evidence = by_id[id].evidence
        assert evidence["nested_standing"] == "PARTIAL_ALIVE", id
        assert evidence["court_manifest"]["verification"] == "drift", id
        assert drift in evidence["court_manifest"]["drift"], id
      end

      assert by_id["SA2A-META-019"].evidence["nested_standing"] == "CONFORMANT"

      # §53: every use-time attack is refused by the component it substituted.
      for {id, component} <- [
            {"SA2A-ROOT-002", :pins},
            {"SA2A-ROOT-003", :content_address},
            {"SA2A-ROOT-004", :canonicalization},
            {"SA2A-ROOT-005", :manufacturers},
            {"SA2A-ROOT-006", :pins},
            {"SA2A-ROOT-007", :engine},
            {"SA2A-ROOT-008", :authority_broker},
            {"SA2A-ROOT-009", :brce_contract},
            {"SA2A-ROOT-010", :receipt_law},
            {"SA2A-ROOT-011", :hash_algorithms},
            {"SA2A-ROOT-012", :version_policy}
          ] do
        assert by_id[id].evidence["refused_component"] == component, id
      end

      assert by_id["SA2A-ROOT-001"].evidence["document_bytes_changed"] == true
      assert by_id["SA2A-ROOT-001"].evidence["recorded_digest_untouched"] == true
      assert by_id["SA2A-ROOT-002"].evidence["ontology_root_bytes_match_pin"] == false
      assert by_id["SA2A-ROOT-006"].evidence["shapes_bytes_match_pin"] == false
      assert by_id["SA2A-ROOT-006"].evidence["consumer_reply"] =~ "REFUSED_META_RIGOR"
      assert by_id["SA2A-ROOT-013"].evidence["reply"] =~ "REFUSED_ROOT_CUSTODY"

      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      assert receipt["results"]["survived_ids"] == []
      assert receipt["results"]["unresolved_ids"] == []
      assert receipt["results"]["falsifiers_killed"] == 28
      assert receipt["results"]["positive_controls_passed"] == 6
      assert receipt["court"]["version"] == CourtManifest.version()
      assert receipt["court"]["manifest"]["verification"] == "admitted"

      assert receipt["court"]["ocel_validator_identity"]["module"] ==
               "AshA2A.Chicago.Ocel.Validator"

      assert is_binary(receipt["court"]["ocel_validator_identity"]["beam_md5"])
      assert receipt["subject"]["root_manifest_digest"] == committed_root_digest()
      assert StandingReceipt.verify_digest(receipt) == :ok
      assert run.ocel.dropped == 0
    end
  end

  describe "environment fault injection: engine artifact absent" do
    test "engine-backed falsifiers are blocked with the measured reason, never killed",
         %{tmp_dir: dir} do
      previous = Application.get_env(:ash_a2a, :graphlaw_wasm_path)
      Application.put_env(:ash_a2a, :graphlaw_wasm_path, Path.join(dir, "absent.wasm"))

      try do
        {:ok, run} =
          Runner.run(courts: [RootManifest, MetaAdmission], profile: :strict, evidence_dir: dir)

        by_id = Map.new(run.results, &{&1.falsifier_id, &1})

        for {id, result} <- by_id, String.starts_with?(id, "SA2A-ROOT") do
          assert result.verdict == :blocked, id
          assert result.detail =~ "engine artifact not resolvable"
        end

        for n <- ~w(001 002 003 004 005 006 007 008 009 010 011 013 014 015 016 017 019) do
          assert by_id["SA2A-META-" <> n].verdict == :blocked, n
        end

        # Boundaries that need no engine still ran for real.
        assert by_id["SA2A-META-012"].verdict == :falsifier_killed
        assert by_id["SA2A-META-018"].verdict == :positive_control_passed
        assert by_id["SA2A-META-018"].ocel_corroborated? == true
      after
        if previous,
          do: Application.put_env(:ash_a2a, :graphlaw_wasm_path, previous),
          else: Application.delete_env(:ash_a2a, :graphlaw_wasm_path)
      end
    end
  end

  describe "court declarations" do
    test "both courts are discoverable strict courts with fully declared falsifiers" do
      for {court, count} <- [{MetaAdmission, 19}, {RootManifest, 15}] do
        assert court in Chicago.courts()
        assert court.profile() == :strict
        assert length(court.falsifiers()) == count

        for f <- court.falsifiers() do
          assert String.starts_with?(f.id, court.id() <> "-")
          assert f.attempt_predicate != nil and f.outcome_predicate != nil, f.id
        end
      end

      refute F.GateCourt1 in Chicago.courts()
    end

    test "the committed court manifest admits both courts and the default validator" do
      assert {:admitted, digest} = CourtManifest.admission([MetaAdmission, RootManifest])
      assert {:ok, committed} = CourtManifest.load()
      assert committed["digest"] == digest
      assert CourtManifest.digest(committed) == digest

      ids = Enum.map(committed["courts"], & &1["id"])
      assert "SA2A-META" in ids and "SA2A-ROOT" in ids
    end
  end

  describe "court manifest and standing" do
    test "the manifest is deterministic and declaration-derived" do
      courts = F.gate_courts()
      assert CourtManifest.build(courts) == CourtManifest.build(Enum.reverse(courts))

      refute CourtManifest.build([F.GateCourt1]) == CourtManifest.build([F.GateCourt1Drifted])

      tampered = Map.put(CourtManifest.build(courts), "court_version", "chicago-court/0")
      assert {:drift, _, fields} = CourtManifest.admission(courts, [], tampered)
      assert "court_manifest_digest" in fields and "court_version" in fields

      assert {:drift, nil, [unavailable]} =
               CourtManifest.admission(courts, [], "/nonexistent.json")

      assert unavailable =~ "court_manifest_unavailable"
    end

    test "drift bars CONFORMANT in the pure recomputation, and round-trips through the receipt" do
      [f | _] = F.GateCourt1.falsifiers()

      results =
        for gate <- 1..3 do
          %{
            Result.positive(f, attempt_observed?: true, expected_outcome_observed?: true)
            | gate: gate,
              ocel_corroborated?: true
          }
        end

      facts = %{
        profile: :core,
        courts: Enum.map(1..3, &%{id: "C#{&1}", gate: &1}),
        results: results,
        ocel_validation_status: :valid,
        ocel_dropped: 0,
        source_revision: "rev",
        court_revision: String.duplicate("0", 64)
      }

      assert StandingReceipt.recompute(facts).standing == :conformant

      admitted = StandingReceipt.recompute(Map.put(facts, :court_admission, {:admitted, "d"}))
      assert admitted.standing == :conformant

      drift = {:drift, "d", ["ocel_validator"]}
      drifted = StandingReceipt.recompute(Map.put(facts, :court_admission, drift))
      assert drifted.standing == :partial_alive
      assert drifted.claim =~ "court manifest drift: ocel_validator"

      for admission <- [:not_evaluated, {:admitted, "d"}, drift] do
        assert admission |> CourtManifest.to_map() |> CourtManifest.from_map() == admission
      end
    end
  end

  describe "SUT surfaces this slice introduced" do
    test "the subject binds the committed Root Manifest's verified content address by default" do
      assert Subject.capture().root_manifest_digest == committed_root_digest()
    end

    test "new refusal codes are classified without editing the refusal table" do
      assert Refusal.classify(:law_without_standing) == :refused_meta_rigor
      assert Refusal.classify(:root_manifest_unavailable) == :refused_meta_rigor
      assert Refusal.classify(:semantic_mapping_receipt_not_held) == :refused_receipt
      assert Refusal.classify(:semantic_mapping_receipt_unbound) == :refused_receipt
      assert Refusal.classify(:court_manifest_not_an_object) == :refused_structure
    end

    test "the committed Root Manifest is reproduced from the corpus and verifies at use" do
      {:ok, rebuilt} = ConformanceCorpus.build()
      assert rebuilt.digest == committed_root_digest()

      {:ok, loaded} = AshA2A.Semantic.RootManifest.load(nil, require_engine: false)

      assert {:ok, _} =
               AshA2A.Semantic.RootManifest.verify_use(loaded, expected_digest: rebuilt.digest)

      assert loaded.brce_contract["boundary"] == "run/4"

      assert loaded.canonicalization["graph_identity"] ==
               AshA2A.Semantic.CanonicalGraph.algorithm_id()
    end
  end

  defp committed_root_digest do
    ConformanceCorpus.manifest_path() |> File.read!() |> JSON.decode!() |> Map.fetch!("digest")
  end
end
