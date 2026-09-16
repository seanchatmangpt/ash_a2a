defmodule AshA2A.Chicago.IdentityGate1Test do
  @moduledoc """
  Gate 1 exact identity (RFC-SA2A-002 §5, §6, §32, §119, §120, §126),
  Chicago style: real scratch git repositories, real commits/tags/branches,
  real artifact and rule files, the real `AshA2A.Chicago.Runner`, the real
  `AshA2A.SA2A.Conformance` over the real in-BEAM Wasmtime and out-of-BEAM
  JavaScript hosts, and a real OCEL artifact read back from disk by the
  independent consumer.

  `async: false`: the observer attributes every telemetry event emitted
  between a stimulus start and stop to that falsifier.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Chicago.{Query, Requalification, Runner, StandingReceipt, Subject}
  alias AshA2A.Chicago.Courts.ExactIdentity
  alias AshA2A.Chicago.Fixtures.Identity, as: Fx
  alias AshA2A.GraphLaw.{RuntimeB, WasmexSession}
  alias AshA2A.RuntimeIdentity
  alias AshA2A.SA2A.Conformance

  @moduletag :tmp_dir

  doctest AshA2A.RuntimeIdentity

  defp runtimes_available? do
    WasmexSession.available?([]) == :ok and RuntimeB.available?([]) == :ok
  end

  describe "the CHI-ID court end to end" do
    @tag timeout: 300_000
    test "every falsifier reaches its verdict and every pass is OCEL-corroborated", %{
      tmp_dir: dir
    } do
      assert ExactIdentity in AshA2A.Chicago.courts_for(:core)

      assert {:ok, run} = Runner.run(courts: [ExactIdentity], profile: :core, evidence_dir: dir)
      by_id = Map.new(run.results, &{&1.falsifier_id, &1})

      runtime_dependent = ["CHI-ID-007", "CHI-ID-009"]

      expected =
        %{
          "CHI-ID-001" => :falsifier_killed,
          "CHI-ID-002" => :falsifier_killed,
          "CHI-ID-003" => :falsifier_killed,
          "CHI-ID-004" => :falsifier_killed,
          "CHI-ID-005" => :falsifier_killed,
          "CHI-ID-006" => :falsifier_killed,
          "CHI-ID-007" => :falsifier_killed,
          "CHI-ID-008" => :positive_control_passed,
          "CHI-ID-009" => :positive_control_passed,
          "CHI-ID-010" => :falsifier_killed,
          "CHI-ID-011" => :falsifier_killed,
          "CHI-ID-012" => :positive_control_passed,
          "CHI-ID-013" => :falsifier_killed,
          "CHI-ID-014" => :positive_control_passed
        }

      assert Enum.sort(Map.keys(by_id)) == Enum.sort(Map.keys(expected))

      for {id, verdict} <- expected do
        result = by_id[id]

        if id in runtime_dependent and not runtimes_available?() do
          IO.puts("#{id} requires the real wasm + node runtimes: #{result.detail}")
          assert result.verdict == :blocked
        else
          assert result.verdict == verdict,
                 "#{id}: #{result.verdict} -- #{result.detail} -- #{result.ocel_detail} -- " <>
                   inspect(result.evidence)

          assert result.ocel_corroborated? == true, "#{id}: #{result.ocel_detail}"
        end
      end

      # The identity refusals are real, durable and name the moved field.
      for {id, name, field} <- [
            {"CHI-ID-001", "branch", "source_revision"},
            {"CHI-ID-002", "artifact", "artifact_digests"},
            {"CHI-ID-003", "manifest", "root_manifest_digest"},
            {"CHI-ID-004", "rules", "validator_digests"},
            {"CHI-ID-005", "tag", "tag_commit"}
          ] do
        receipt =
          Path.join([dir, "chi-id", name <> "-standing", "standing_receipt.json"])
          |> File.read!()
          |> JSON.decode!()

        assert receipt["standing"] == "REFUSED", id
        assert field in receipt["subject"]["verification"]["fields"], id
        assert receipt["claim"] =~ "REFUSED", id
        assert :ok = StandingReceipt.verify_digest(receipt)
      end

      # Artifact / manifest / rule-set substitution left the source revision
      # untouched: the mismatch is exactly the substituted identity.
      for {id, field} <- [
            {"CHI-ID-002", "artifact_digests"},
            {"CHI-ID-003", "root_manifest_digest"},
            {"CHI-ID-004", "validator_digests"}
          ] do
        evidence = by_id[id].evidence
        assert evidence["claimed_source_revision"] == evidence["observed_source_revision"], id
        assert evidence["verification"]["fields"] == [field], id
      end

      receipt = run.receipt
      gate1 = Enum.find(receipt["gates"], &(&1["gate"] == 1))
      assert gate1["status"] == if(runtimes_available?(), do: "PASSED", else: "OPEN")
      assert receipt["results"]["falsifiers_survived"] == 0
      assert receipt["standing"] in ["PARTIAL_ALIVE", "UNKNOWN"]

      # The independent consumer answers the §32 question from disk: every
      # REFUSED standing was preceded by the identity verification of the
      # same subject object.
      assert {:ok, index} = Query.load(Path.join(dir, "ocel.json"), run.ocel.sha256)

      assert {true, _} =
               Query.eval(
                 index,
                 "CHI-ID-005",
                 {:precedes, "chicago.subject.verified", "chicago.run.stop", "subject"}
               )
    end
  end

  describe "Subject over a real scratch release" do
    test "binds tag, CalVer, artifact, manifest, rule set and the observed emulator", %{
      tmp_dir: dir
    } do
      release = Fx.release!(dir, "subject")
      subject = Subject.capture(release.subject_opts)

      assert subject.source_revision == release.c1
      assert subject.tag == "v26.9.16"
      assert subject.tag_commit == release.c1
      assert subject.version == "26.9.16"
      assert subject.dirty? == false
      assert Map.keys(subject.artifact_digests) == ["dist/graphlaw.wasm"]
      assert subject.root_manifest_digest == Subject.file_sha256(release.manifest)
      assert map_size(subject.validator_digests) == 2
      assert String.match?(subject.runtime["emulator_sha256"], ~r/\A[0-9a-f]{64}\z/)

      assert :ok = Subject.verify(subject, Subject.capture(release.subject_opts))
      assert {:ok, ^subject} = subject |> Subject.to_map() |> Subject.from_map()
    end

    test "a moved tag breaks TagCommit = VerifiedCommit even without a prior claim", %{
      tmp_dir: dir
    } do
      release = Fx.release!(dir, "tagonly")
      c2 = Fx.move_tag!(release)
      moved = Subject.capture(release.subject_opts)

      assert moved.source_revision == release.c1
      assert moved.tag_commit == c2
      assert {:error, {:subject_mismatch, [:tag_commit]}} = Subject.verify(moved, moved)
    end

    test "verify emits the boundary telemetry with the mismatched fields", %{tmp_dir: dir} do
      release = Fx.release!(dir, "telemetry")
      claim = Subject.capture(release.subject_opts)
      Fx.alter_manifest!(release)
      observed = Subject.capture(release.subject_opts)

      handler = {__MODULE__, make_ref()}
      parent = self()

      :telemetry.attach(
        handler,
        Subject.verified_event(),
        fn _event, _m, meta, _ -> send(parent, {:verified, meta}) end,
        nil
      )

      try do
        assert {:mismatch, claimed_identity, [:root_manifest_digest]} =
                 Subject.verify_claim(claim, observed)

        assert claimed_identity == Subject.digest(claim)
        assert_received {:verified, %{outcome: :mismatch, fields: [:root_manifest_digest]}}

        # A tampered JSON claim is refused as unreadable, never ignored.
        tampered =
          claim |> Subject.to_map() |> Map.put("identity", String.duplicate("0", 64))

        assert {:mismatch, nil, [:claimed_subject]} = Subject.verify_claim(tampered, observed)
        assert :not_claimed = Subject.verify_claim(nil, observed)
      after
        :telemetry.detach(handler)
      end
    end
  end

  describe "Runner :claimed_subject hook" do
    test "a matching claim keeps computed standing; a stale claim is REFUSED before issue", %{
      tmp_dir: dir
    } do
      release = Fx.release!(dir, "runner")
      claim = Subject.capture(release.subject_opts)

      assert {:ok, ok_run} =
               Runner.run(
                 courts: [],
                 claimed_subject: Subject.to_map(claim),
                 subject_opts: release.subject_opts,
                 evidence_dir: Path.join(dir, "match")
               )

      assert ok_run.receipt["standing"] == "UNKNOWN"
      assert ok_run.receipt["subject"]["verification"]["outcome"] == "match"

      Fx.advance_branch!(release)

      assert {:ok, stale_run} =
               Runner.run(
                 courts: [],
                 claimed_subject: claim,
                 subject_opts: release.subject_opts,
                 evidence_dir: Path.join(dir, "stale")
               )

      assert stale_run.receipt["standing"] == "REFUSED"
      assert "source_revision" in stale_run.receipt["subject"]["verification"]["fields"]
      assert stale_run.receipt["claim"] =~ "SA2A-CORE REFUSED"

      assert {:ok, unclaimed} =
               Runner.run(
                 courts: [],
                 subject_opts: release.subject_opts,
                 evidence_dir: Path.join(dir, "unclaimed")
               )

      assert unclaimed.receipt["subject"]["verification"]["outcome"] == "not_claimed"
    end
  end

  describe "Requalification (§119, §120)" do
    test "maps changed identity fields to dependent gates, fail closed on unknown fields" do
      assert Requalification.gates_for_fields([]) == []
      assert Requalification.gates_for_fields(["tag"]) == [1]
      assert Requalification.gates_for_fields(["validator_digests"]) == [1, 2, 5, 12]
      assert Requalification.gates_for_fields(["root_manifest_digest"]) == [1, 2, 5, 9, 10, 11]
      assert Requalification.gates_for_fields(["source_revision"]) == Enum.to_list(1..12)
      assert Requalification.gates_for_fields(["something_new"]) == Enum.to_list(1..12)
    end

    test "version ordering never changes the requalification set", %{tmp_dir: dir} do
      release = Fx.release!(dir, "order")
      base = Subject.capture(release.subject_opts)
      newer = %{base | version: "26.9.17"}
      older = %{base | version: "26.9.15"}

      assert Requalification.dependent_gates(base, newer) == [1]
      assert Requalification.dependent_gates(base, older) == [1]
      assert Requalification.dependent_gates(base, base) == []
      assert Requalification.changed_fields(base, newer) == ["version"]
    end

    test "a tampered prior receipt is never reused", %{tmp_dir: dir} do
      release = Fx.release!(dir, "tamper")

      {:ok, run} =
        Runner.run(courts: [], subject_opts: release.subject_opts, evidence_dir: dir)

      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      subject = Subject.capture(release.subject_opts)

      assert {:reuse, "UNKNOWN"} = Requalification.decide(receipt, subject)
      assert run.receipt["receipt_digest"] == receipt["receipt_digest"]

      tampered = Map.put(receipt, "standing", "CONFORMANT")

      assert {:requalify, %{fields: ["receipt_digest"], gates: gates}} =
               Requalification.decide(tampered, subject)

      assert gates == Enum.to_list(1..12)
    end
  end

  describe "SA2A runtime identity (§126)" do
    test "label keys collapse whitespace, case, width and zero-width variants only" do
      key = RuntimeIdentity.label_key("BEAM/Wasmex")

      for variant <- [
            "BEAM/Wasmex ",
            " beam/wasmex",
            "BEAM /\tWASMEX",
            "ＢＥＡＭ/Wasmex",
            "BEAM/​Wasmex"
          ] do
        assert RuntimeIdentity.label_key(variant) == key, inspect(variant)
      end

      refute RuntimeIdentity.label_key("BEAM/Wasmex(degraded)") == key
      refute RuntimeIdentity.label_key("Node/StandaloneJS") == key
    end

    test "the padded host label is refused as degenerate before any runtime opens" do
      assert {:error, reason} =
               Conformance.run(runtime_a: WasmexSession, runtime_b: Fx.PaddedHostRuntime)

      assert reason.code == :sa2a_identical_runtimes
      assert reason.basis == :label
    end

    test "observed identity separates the in-BEAM and out-of-BEAM hosts and joins relabelled ones" do
      if runtimes_available?() do
        {:ok, %{session: wasmex}} = WasmexSession.open([])
        {:ok, %{session: relabelled}} = Fx.RelabelledHostRuntime.open([])
        {:ok, %{session: node}} = RuntimeB.open([])

        try do
          assert {:ok, [%{"kind" => "beam_process"} = beam]} =
                   RuntimeIdentity.observe_session(wasmex)

          assert beam["engine_application"] == "wasmex"
          assert {:ok, [%{"kind" => "os_process"}]} = RuntimeIdentity.observe_session(node)

          assert RuntimeIdentity.observe_session(wasmex) ==
                   RuntimeIdentity.observe_session(relabelled)

          refute RuntimeIdentity.observe_session(wasmex) == RuntimeIdentity.observe_session(node)
          assert {:unobservable, _} = RuntimeIdentity.observe_session(%{no: :resources})
        after
          WasmexSession.close(wasmex)
          Fx.RelabelledHostRuntime.close(relabelled)
          RuntimeB.close(node)
        end
      else
        IO.puts("skipped: real wasm/node runtimes unavailable")
      end
    end
  end
end
