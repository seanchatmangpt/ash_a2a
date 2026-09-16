defmodule AshA2A.Chicago.FoundationTest do
  @moduledoc """
  Qualifies the RFC-SA2A-002 court machinery itself, Chicago style: real
  CommandBus, real ETS resource, real receipt store, real telemetry, a real
  OCEL artifact on disk read back by an independent consumer.

  `async: false` -- the observer attributes every telemetry event emitted
  between a stimulus start and stop to that falsifier, so concurrent tests
  driving the same boundaries would pollute attribution.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Chicago

  alias AshA2A.Chicago.{
    Context,
    Falsifier,
    Observer,
    Profile,
    Query,
    Result,
    Runner,
    StandingReceipt,
    Subject
  }

  alias AshA2A.Chicago.Ocel.Mapping
  alias AshA2A.Semantic.Refusal
  alias AshA2A.Test.ChicagoSelfTest

  @moduletag :tmp_dir

  describe "a real run over the real CommandBus" do
    test "kills the no-grant falsifier, passes the positive control, and both are OCEL-corroborated",
         %{tmp_dir: dir} do
      assert {:ok, run} =
               Runner.run(profile: :core, courts: [ChicagoSelfTest.Court], evidence_dir: dir)

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})

      negative = by_id["CHI-SELFTEST-001"]
      assert negative.verdict == :falsifier_killed
      assert negative.attempt_observed? == true
      assert negative.ocel_corroborated? == true, negative.ocel_detail

      positive = by_id["CHI-SELFTEST-002"]
      assert positive.verdict == :positive_control_passed
      assert positive.ocel_corroborated? == true, positive.ocel_detail

      # The artifact is durable and content-addressed: a fresh read of the
      # bytes on disk hashes to the digest the receipt binds.
      assert File.exists?(Path.join(dir, "ocel.json"))
      assert Subject.file_sha256(Path.join(dir, "ocel.json")) == run.ocel.sha256
      assert run.ocel.dropped == 0

      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      assert receipt["evidence"]["ocel_digest"] == run.ocel.sha256
      assert :ok = StandingReceipt.verify_digest(receipt)
      assert receipt["results"]["falsifiers_killed"] == 1
      assert receipt["results"]["positive_controls_passed"] == 1

      # Core requires gates 1-3; none are covered by the self-test court, so
      # standing is honestly PARTIAL_ALIVE, never CONFORMANT.
      assert receipt["standing"] == "PARTIAL_ALIVE"
      assert receipt["results"]["gates_missing"] == 3
      assert receipt["claim"] =~ "SA2A-CORE PARTIAL_ALIVE"
    end

    test "the independent consumer answers semantic questions from disk only", %{tmp_dir: dir} do
      {:ok, run} = Runner.run(profile: :core, courts: [ChicagoSelfTest.Court], evidence_dir: dir)

      assert {:ok, index} = Query.load(Path.join(dir, "ocel.json"), run.ocel.sha256)

      # No actuation was attributed to the denied stimulus...
      assert {false, _} = Query.eval(index, "CHI-SELFTEST-001", {:observed, "brce.actuate.start"})
      # ...while the authorized one prepared its receipt before actuating.
      assert {true, _} =
               Query.eval(
                 index,
                 "CHI-SELFTEST-002",
                 {:precedes, "brce.prepare", "brce.actuate.start", "command"}
               )

      # Tampered bytes are refused, not silently re-hashed.
      assert {:error, {:ocel_digest_mismatch, _}} =
               Query.load(Path.join(dir, "ocel.json"), String.duplicate("0", 64))
    end

    test "the OCEL artifact is object-centric OCEL 2.0 JSON", %{tmp_dir: dir} do
      {:ok, _run} = Runner.run(profile: :core, courts: [ChicagoSelfTest.Court], evidence_dir: dir)
      doc = JSON.decode!(File.read!(Path.join(dir, "ocel.json")))

      assert Enum.sort(Map.keys(doc)) == ["eventTypes", "events", "objectTypes", "objects"]
      object_ids = MapSet.new(doc["objects"], & &1["id"])

      for event <- doc["events"], rel <- event["relationships"] do
        assert MapSet.member?(object_ids, rel["objectId"])
      end

      admission = Enum.find(doc["events"], &(&1["type"] == "brce.admission"))

      related_types =
        admission["relationships"]
        |> Enum.map(& &1["objectId"])
        |> Enum.map(&hd(String.split(&1, ":")))

      assert "command" in related_types
      assert "capability" in related_types
      assert "falsifier" in related_types
    end
  end

  describe "the verdict algebra cannot be gamed" do
    test "a court that reports a kill it never attempted is downgraded to UNKNOWN", %{
      tmp_dir: dir
    } do
      {:ok, run} =
        Runner.run(profile: :core, courts: [ChicagoSelfTest.LyingCourt], evidence_dir: dir)

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})

      assert by_id["CHI-LIAR-001"].verdict == :unknown
      assert by_id["CHI-LIAR-001"].failure_class == :ocel_evidence_incomplete
      assert by_id["CHI-LIAR-002"].verdict == :unknown
      assert by_id["CHI-LIAR-002"].detail =~ "vacuity guard"
      assert run.receipt["standing"] == "UNKNOWN"
    end

    test "a crashing court yields UNKNOWN for every declared falsifier, never a pass", %{
      tmp_dir: dir
    } do
      {:ok, run} =
        Runner.run(profile: :core, courts: [ChicagoSelfTest.CrashingCourt], evidence_dir: dir)

      assert [%Result{falsifier_id: "CHI-CRASH-001", verdict: :unknown, detail: detail}] =
               run.results

      assert detail =~ "court exploded"
      assert Enum.find(run.receipt["gates"], &(&1["gate"] == 7))["status"] == "OPEN"
    end

    test "attempt not observed is UNKNOWN, forbidden observed is SURVIVED" do
      [f | _] = ChicagoSelfTest.Court.falsifiers()

      assert Result.negative(f, attempt_observed?: false, forbidden_outcome_observed?: false).verdict ==
               :unknown

      assert Result.negative(f, attempt_observed?: :unknown, forbidden_outcome_observed?: false).verdict ==
               :unknown

      assert Result.negative(f, attempt_observed?: true, forbidden_outcome_observed?: :unknown).verdict ==
               :unknown

      survived = Result.negative(f, attempt_observed?: true, forbidden_outcome_observed?: true)
      assert survived.verdict == :falsifier_survived
      assert survived.failure_class == :authority_failure

      killed = Result.negative(f, attempt_observed?: true, forbidden_outcome_observed?: false)
      assert killed.verdict == :falsifier_killed
      refute Result.counts_as_pass?(killed)
    end

    test "a §11-incomplete falsifier declaration is refused at construction" do
      assert_raise ArgumentError, ~r/guard must be a non-empty string/, fn ->
        Falsifier.new!(
          id: "CHI-X-001",
          court_id: "CHI-X",
          kind: :negative,
          invariant: "i",
          stimulus: "s",
          boundary: "b",
          forbidden_outcome: "f",
          attempt_evidence: "a",
          survival_evidence: "s"
        )
      end

      assert_raise ArgumentError, ~r/falsifier id must match/, fn ->
        Falsifier.new!(
          id: "bad",
          court_id: "CHI-X",
          kind: :measurement,
          invariant: "i",
          stimulus: "s",
          boundary: "b"
        )
      end

      assert_raise ArgumentError, ~r/not a valid Chicago query predicate/, fn ->
        Falsifier.new!(
          id: "CHI-X-002",
          court_id: "CHI-X",
          kind: :measurement,
          invariant: "i",
          stimulus: "s",
          boundary: "b",
          attempt_evidence: "a",
          attempt_predicate: {:golden_trace, "ocel.json"}
        )
      end
    end
  end

  describe "observer evidence discipline" do
    test "a raising mapping never detaches the handler or loses the event" do
      event = [:ash_a2a, :chicago, :foundation_test, :probe]

      mapping =
        Mapping.new!(
          event: event,
          activity: "probe",
          source: __MODULE__,
          objects: fn _, _ -> raise "boom" end
        )

      {:ok, observer} = Observer.start_link(run_id: "probe-run", mappings: [mapping])

      :telemetry.execute(event, %{}, %{})
      :telemetry.execute(event, %{}, %{})

      records = Observer.records(observer)
      assert length(records) == 2
      assert Enum.all?(records, &(&1.attributes["chicago_mapping_error"] == "boom"))
      assert Observer.dropped(observer) == 0
      assert records |> Enum.map(& &1.seq) |> then(&(&1 == Enum.sort(&1)))

      Observer.stop(observer)
    end

    test "stimulus attribution scopes SUT events to the falsifier under attack" do
      event = [:ash_a2a, :chicago, :foundation_test, :sut]
      mapping = Mapping.new!(event: event, activity: "sut", source: __MODULE__)
      {:ok, observer} = Observer.start_link(run_id: "attr-run", mappings: [mapping])
      [f | _] = ChicagoSelfTest.Court.falsifiers()

      ctx = %Context{
        run_id: "attr-run",
        profile: :core,
        subject: nil,
        evidence_dir: "",
        observer: observer
      }

      :telemetry.execute(event, %{}, %{})
      Context.stimulus(ctx, f, fn -> :telemetry.execute(event, %{}, %{}) end)
      :telemetry.execute(event, %{}, %{})

      assert [
               %{activity: "chicago.stimulus.start"},
               %{activity: "sut"},
               %{activity: "chicago.stimulus.stop"}
             ] =
               Context.observed(ctx, f)

      assert length(Observer.records(observer)) == 5
      Observer.stop(observer)
    end
  end

  describe "exact subject identity" do
    test "capture binds the real revision and verify names every substituted identity" do
      subject = Subject.capture()
      {rev, 0} = System.cmd("git", ["rev-parse", "HEAD"])
      assert subject.source_revision == String.trim(rev)
      assert map_size(subject.artifact_digests) > 0

      clean = %{subject | dirty?: false}
      assert :ok = Subject.verify(clean, clean)

      [artifact | _] = Map.keys(subject.artifact_digests)

      substituted = %{
        clean
        | artifact_digests: Map.put(subject.artifact_digests, artifact, String.duplicate("f", 64))
      }

      assert {:error, {:subject_mismatch, [:artifact_digests]}} =
               Subject.verify(substituted, clean)

      moved = %{clean | source_revision: String.duplicate("a", 40)}
      assert {:error, {:subject_mismatch, [:source_revision]}} = Subject.verify(moved, clean)

      assert {:error, {:subject_mismatch, [:dirty?]}} =
               Subject.verify(clean, %{clean | dirty?: true})

      refute Subject.digest(substituted) == Subject.digest(clean)
    end
  end

  describe "profiles, discovery and refusal providers" do
    test "profiles are cumulative and strict requires all twelve gates" do
      assert Profile.applicable?(:core, :strict)
      refute Profile.applicable?(:do, :plan)
      assert Profile.required_gates(:strict) == Enum.to_list(1..12)
      assert Profile.parse("SA2A-DO") == {:ok, :do}
    end

    test "non-discoverable self-test courts never enter a real qualification run" do
      refute ChicagoSelfTest.Court in Chicago.courts()
      refute ChicagoSelfTest.LyingCourt in Chicago.courts()
    end

    test "a court's refusal codes classify without editing the Refusal table" do
      assert Refusal.classify(:chicago_selftest_refusal) == :refused_authority
      assert Refusal.mapping()[:chicago_selftest_refusal] == :refused_authority
    end
  end
end
