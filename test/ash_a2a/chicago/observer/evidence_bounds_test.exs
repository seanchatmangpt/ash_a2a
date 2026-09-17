defmodule AshA2A.Chicago.Observer.EvidenceBoundsTest do
  @moduledoc """
  PRD §48 / ARD §51 bounded evidence fan-out.

  Chicago style throughout: a real `AshA2A.Chicago.Observer` GenServer, real
  `:telemetry.execute` stimuli, and assertions on the real accepted/refused
  OCEL records and real `stats/1` -- no `Mock`/`mox`/`patch`/`monkeypatch`.
  The one telemetry handler attached inside the negative-control test is a
  real `:telemetry` handler used as a test probe (the same idiom
  `AshA2A.Chicago.FoundationTest` already uses to observe the observer's own
  boundary events), asserted on the real payload it received -- never on
  "was this called", so it is not an interaction mock.

  `async: false`: a shared telemetry event name is used across tests in this
  module and concurrent tests would risk cross-attaching handlers.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Chicago.Observer
  alias AshA2A.Chicago.Observer.EvidenceBounds
  alias AshA2A.Chicago.Ocel.Mapping

  @probe_event [:ash_a2a, :chicago, :evidence_bounds_test, :probe]

  setup do
    mapping = Mapping.new!(event: @probe_event, activity: "probe", source: __MODULE__)
    {:ok, mapping: mapping}
  end

  defp run_id(tag), do: "evidence-bounds-#{tag}-#{System.unique_integer([:positive])}"

  describe "AshA2A.Chicago.Observer.EvidenceBounds (pure envelope)" do
    test "every ceiling is required; there is no implicit unlimited" do
      assert {:error, %{code: :evidence_bounds_ceiling_missing, detail: :max_records}} =
               EvidenceBounds.new(max_watch_events: 1, max_journal_bytes: 1)

      assert {:error, %{code: :evidence_bounds_ceiling_invalid}} =
               EvidenceBounds.new(max_records: -1, max_watch_events: 1, max_journal_bytes: 1)
    end

    test "consume_record narrows to the ceiling then refuses fail-closed, never clamping" do
      {:ok, bounds} =
        EvidenceBounds.new(max_records: 1, max_watch_events: 1, max_journal_bytes: 1_000)

      assert {:ok, spent} = EvidenceBounds.consume_record(bounds)
      assert spent.consumed_records == 1

      assert {:error,
              %{
                code: :evidence_fan_out_exceeded,
                detail: %{resource: :max_records, ceiling: 1, consumed: 1}
              }} = EvidenceBounds.consume_record(spent)
    end

    test "consume_journal_bytes fails closed on overspend and refuses a negative size outright" do
      {:ok, bounds} =
        EvidenceBounds.new(max_records: 10, max_watch_events: 1, max_journal_bytes: 100)

      assert {:ok, spent} = EvidenceBounds.consume_journal_bytes(bounds, 90)

      assert {:error,
              %{code: :evidence_fan_out_exceeded, detail: %{resource: :max_journal_bytes}}} =
               EvidenceBounds.consume_journal_bytes(spent, 11)

      assert {:error, %{code: :evidence_bounds_amount_invalid}} =
               EvidenceBounds.consume_journal_bytes(spent, -1)

      # A refused spend never itself changes consumption (fail closed, not a
      # partial credit).
      assert spent.consumed_journal_bytes == 90
    end

    test "admit_watch_event admits distinct names up to the ceiling, idempotently" do
      {:ok, bounds} =
        EvidenceBounds.new(max_records: 10, max_watch_events: 1, max_journal_bytes: 1_000)

      assert {:ok, admitted} = EvidenceBounds.admit_watch_event(bounds, "a")
      assert {:ok, ^admitted} = EvidenceBounds.admit_watch_event(admitted, "a")

      assert {:error, %{code: :evidence_fan_out_exceeded, detail: %{resource: :max_watch_events}}} =
               EvidenceBounds.admit_watch_event(admitted, "b")
    end

    test "fence refuses any envelope that somehow carries authority" do
      {:ok, bounds} =
        EvidenceBounds.new(max_records: 1, max_watch_events: 1, max_journal_bytes: 1)

      assert :ok = EvidenceBounds.fence(bounds)

      carrying = %{bounds | authority: :escalated}

      assert {:error, %{code: :evidence_bounds_authority_ceiling_violated}} =
               EvidenceBounds.fence(carrying)
    end
  end

  describe "positive control: a run at or below every ceiling" do
    test "every record is accepted and the envelope reports zero exceedances", %{
      mapping: mapping
    } do
      bounds =
        EvidenceBounds.new!(max_records: 10, max_watch_events: 4, max_journal_bytes: 1_000_000)

      run_id = run_id("positive")

      {:ok, observer} =
        Observer.start_link(run_id: run_id, mappings: [mapping], evidence_bounds: bounds)

      for i <- 1..5, do: :telemetry.execute(@probe_event, %{}, %{n: i})

      records = Observer.records(observer)
      stats = Observer.stats(observer)

      assert length(records) == 5
      assert stats.evidence_bounds_exceeded == 0
      assert stats.evidence_bounds.records == %{consumed: 5, limit: 10}
      assert stats.evidence_bounds.journal_bytes.consumed > 0
      assert stats.evidence_bounds.journal_bytes.consumed <= 1_000_000

      Observer.stop(observer)
    end
  end

  describe "negative control: a run that floods telemetry past max_records" do
    test "records past the ceiling are refused rather than silently accepted, and a typed event fires",
         %{mapping: mapping} do
      bounds =
        EvidenceBounds.new!(max_records: 3, max_watch_events: 4, max_journal_bytes: 1_000_000)

      run_id = run_id("negative")

      {:ok, observer} =
        Observer.start_link(run_id: run_id, mappings: [mapping], evidence_bounds: bounds)

      test_pid = self()
      handler_id = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler_id,
        [:ash_a2a, :chicago, :observer, :evidence_bounds_exceeded],
        fn _event, _measurements, metadata, _config -> send(test_pid, {:exceeded, metadata}) end,
        nil
      )

      # A runaway emitter: 10 stimuli against a ceiling of 3.
      for i <- 1..10, do: :telemetry.execute(@probe_event, %{}, %{n: i})

      records = Observer.records(observer)
      stats = Observer.stats(observer)

      # The forbidden outcome (this falsifier's whole point) is an OCEL
      # artifact that silently grew past the admitted ceiling.
      assert length(records) == 3
      assert stats.evidence_bounds.records == %{consumed: 3, limit: 3}
      assert stats.evidence_bounds_exceeded == 7

      for _ <- 1..7 do
        assert_received {:exceeded,
                         %{code: :evidence_fan_out_exceeded, resource: :max_records} = meta}

        assert meta.ceiling == 3
      end

      refute_received {:exceeded, _}

      :telemetry.detach(handler_id)
      Observer.stop(observer)
    end
  end

  describe "watch-event vocabulary ceiling (§48/§51 watched-event-type breadth)" do
    test "a configured :watch_events vocabulary already wider than the ceiling refuses startup" do
      bounds =
        EvidenceBounds.new!(max_records: 100, max_watch_events: 1, max_journal_bytes: 1_000_000)

      event_a = [:ash_a2a, :chicago, :evidence_bounds_test, :watch_a]
      event_b = [:ash_a2a, :chicago, :evidence_bounds_test, :watch_b]

      assert {:error, {:evidence_fan_out_exceeded, %{code: :evidence_fan_out_exceeded}}} =
               Observer.start(
                 run_id: run_id("watch-refused"),
                 watch_events: [event_a, event_b],
                 evidence_bounds: bounds
               )
    end

    test "a configured :watch_events vocabulary at the ceiling starts and runs normally" do
      bounds =
        EvidenceBounds.new!(max_records: 100, max_watch_events: 1, max_journal_bytes: 1_000_000)

      event_a = [:ash_a2a, :chicago, :evidence_bounds_test, :watch_a]

      assert {:ok, observer} =
               Observer.start(
                 run_id: run_id("watch-ok"),
                 watch_events: [event_a],
                 evidence_bounds: bounds
               )

      :telemetry.execute(event_a, %{}, %{})
      assert length(Observer.records(observer)) == 1
      assert Observer.stats(observer).evidence_bounds_exceeded == 0

      Observer.stop(observer)
    end
  end

  describe "journal-byte ceiling (§48/§51 attribute payload per record)" do
    test "a record whose canonical payload would exceed max_journal_bytes is refused", %{
      mapping: mapping
    } do
      bounds = EvidenceBounds.new!(max_records: 100, max_watch_events: 4, max_journal_bytes: 1)
      run_id = run_id("bytes")

      {:ok, observer} =
        Observer.start_link(run_id: run_id, mappings: [mapping], evidence_bounds: bounds)

      :telemetry.execute(@probe_event, %{}, %{n: 1})

      assert Observer.records(observer) == []
      assert Observer.stats(observer).evidence_bounds_exceeded == 1
      assert Observer.stats(observer).evidence_bounds.journal_bytes.limit == 1

      Observer.stop(observer)
    end
  end

  describe "an observer with no :evidence_bounds is unaffected (strictly additive)" do
    test "unbounded behavior is unchanged from before this envelope existed", %{mapping: mapping} do
      run_id = run_id("unbounded")
      {:ok, observer} = Observer.start_link(run_id: run_id, mappings: [mapping])

      for i <- 1..25, do: :telemetry.execute(@probe_event, %{}, %{n: i})

      assert length(Observer.records(observer)) == 25
      stats = Observer.stats(observer)
      assert stats.evidence_bounds_exceeded == 0
      assert stats.evidence_bounds == nil

      Observer.stop(observer)
    end
  end
end
