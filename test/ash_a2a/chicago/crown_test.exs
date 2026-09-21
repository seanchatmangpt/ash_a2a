defmodule AshA2A.Chicago.CrownTest do
  @moduledoc """
  RFC-SA2A-002 Chicago Crown assembly (`AshA2A.Chicago.Crown`), Chicago
  style: every assertion below is over real discovered court modules, a real
  `AshA2A.Chicago.Runner.run/1` execution, and the real, currently-executable
  `AshA2A.Semantic.Conformance.requirement_results/0` -- no mocked court, no
  hand-typed fake receipt.

  `async: false`: shares the observer-attribution discipline of the other
  Chicago test files that drive a real `AshA2A.Chicago.Runner.run/1`.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.Chicago

  alias AshA2A.Chicago.Courts.{
    CanonicalGraphIdentity,
    CanonicalMutation,
    ExactIdentity,
    ExecutableWorld,
    GeneratedProjection,
    PublicSemanticsNamespace,
    RealCollaborators
  }

  alias AshA2A.Chicago.{CourtManifest, Crown, Runner}
  alias AshA2A.Semantic.Conformance

  @moduletag :tmp_dir

  # The same real, currently-passing court set as
  # `AshA2A.Chicago.CanonicalIdentityProjectionTest` (51 falsifiers, ~2s):
  # reused here rather than re-run, so the marginal cost of this file is only
  # the Crown assertions layered on top of one real run.
  @projection_courts [
    CanonicalGraphIdentity,
    PublicSemanticsNamespace,
    GeneratedProjection,
    CanonicalMutation
  ]

  describe "§98 mandatory-corpus registry, over the full discovered corpus" do
    test "every one of the fourteen mandatory members resolves to a real declared falsifier" do
      coverage = Crown.mandatory_corpus_coverage()

      assert length(coverage) == 14

      assert Enum.all?(coverage, & &1["resolved"]),
             inspect(Enum.reject(coverage, & &1["resolved"]))

      assert Crown.mandatory_corpus_gaps() == []
    end
  end

  describe "§98 mandatory-corpus registry, over a real restricted court subset" do
    test "a court subset that only implements 3 of the 14 members surfaces exactly those real gaps" do
      courts = [CanonicalGraphIdentity, CanonicalMutation]
      coverage = Crown.mandatory_corpus_coverage(courts)
      gaps = Crown.mandatory_corpus_gaps(courts)

      resolved_ids =
        coverage |> Enum.filter(& &1["resolved"]) |> Enum.map(& &1["id"]) |> Enum.sort()

      assert resolved_ids ==
               Enum.sort([
                 "semantic_artifact_lacking_canonical_identity",
                 "projection_attempting_to_become_canonical_source",
                 "llm_output_marked_directly_as_admitted"
               ])

      assert length(gaps) == 11
      gap_ids = Enum.map(gaps, & &1["id"])
      refute "semantic_artifact_lacking_canonical_identity" in gap_ids
      assert "consequence_without_authority_requirement" in gap_ids
    end
  end

  describe "§31 gate coverage" do
    test "the full discovered corpus leaves no required Strict gate uncovered" do
      coverage = Crown.gate_coverage(:strict)

      assert length(coverage) == 12
      assert Enum.all?(coverage, & &1["required"])
      refute Enum.any?(coverage, &(&1["status"] == "NO_COURT")), inspect(coverage)
      assert Enum.find(coverage, &(&1["gate"] == 1))["title"] == "Exact Identity Fenced"
      assert Enum.find(coverage, &(&1["gate"] == 7))["title"] =~ "Sole DO Boundary"
    end

    test "a narrow real court subset shows a real NO_COURT gap for gates it does not cover" do
      coverage = Crown.gate_coverage(:strict, [CanonicalGraphIdentity])
      gate1 = Enum.find(coverage, &(&1["gate"] == 1))

      assert gate1["status"] == "NO_COURT"
      assert gate1["court_ids"] == []
    end
  end

  describe "§145 compliance matrix, §114 package completeness and Appendix C, over a real run" do
    @tag timeout: 600_000
    test "the compliance matrix maps a real RFC-SA2A-001 requirement to real courts, falsifiers and results",
         %{tmp_dir: dir} do
      assert {:ok, %{run: run, crown: crown}} =
               Crown.run(courts: @projection_courts, profile: :strict, evidence_dir: dir)

      matrix = crown["compliance_matrix"]

      assert length(matrix) == length(Conformance.requirement_results())

      # A requirement whose RFC-SA2A-001 section token (S12) is really shared
      # by SA2A-CANON's declared `rfc_sections/0`: every one of its falsifiers
      # really ran and really passed in this run (Chicago style: the pass
      # this asserts on is the pre-existing, independently-passing
      # `CanonicalIdentityProjectionTest` baseline, not a value this test
      # invents).
      row = Enum.find(matrix, &(&1["requirement_id"] == "canonical_graph_identity"))
      assert row["rfc_section"] == "S59/S12"
      assert "SA2A-CANON" in row["court_ids"]
      assert row["falsifier_ids"] != []
      assert row["result"] == "PASSED"
      assert row["exact_subject"] == get_in(run.receipt, ["subject", "identity"])
      assert row["evidence_artifact"] != nil

      # A requirement whose RFC-SA2A-001 section (S20) none of these 4
      # courts' real `rfc_sections/0` declare: a real, mechanically-detected
      # §145 open evidence gap, never silently dropped.
      no_court = Enum.find(matrix, &(&1["requirement_id"] == "safe_finite_datalog"))
      assert no_court["result"] == "NO_COURT"
      assert no_court["court_ids"] == []
      assert no_court["requirement_id"] in crown["compliance_matrix_open_gaps"]

      # §98: this 4-court set resolves exactly 3 of the 14 mandatory members
      # (SA2A-CANON-008, SA2A-CANONMUT-004, SA2A-CANONMUT-006) -- 11 real gaps.
      mandatory = crown["mandatory_corpus"]
      refute mandatory["complete?"]
      assert length(mandatory["gaps"]) == 11

      # §114: every artifact this run really produces is really reported present.
      completeness = crown["package_completeness"]

      present_names =
        completeness["artifacts"] |> Enum.filter(& &1["present"]) |> Enum.map(& &1["artifact"])

      for name <- [
            "exact-subject manifest",
            "OCEL 2.0 artifact",
            "OCEL validation receipt",
            "conformance-query results",
            "raw durable receipts",
            "final standing receipt"
          ] do
        assert name in present_names,
               "expected #{inspect(name)} present in #{inspect(present_names)}"
      end

      # An artifact this run genuinely does not track is reported absent, not fabricated.
      assert "commands and exit codes" in completeness["missing"]

      # Appendix C, answered mechanically by the real FreshConsumer, not reimplemented here.
      assert crown["fresh_consumer_outcome"] in ["reproduced", "diverged", "refused"]

      assert map_size(crown["evidence_questions"]) ==
               length(AshA2A.Chicago.FreshConsumer.questions())

      # crown.json is really written, and really hashes to its own digest.
      crown_path = Path.join(dir, "crown.json")
      assert File.exists?(crown_path)
      on_disk = JSON.decode!(File.read!(crown_path))
      assert on_disk["crown_digest"] == crown["crown_digest"]
      assert Crown.digest(on_disk) == on_disk["crown_digest"]
    end
  end

  describe "§98/§146 a mandatory-corpus gap blocks a Strict crown claim, never silently upgraded" do
    test "a real SA2A-CORE CONFORMANT run is reported PARTIAL_ALIVE, never CONFORMANT, when claimed Strict",
         %{tmp_dir: dir} do
      courts = [ExactIdentity, ExecutableWorld, RealCollaborators]
      # Self-admitted for this exact court set so §137 court-manifest drift
      # against the committed, possibly-stale `chicago_court_manifest.json`
      # cannot itself explain the standing this test asserts on.
      manifest = CourtManifest.build(courts)

      assert {:ok, run} =
               Runner.run(
                 profile: :core,
                 courts: courts,
                 evidence_dir: dir,
                 court_manifest: manifest
               )

      assert run.receipt["standing"] == "CONFORMANT"

      # Reporting honestly for the profile this run actually qualified is
      # never downgraded: the crown claim equals the run's own standing.
      honest = Crown.build(run)
      assert honest["standing"] == "CONFORMANT"
      assert honest["mandatory_corpus"]["gaps"] != []

      # The exact same real evidence, claimed Strict instead: none of these
      # three courts (gates 1-3 only) resolve any of the fourteen §98
      # mandatory members, so the Strict claim MUST NOT read CONFORMANT.
      over_claimed = Crown.build(%{run | profile: :strict})

      assert over_claimed["standing"] == "PARTIAL_ALIVE"
      assert over_claimed["claim"] =~ "mandatory RFC-SA2A-001 falsifier corpus"
      assert length(over_claimed["mandatory_corpus"]["gaps"]) == 14
      refute over_claimed["mandatory_corpus"]["complete?"]
    end
  end

  describe "discovery" do
    test "the crown module itself never registers as a discoverable court" do
      refute Crown in Chicago.courts()
    end
  end
end
