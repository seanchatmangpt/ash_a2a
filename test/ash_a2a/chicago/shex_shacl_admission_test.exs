defmodule AshA2A.Chicago.ShexShaclAdmissionTest do
  @moduledoc """
  Gate 2 / admission pipeline / ShEx / SHACL courts (RFC-SA2A-002 §33, §44,
  §45, §46) run end to end through the real `AshA2A.Chicago.Runner`: the real
  `AshA2A.Semantic.AdmissionPipeline`, the real `praxis-graphlaw` wasm, the
  real term and mapping registries, the real observer, and the durable OCEL
  artifact read back by the independent consumer. No mocks, no stubs.

  `async: false` -- the observer attributes every telemetry event between a
  stimulus start and stop to that falsifier.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.Chicago
  alias AshA2A.Chicago.{Query, Runner}
  alias AshA2A.Chicago.Courts.{ExecutableWorld, Shacl, Shex}
  alias AshA2A.Chicago.Fixtures.ShexShaclAdmission, as: World
  alias AshA2A.Chicago.Fixtures.ShexShaclAdmission.Evidence

  alias AshA2A.Semantic.{
    AdmissionPipeline,
    LawDocument,
    MappingRegistry,
    ShaclSeverity,
    TermRegistry
  }

  alias AshA2A.Semantic.AdmissionRefusal

  @moduletag :tmp_dir

  doctest AshA2A.Semantic.ShaclSeverity

  # Engine-backed cases are a NAMED, visible skip where the real wasm is absent
  # -- never a substituted engine.
  @engine_unavailable (case AshA2A.GraphLaw.Wasm.availability() do
                         :ok -> nil
                         {:error, detail} -> "real GraphLaw wasm unavailable: #{inspect(detail)}"
                       end)

  # Observed on the real SUT at this revision. CHI-ADM-005/006/008 survived at
  # 46e522f (meta-admission absent; named receipt accepted) and are killed by
  # the law-standing and held-receipt repairs -- the falsifiers are unchanged.
  @expected %{
    "CHI-ADM-001" => :falsifier_killed,
    "CHI-ADM-002" => :falsifier_killed,
    "CHI-ADM-003" => :falsifier_killed,
    "CHI-ADM-004" => :falsifier_killed,
    "CHI-ADM-005" => :falsifier_killed,
    "CHI-ADM-006" => :falsifier_killed,
    "CHI-ADM-007" => :falsifier_killed,
    "CHI-ADM-008" => :falsifier_killed,
    "CHI-ADM-009" => :falsifier_killed,
    "CHI-ADM-010" => :falsifier_killed,
    "CHI-ADM-011" => :positive_control_passed,
    "CHI-ADM-012" => :positive_control_passed,
    "CHI-ADM-013" => :positive_control_passed,
    "SA2A-SHEX-001" => :falsifier_killed,
    "SA2A-SHEX-002" => :falsifier_killed,
    "SA2A-SHEX-003" => :falsifier_killed,
    "SA2A-SHEX-004" => :falsifier_killed,
    "SA2A-SHEX-005" => :falsifier_killed,
    "SA2A-SHEX-006" => :positive_control_passed,
    "SA2A-SHEX-007" => :positive_control_passed,
    "SA2A-SHACL-001" => :falsifier_killed,
    "SA2A-SHACL-002" => :falsifier_killed,
    "SA2A-SHACL-003" => :falsifier_killed,
    "SA2A-SHACL-004" => :falsifier_killed,
    "SA2A-SHACL-005" => :falsifier_killed,
    "SA2A-SHACL-006" => :falsifier_killed,
    "SA2A-SHACL-007" => :falsifier_killed,
    "SA2A-SHACL-008" => :positive_control_passed,
    "SA2A-SHACL-009" => :positive_control_passed
  }

  describe "end to end over the real runner" do
    @tag :graphlaw
    if @engine_unavailable, do: @tag(skip: @engine_unavailable)

    test "every falsifier reaches its observed verdict and every verdict is OCEL-corroborated",
         %{tmp_dir: dir} do
      assert {:ok, run} =
               Runner.run(
                 courts: [ExecutableWorld, Shex, Shacl],
                 profile: :core,
                 evidence_dir: dir
               )

      verdicts = Map.new(run.results, &{&1.falsifier_id, &1.verdict})
      assert verdicts == @expected

      for result <- run.results do
        assert result.ocel_corroborated? == true,
               "#{result.falsifier_id} #{result.verdict}: #{result.ocel_detail} / #{result.detail}"

        assert result.attempt_observed? == true, result.falsifier_id
      end

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})

      # Canonical state, read independently, is unchanged by every refusal.
      for id <- ~w(SA2A-SHEX-001 SA2A-SHACL-001 CHI-ADM-002 CHI-ADM-009) do
        assert by_id[id].evidence["canonical_unchanged"] == true, id
        assert by_id[id].evidence["canonical_after"]["engine_scratch_entries"] == 0, id
      end

      assert by_id["CHI-ADM-010"].evidence["canonical_before"] ==
               by_id["CHI-ADM-010"].evidence["canonical_after"]

      # The laundering attempts are refused by law standing, at the stage whose
      # law lacked it -- not by an unrelated stage.
      assert by_id["CHI-ADM-005"].evidence["outcome"] == "refused"

      assert by_id["CHI-ADM-005"].evidence["refusal"] =~
               "stage=rule_closure code=law_without_standing"

      assert by_id["CHI-ADM-006"].evidence["outcome"] == "refused"
      assert by_id["CHI-ADM-006"].evidence["refusal"] =~ "stage=shacl code=law_without_standing"
      assert by_id["CHI-ADM-008"].evidence["reply"] =~ "semantic_mapping_receipt_not_held"

      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      refute receipt["standing"] in ["NONCONFORMANT", "CONFORMANT"]
      assert receipt["results"]["survived_ids"] == []
      assert receipt["results"]["falsifiers_killed"] == 22
      assert receipt["results"]["positive_controls_passed"] == 7
      assert receipt["results"]["unresolved_ids"] == []
      assert run.ocel.dropped == 0
    end

    @tag :graphlaw
    if @engine_unavailable, do: @tag(skip: @engine_unavailable)

    test "the independent consumer reads the ShEx/SHACL split and the admitted control from disk",
         %{tmp_dir: dir} do
      {:ok, run} = Runner.run(courts: [Shex], profile: :core, evidence_dir: dir)
      assert {:ok, index} = Query.load(Path.join(dir, "ocel.json"), run.ocel.sha256)

      assert {true, _} = Query.eval(index, "SA2A-SHEX-006", Evidence.stage(:shex, :ok))
      assert {true, _} = Query.eval(index, "SA2A-SHEX-006", Evidence.stage(:shacl, :refused))
      assert {false, _} = Query.eval(index, "SA2A-SHEX-003", Evidence.stage(:shacl))
      assert {true, _} = Query.eval(index, "SA2A-SHEX-007", Evidence.admitted())

      assert {true, _} =
               Query.eval(
                 index,
                 "SA2A-SHEX-007",
                 {:precedes, "admission.start", "admission.stop"}
               )
    end
  end

  describe "engine unavailable (environment fault injection)" do
    test "pipeline falsifiers are blocked with the measured reason, never killed", %{tmp_dir: dir} do
      previous = Application.get_env(:ash_a2a, :graphlaw_wasm_path)
      Application.put_env(:ash_a2a, :graphlaw_wasm_path, Path.join(dir, "absent.wasm"))

      try do
        {:ok, run} =
          Runner.run(courts: [Shex, ExecutableWorld], profile: :core, evidence_dir: dir)

        by_id = Map.new(run.results, &{&1.falsifier_id, &1})

        for {id, result} <- by_id, String.starts_with?(id, "SA2A-SHEX") do
          assert result.verdict == :blocked, id
          assert result.detail =~ "graphlaw_wasm_not_found"
        end

        for id <-
              ~w(CHI-ADM-002 CHI-ADM-003 CHI-ADM-004 CHI-ADM-005 CHI-ADM-006 CHI-ADM-009 CHI-ADM-010 CHI-ADM-011) do
          assert by_id[id].verdict == :blocked, id
        end

        # Boundaries that do not need the engine still ran for real.
        assert by_id["CHI-ADM-001"].verdict == :falsifier_killed
        assert by_id["CHI-ADM-001"].ocel_corroborated? == true
        assert by_id["CHI-ADM-013"].verdict == :positive_control_passed
      after
        if previous,
          do: Application.put_env(:ash_a2a, :graphlaw_wasm_path, previous),
          else: Application.delete_env(:ash_a2a, :graphlaw_wasm_path)
      end
    end
  end

  describe "court declarations" do
    test "the three courts are discoverable core courts with fully declared falsifiers" do
      for court <- [ExecutableWorld, Shex, Shacl] do
        assert court in Chicago.courts()
        assert court.gate() == 2
        assert court.profile() == :core

        for f <- court.falsifiers() do
          assert String.starts_with?(f.id, court.id() <> "-")
          assert f.attempt_predicate != nil and f.outcome_predicate != nil, f.id
        end
      end

      assert length(ExecutableWorld.falsifiers()) == 13
      assert length(Shex.falsifiers()) == 7
      assert length(Shacl.falsifiers()) == 9
    end

    test "the world law is non-vacuous under the pipeline's own obligation counts" do
      assert {:ok, 7} = LawDocument.shacl_shape_count(World.shacl_shapes())
      assert {:ok, 2} = LawDocument.shex_shape_count(World.shex_schema())
      assert {:ok, 1} = LawDocument.shex_shape_map_count(World.shex_shape_map())
      assert {:ok, 2} = LawDocument.owl_axiom_count(World.profile())
      assert LawDocument.n3_rule_count(World.falsifiers()) == 1
      assert {:ok, _graph} = LawDocument.turtle_graph(World.world_graph())
    end
  end

  describe "AshA2A.Semantic.ShaclSeverity" do
    test "Violation-only law needs no partition" do
      shapes = World.shacl_shapes() |> String.replace("sh:severity sh:Warning ;", "")
      assert {:ok, :no_non_violation_shapes} = ShaclSeverity.violations_only(shapes)
    end

    test "removes exactly the sh:Warning shape and keeps every Violation shape" do
      assert {:ok, %{violations_only: law, removed: 1}} =
               ShaclSeverity.violations_only(World.shacl_shapes())

      assert {:ok, graph} = LawDocument.turtle_graph(law)
      refute law =~ "Warning"
      refute law =~ "rdfs:comment"
      assert {:ok, 7} = LawDocument.shacl_shape_count(law)

      severities =
        for {_s, p, o} <- RDF.Graph.triples(graph),
            to_string(p) == "http://www.w3.org/ns/shacl#severity",
            do: to_string(o)

      assert severities == ["http://www.w3.org/ns/shacl#Violation"]
    end

    test "refuses a partition that would change a Violation shape's meaning" do
      prefix = "@prefix sh: <http://www.w3.org/ns/shacl#> . @prefix ex: <http://e.org/> .\n"

      referenced = """
      ex:V a sh:NodeShape ; sh:targetClass ex:C ; sh:node ex:W .
      ex:W a sh:NodeShape ; sh:severity sh:Warning ; sh:property [ sh:path ex:p ; sh:minCount 1 ] .
      """

      assert {:error, %{code: :shacl_severity_not_partitionable}} =
               ShaclSeverity.violations_only(prefix <> referenced)

      nested = """
      ex:W a sh:NodeShape ; sh:targetClass ex:C ; sh:severity sh:Warning ;
        sh:property [ sh:path ex:p ; sh:minCount 1 ] .
      """

      assert {:error, %{code: :shacl_severity_not_partitionable, reason: :carries_nested_shapes}} =
               ShaclSeverity.violations_only(prefix <> nested)

      closed = """
      ex:S a sh:NodeShape ; sh:targetClass ex:C ; sh:closed true ;
        sh:property [ sh:path ex:p ; sh:minCount 1 ; sh:severity sh:Info ] .
      """

      assert {:error,
              %{code: :shacl_severity_not_partitionable, reason: :property_of_closed_shape}} =
               ShaclSeverity.violations_only(prefix <> closed)

      custom = """
      ex:S a sh:NodeShape ; sh:targetClass ex:C ;
        sh:property [ sh:path ex:p ; sh:minCount 1 ; sh:severity ex:Advisory ] .
      """

      assert {:ok, :no_non_violation_shapes} = ShaclSeverity.violations_only(prefix <> custom)
      assert {:error, %{code: :turtle_not_parseable}} = ShaclSeverity.violations_only("@@@")
    end

    test "its refusal code is classified without editing the refusal table" do
      assert AshA2A.Semantic.Refusal.classify(:shacl_severity_not_partitionable) == :refused_shacl
    end
  end

  describe "admission pipeline severity repair against the conformance corpus" do
    @tag :graphlaw
    if @engine_unavailable, do: @tag(skip: @engine_unavailable)

    test "warning-only admits, violation-with-warning refuses at :shacl, matching the corpus sidecars",
         %{tmp_dir: dir} do
      corpus = Path.join(to_string(:code.priv_dir(:ash_a2a)), "sa2a_conformance")
      read = &File.read!(Path.join(corpus, &1))

      law = fn name -> read.(name) end

      {:ok, manifest} =
        AshA2A.Semantic.RootManifest.LawCorpus.build(Path.join(dir, "corpus-law"), [
          {"semantic_profile", law.("profile.ttl")},
          {"shacl_shapes", law.("shapes.shacl.ttl")},
          {"shex_schema", law.("schema.shex")},
          {"shex_shape_map", law.("shape_map.json")},
          {"n3_rules", law.("rules/denials.n3")}
        ])

      scratch = Path.join(dir, "scratch")
      File.mkdir_p!(scratch)

      candidate = fn vector ->
        %AdmissionPipeline.Candidate{
          graph_ttl: read.(vector),
          profile_ttl: read.("profile.ttl"),
          shacl_shapes: read.("shapes.shacl.ttl"),
          shex_schema: read.("schema.shex"),
          shex_shape_map: read.("shape_map.json"),
          falsifiers: read.("rules/denials.n3"),
          provenance: World.provenance()
        }
      end

      for {vector, sidecar} <- [
            {"base.ttl", "base.expected.json"},
            {"negative/shacl_warning_only.ttl", "negative/shacl_warning_only.expected.json"},
            {"negative/shacl_violation_and_warning.ttl",
             "negative/shacl_violation_and_warning.expected.json"},
            {"negative/shacl_violation.ttl", "negative/shacl_violation.expected.json"}
          ] do
        expected = JSON.decode!(read.(sidecar))["expected"]["sa2a_admission"]

        case AdmissionPipeline.admit(candidate.(vector),
               tmp_dir: scratch,
               root_manifest: manifest
             ) do
          {:ok, result} ->
            assert expected == "ADMITTED", vector
            assert result.standing == :admitted

          {:error, %AdmissionRefusal{} = refusal} ->
            assert expected == "REFUSED", "#{vector}: #{AdmissionRefusal.describe(refusal)}"
            assert refusal.stage == :shacl
            assert refusal.code == :shacl_nonconformant
        end
      end

      assert File.ls!(scratch) == []
    end
  end

  describe "boundary telemetry added for independent observation" do
    setup do
      pid = self()
      handler = "gate2-boundary-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler,
        [
          [:ash_a2a, :semantic, :term, :operational_use],
          [:ash_a2a, :semantic, :mapping, :register]
        ],
        fn event, _m, meta, _ -> send(pid, {event, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    test "TermRegistry reports its real decision and returns it unchanged" do
      {:ok, registry} = TermRegistry.from_cache(profile: :strict)
      term = World.unadmitted_term()

      assert {:error, %{code: :runtime_semantic_individualism_refused, return_to: :admission}} =
               TermRegistry.admit_operational_use(registry, term)

      assert_receive {[:ash_a2a, :semantic, :term, :operational_use],
                      %{
                        iri: ^term,
                        outcome: :refused,
                        code: :runtime_semantic_individualism_refused
                      }}

      assert {:ok, {:candidate, ^term}} =
               TermRegistry.admit_operational_use(registry, term, consequential?: false)

      assert_receive {_, %{iri: ^term, outcome: :candidate, code: nil, consequential: false}}

      admitted = World.admitted_term()

      assert {:ok, {:admitted, ^admitted}} =
               TermRegistry.admit_operational_use(registry, admitted)

      assert_receive {_, %{iri: ^admitted, outcome: :admitted}}
    end

    test "MappingRegistry reports its real decision and returns it unchanged" do
      assert {:error, %{code: :semantic_mapping_unadmitted}} =
               MappingRegistry.register(MappingRegistry.new(), World.mapping(nil))

      assert_receive {[:ash_a2a, :semantic, :mapping, :register],
                      %{outcome: :refused, code: :semantic_mapping_unadmitted, kind: :exact_match}}

      assert {:error, %{code: :semantic_mapping_malformed}} =
               MappingRegistry.register(MappingRegistry.new(), :not_a_map)

      assert_receive {_, %{outcome: :refused, code: :semantic_mapping_malformed, source: nil}}
    end
  end
end
