defmodule AshA2A.Chicago.ObserverQualificationTest do
  @moduledoc """
  RFC-SA2A-002 §19, §20, §107, §108, §138, §139: process observer
  qualification, Chicago style. The court runs through the real
  `AshA2A.Chicago.Runner`; the narrow tests exercise the real observer,
  journal, mapping validation, independent consumer and standing function
  with real processes, real files and real telemetry -- no doubles.

  `async: false`: observers attach global telemetry handlers and attribute by
  stimulus interval.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.Chicago.{Observer, Query, Result, Runner, StandingReceipt, Subject}
  alias AshA2A.Chicago.Courts.ObserverQualification
  alias AshA2A.Chicago.Fixtures.ObserverQualification, as: Fx
  alias AshA2A.Chicago.Observer.{Journal, NonAuthority}
  alias AshA2A.Chicago.Ocel.{Mapping, SutEvents, SutMappings}

  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  describe "SA2A-OCEL-OBSERVER through the real Runner" do
    test "every falsifier is killed, every control passes, all corroborated by the independent consumer",
         %{tmp_dir: dir} do
      assert {:ok, run} =
               Runner.run(courts: [ObserverQualification], profile: :core, evidence_dir: dir)

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})
      assert map_size(by_id) == 14

      for n <- 1..9 do
        id = "SA2A-OCEL-OBSERVER-" <> String.pad_leading("#{n}", 3, "0")
        result = Map.fetch!(by_id, id)

        assert result.verdict == :falsifier_killed,
               "#{id}: #{result.verdict} #{inspect(result.evidence)} #{result.ocel_detail}"

        assert result.attempt_observed? == true, id
        assert result.ocel_corroborated? == true, "#{id}: #{result.ocel_detail}"
      end

      for n <- 10..14 do
        id = "SA2A-OCEL-OBSERVER-0" <> Integer.to_string(n)
        result = Map.fetch!(by_id, id)

        assert result.verdict == :positive_control_passed,
               "#{id}: #{result.verdict} #{inspect(result.evidence)} #{result.ocel_detail}"

        assert result.ocel_corroborated? == true, "#{id}: #{result.ocel_detail}"
      end

      # The run's own observer stayed whole while the court disturbed others.
      assert run.ocel.dropped == 0
      assert run.ocel.gaps == 0

      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      assert :ok = StandingReceipt.verify_digest(receipt)
      assert receipt["evidence"]["ocel_dropped_records"] == 0
      assert receipt["evidence"]["ocel_gaps"] == 0
      assert receipt["results"]["falsifiers_killed"] == 9
      assert receipt["results"]["positive_controls_passed"] == 5
      # Core gates 1-3 are not this court's: honest PARTIAL_ALIVE.
      assert receipt["standing"] == "PARTIAL_ALIVE"

      # The observer outage evidence is on disk, not in memory.
      killed =
        JSON.decode!(
          File.read!(
            Path.join([dir, "observer_qualification", "001-killed", "standing_receipt.json"])
          )
        )

      assert killed["evidence"]["ocel_dropped_records"] > 0
      assert killed["evidence"]["ocel_gaps"] >= 1
      refute killed["standing"] == "CONFORMANT"
    end
  end

  describe "standing" do
    test "CONFORMANT is reachable only with zero dropped records and zero observer gaps" do
      [f | _] = ObserverQualification.falsifiers()

      results =
        for gate <- 1..3 do
          %{
            Result.negative(f, attempt_observed?: true, forbidden_outcome_observed?: false)
            | gate: gate,
              ocel_corroborated?: true
          }
        end

      input = fn ocel ->
        %{
          profile: :core,
          subject: Subject.capture(),
          courts: [ObserverQualification],
          falsifiers: ObserverQualification.falsifiers(),
          results: results,
          ocel:
            Map.merge(
              %{sha256: "0", bytes: 1, events: 1, objects: 1, mapping_digest: "m"},
              ocel
            ),
          ocel_validation: %{status: :valid, validator: "independent", report: %{}},
          run_id: "standing-unit"
        }
      end

      assert StandingReceipt.build(input.(%{dropped: 0, gaps: 0}))["standing"] == "CONFORMANT"
      refute StandingReceipt.build(input.(%{dropped: 1, gaps: 0}))["standing"] == "CONFORMANT"
      refute StandingReceipt.build(input.(%{dropped: 0, gaps: 1}))["standing"] == "CONFORMANT"
    end
  end

  describe "observer" do
    test "a killed observer is replaced by a recovery incarnation that restores the journal and records the gap",
         %{tmp_dir: dir} do
      run_id = "unit-recovery-#{System.unique_integer([:positive])}"

      opts = [
        run_id: run_id,
        mappings: [Fx.probe_mapping()],
        journal: Observer.journal_path(dir, run_id),
        delivery_timeout_ms: 500
      ]

      {:ok, first} = Observer.start(opts)
      for i <- 1..3, do: Fx.probe(%{probe_id: "p#{i}", i: i})
      ref = Process.monitor(first)
      Process.exit(first, :kill)
      assert_receive {:DOWN, ^ref, :process, _, :killed}
      for i <- 4..5, do: Fx.probe(%{probe_id: "p#{i}", i: i})

      second = Observer.ensure_running(first, opts)
      refute second == first
      assert Observer.ensure_running(second, opts) == second

      stats = Observer.stats(second)
      assert stats.incarnation == 2
      assert stats.gaps == 1
      assert stats.dropped == 2
      assert stats.harvested_handlers == 1

      {:ok, flush} = Observer.flush(second, dir)
      Observer.stop_run(run_id)

      doc = JSON.decode!(File.read!(flush.path))
      assert Enum.count(doc["events"], &(&1["type"] == "fixture.probe")) == 3
      assert Enum.count(doc["events"], &(&1["type"] == "chicago.observer.gap")) == 1
      assert flush.gaps == 1 and flush.dropped == 2

      assert [] ==
               :telemetry.list_handlers([])
               |> Enum.filter(&match?(%{id: {Observer, ^run_id, _, _}}, &1))
    end

    test "attribution follows chicago_seq intervals, not delivery order" do
      start = %{seq: 10, activity: "chicago.stimulus.start", falsifier_id: "F", court_id: "C"}
      stop = %{seq: 20, activity: "chicago.stimulus.stop", falsifier_id: "F", court_id: "C"}
      before = %{seq: 5, activity: "x", falsifier_id: nil, court_id: nil}
      inside = %{seq: 15, activity: "x", falsifier_id: nil, court_id: nil}
      gap = %{seq: 12, activity: "chicago.observer.gap", falsifier_id: nil, court_id: nil}

      # Arrival order: start, the pre-stimulus record, inside, stop.
      arrived = [start, before, inside, stop]

      attributed =
        arrived |> Enum.sort_by(& &1.seq) |> Observer.attribute() |> Map.new(&{&1.seq, &1})

      assert attributed[5].falsifier_id == nil
      assert attributed[15].falsifier_id == "F"

      # A gap closes the interval: the stop may have been lost.
      after_gap = [start, gap, inside, stop] |> Enum.sort_by(& &1.seq) |> Observer.attribute()
      assert Enum.find(after_gap, &(&1.seq == 15)).falsifier_id == nil
    end

    test "observers watching each other's boundary events while both are dead do not recurse" do
      ids = for n <- 1..2, do: "unit-mutual-#{n}-#{System.unique_integer([:positive])}"

      pids =
        for run_id <- ids do
          {:ok, pid} =
            Observer.start(
              run_id: run_id,
              mappings: [Fx.probe_mapping()],
              watch_events: Observer.boundary_events(),
              delivery_timeout_ms: 100
            )

          pid
        end

      for pid <- pids do
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^ref, :process, _, _}
      end

      task = Task.async(fn -> Fx.probe(%{probe_id: "loop-1"}) end)
      assert :ok = Task.await(task, 5_000)

      drops =
        []
        |> :telemetry.list_handlers()
        |> Enum.uniq_by(& &1.id)
        |> Enum.filter(fn %{id: id} -> match?({Observer, _, _, _}, id) and elem(id, 1) in ids end)
        |> Enum.map(&:counters.get(&1.config.counters, 1))

      # Each dead observer: the probe, plus the other observer's single
      # `dropped` boundary event -- which is never re-emitted.
      assert drops == [2, 2]
      Enum.each(ids, &Observer.stop_run/1)
    end

    test "unmapped watched telemetry becomes a typed chicago.unmapped event", %{tmp_dir: dir} do
      run_id = "unit-unmapped-#{System.unique_integer([:positive])}"
      event = Fx.event(:unit_unmapped)
      {:ok, pid} = Observer.start(run_id: run_id, watch_events: [event])
      Fx.emit(event, %{n: 1}, %{kind: :novel, pid: self()})
      {:ok, flush} = Observer.flush(pid, dir)
      Observer.stop_run(run_id)

      assert flush.unmapped == 1
      doc = JSON.decode!(File.read!(flush.path))
      [unmapped] = Enum.filter(doc["events"], &(&1["type"] == "chicago.unmapped"))
      attrs = Map.new(unmapped["attributes"], &{&1["name"], &1["value"]})
      assert attrs["telemetry_event"] == Enum.join(event, ".")
      assert attrs["meta.kind"] == "novel"
      assert attrs["measure.n"] == 1
      refute Map.has_key?(attrs, "meta.pid")
    end
  end

  describe "mapping reference validation" do
    test "absent ids are skipped, malformed and reserved references are rejected, unusual valid ones kept" do
      assert :absent = Mapping.validate_ref({"widget", nil, "q"})
      assert {:ok, {"widget", "42", "q"}} = Mapping.validate_ref({"widget", 42, "q"})
      assert {:ok, {"nebula", "a:b", "q"}} = Mapping.validate_ref({:nebula, "a:b", :q})

      assert {:ok, {"principal", "p-1", "actor"}} =
               Mapping.validate_ref({"principal", AshA2A.Identity.principal("p-1"), "actor"})

      assert {:rejected, :malformed_id, "widget"} = Mapping.validate_ref({"widget", "", "q"})

      assert {:rejected, :malformed_id, "widget"} =
               Mapping.validate_ref({"widget", <<0xFF>>, "q"})

      assert {:rejected, :malformed_id, "widget"} = Mapping.validate_ref({"widget", %{a: 1}, "q"})
      assert {:rejected, :malformed_type, nil} = Mapping.validate_ref({"command:a", "b", "q"})
      assert {:rejected, :malformed_type, nil} = Mapping.validate_ref({42, "b", "q"})

      assert {:rejected, :reserved_type, "falsifier"} =
               Mapping.validate_ref({"falsifier", "F", "q"})

      assert {:rejected, :malformed_qualifier, "widget"} =
               Mapping.validate_ref({"widget", "w", 1})

      assert {:rejected, :malformed_shape, nil} = Mapping.validate_ref({:only, :two})
    end
  end

  describe "journal" do
    test "restores verified lines and counts corrupt, torn and duplicate lines", %{tmp_dir: dir} do
      path = Path.join(dir, "unit-journal.jsonl")
      {:ok, j} = Journal.open(path, :every_record)
      {:ok, j} = Journal.append(j, %{"kind" => "header", "run_id" => "r", "incarnation" => 1})

      record = fn seq ->
        %{
          seq: seq,
          event: [:ash_a2a, :unit],
          activity: "unit",
          time_us: 1,
          attributes: %{"f" => 1.5, "s" => "v"},
          objects: [{"t", "id", "q"}],
          falsifier_id: nil,
          court_id: nil,
          run_id: nil
        }
      end

      {:ok, j} = Journal.append(j, Journal.record_entry(record.(1)))
      {:ok, j} = Journal.append(j, Journal.record_entry(record.(2)))
      {:ok, j} = Journal.append(j, Journal.record_entry(record.(2)))
      :ok = Journal.close(j)

      bytes = File.read!(path)
      tampered = String.replace(bytes, ~s("s":"v"), ~s("s":"w"), global: false)
      File.write!(path, tampered <> ~s({"kind":"rec))

      assert {:ok, recovered} = Journal.recover(path)
      assert recovered.run_ids == ["r"]
      assert recovered.incarnations == 1
      assert Enum.map(recovered.records, & &1.seq) == [2]
      assert hd(recovered.records).attributes == %{"f" => 1.5, "s" => "v"}
      assert recovered.corrupt_lines == 2
      assert recovered.duplicate_lines == 1
      assert recovered.torn_tail

      # Reopening terminates the torn tail so new lines never fuse with it.
      {:ok, j} = Journal.open(path)
      {:ok, j} = Journal.append(j, Journal.record_entry(record.(3)))
      :ok = Journal.close(j)
      assert {:ok, again} = Journal.recover(path)
      assert Enum.map(again.records, & &1.seq) == [2, 3]
      refute again.torn_tail
    end
  end

  describe "independent consumer" do
    test "refuses duplicated event identities and reports content duplicates", %{tmp_dir: dir} do
      run_id = "unit-dup-#{System.unique_integer([:positive])}"
      {:ok, pid} = Observer.start(run_id: run_id, mappings: [Fx.probe_mapping()])
      Fx.probe(%{probe_id: "same", i: 1})
      Fx.probe(%{probe_id: "same", i: 1})
      {:ok, flush} = Observer.flush(pid, dir)
      Observer.stop_run(run_id)

      assert {:ok, index} = Query.load(flush.path, flush.sha256)
      assert [%{type: "fixture.probe", count: 2, seqs: [a, b]}] = Query.duplicates(index)
      assert a != b

      doc = JSON.decode!(File.read!(flush.path))
      dup = Path.join(dir, "dup.json")
      File.write!(dup, JSON.encode!(%{doc | "events" => doc["events"] ++ [hd(doc["events"])]}))
      assert {:error, {:ocel_duplicate_event_identity, _}} = Query.load(dup)
    end
  end

  describe "static proofs" do
    test "the observer closure is proved non-authoritative and discovery sees unmapped SUT telemetry" do
      assert %{outcome: :proved, violations: [], unprovable: []} =
               NonAuthority.prove(NonAuthority.default_scope(SutMappings.mappings()))

      assert NonAuthority.forbidden?(AshA2A.CommandBus)
      assert NonAuthority.forbidden?(AshA2A.Authority.Broker.InMemory)
      refute NonAuthority.forbidden?(AshA2A.Chicago.Query)

      unmapped = SutEvents.unmapped(SutMappings.mappings())
      assert [:ash_a2a, :ocel, :shed] in unmapped
      refute [:ash_a2a, :receipt, :committed] in unmapped
      refute Enum.any?(unmapped, &match?([:ash_a2a, :chicago, :fixtures | _], &1))
    end
  end
end
