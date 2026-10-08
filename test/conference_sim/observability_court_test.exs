# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule ConferenceSim.ObservabilityVenue do
  @moduledoc """
  Real conference venue agent (EV11 fixture, named ObservabilityVenue so it does not collide with the
  shared fixture's Ash resource `ConferenceSim.Venue`: test/conference_sim/observability_court.exs owns it).

  One AshA2A.Agent GenServer with three activities, routed on the inbound
  Part.Data payload:

    * register - attendee registration, answers a non-streaming {:reply, _}
      (the registration task runs :working -> :completed);
    * task - a plain task create, non-streaming;
    * stream - a stream connect, answers {:stream, enum} (three chunks; the
      task parks in :working until the real {:stream_done, _} cast folds it
      to :completed).

  The :resource_or_domain fixture is never dispatched (same pattern as
  AshA2A.V1ArtifactStreamingTest.StreamAgent): handle_message/2 is genuinely
  overridden; AshA2A.Test.Fixture.Echo exists only because
  AshA2A.Agent.__using__/1 requires one.

  NOTE (EV11): once the shared ConferenceSim fixture lane lands
  (test/conference_sim/fixture.ex, ConferenceSim.build/1), this venue can be
  replaced by the shared fixture's venue; the courts read only the
  observability surface, so they are fixture-agnostic by construction.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.Echo,
    name: "conference_sim_venue"

  alias AshA2A.Protocol.Part

  @impl AshA2A.Protocol.Agent
  def handle_message(
        %AshA2A.Protocol.Message{
          parts: [%Part.Data{data: %{"activity" => "register", "attendee" => attendee}}]
        },
        _context
      ) do
    {:reply,
     [
       Part.Data.new(%{
         "activity" => "register",
         "attendee" => attendee,
         "badge" => "badge-" <> attendee
       })
     ]}
  end

  @impl AshA2A.Protocol.Agent
  def handle_message(%AshA2A.Protocol.Message{parts: [%Part.Data{data: %{"activity" => "stream"}}]}, _context) do
    {:stream, Stream.map(1..3, fn i -> Part.Text.new("talk-chunk-#{i}") end)}
  end

  @impl AshA2A.Protocol.Agent
  def handle_message(%AshA2A.Protocol.Message{parts: [%Part.Data{data: %{"activity" => "task"}}]}, _context) do
    {:reply, [Part.Data.new(%{"activity" => "task", "status" => "created"})]}
  end

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context) do
    {:reply, [Part.Text.new("venue: unknown activity")]}
  end
end

defmodule ConferenceSim.ObservabilityCourt do
  @moduledoc """
  EV11: the conference sim's event log as an OCEL-shaped observability surface,
  read from the estate's real OCEL capital - ash_a2a's real telemetry stream
  ([:a2a, :task, :transition] plus the ported-SDK spans) - with the event-log
  read side built in this file (ConferenceSim.EventLog, a real
  :telemetry.attach/4 handler writing an ordered ETS log). No mock, no stub,
  no faked log: every event this court asserts on was emitted by the real
  running AshA2A.Agent GenServer.

  ## OCEL shape

  Each captured telemetry event maps to one OCEL event:

      %{
        seq: <global emission order>,
        activity: event_name,           # e.g. [:a2a, :task, :transition]
        time: measurements.system_time, # real monotonic system time
        objects: {task_id, context_id}, # object references
        attributes: meta                # from/to/reply_type/status/agent/...
      }

  ## Pinned event inventory (verified against the source, not assumed)

    * [:a2a, :task, :transition] - every task state change; meta carries
      task_id, context_id, from, to (lib/ash_a2a/protocol/agent/state.ex)
    * [:a2a, :agent, :call, :start/:stop] - span around
      AshA2A.Protocol.call/3 / stream/3; stop carries task_id, status,
      context_id, streaming (lib/ash_a2a/protocol.ex)
    * [:a2a, :agent, :message, :start/:stop] - span around handler execution;
      stop carries task_id, reply_type
      (lib/ash_a2a/protocol/agent/runtime.ex)

  ## Courts

    1. every registration produces an observable event (transition + span)
    2. every task state transition is observable with the task id
    3. one attendee's journey (register -> create task -> stream -> terminal)
       is ordered and complete
    4. no event leaks another attendee's identity (privacy boundary)
    5. counter-integrity: events emitted == events expected for the scripted
       scenario (no silent drops, no dupes)
  """

  use ExUnit.Case, async: true

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Protocol
  alias ConferenceSim.ObservabilityVenue

  # -- event-log read side ---------------------------------------------------

  defmodule EventLog do
    @moduledoc """
    The minimal read side, built in-repo because ash_a2a had no in-repo
    event-log query surface: a real :telemetry.attach/4 handler that appends
    every captured [:a2a, ...] observability event to an ordered public ETS
    log under a real global monotonic sequence counter (:ets.update_counter/3),
    so cross-process event ORDER is real, not asserted. A :telemetry attach
    handler is a real collaborator, not a test double.
    """

    @doc "Starts a fresh ordered log: {table, handler_id}."
    def start do
      table = :ets.new(:conference_sim_event_log, [:ordered_set, :public])
      :ets.insert(table, {:seq, 0})

      handler_id = :"conference_sim_log_#{System.unique_integer([:positive])}"

      :ok = :telemetry.attach_many(handler_id, span_events(), &__MODULE__.handle/4, table)

      {table, handler_id}
    end

    defp span_events do
      [
        [:a2a, :task, :transition],
        [:a2a, :agent, :call, :start],
        [:a2a, :agent, :call, :stop],
        [:a2a, :agent, :message, :start],
        [:a2a, :agent, :message, :stop]
      ]
    end

    def stop(handler_id), do: :telemetry.detach(handler_id)

    @doc false
    def handle(event, measurements, meta, table) do
      seq = :ets.update_counter(table, :seq, 1)
      :ets.insert(table, {seq + 1, event, measurements, meta})
      :ok
    end

    @doc "All captured events in real emission order, as OCEL-shaped maps."
    def events(table) do
      table
      |> :ets.tab2list()
      |> Enum.filter(fn row -> is_tuple(row) and tuple_size(row) == 4 and is_integer(elem(row, 0)) end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {seq, event, measurements, meta} ->
        %{
          seq: seq,
          activity: event,
          time: Map.get(measurements, :system_time) || Map.get(measurements, :duration),
          objects: {meta[:task_id], meta[:context_id]},
          attributes: meta
        }
      end)
    end

    @doc "All events for one object (task_id), in order."
    def for_task(table, task_id) do
      table |> events() |> Enum.filter(&(elem(&1.objects, 0) == task_id))
    end

    @doc "Transition events for one task (or all), in order."
    def transitions(table, task_id \\ nil) do
      table
      |> events()
      |> Enum.filter(&(&1.activity == [:a2a, :task, :transition]))
      |> then(fn ts ->
        if task_id, do: Enum.filter(ts, &(elem(&1.objects, 0) == task_id)), else: ts
      end)
    end

    @doc "True if any captured event's payload mentions leak."
    def leaks?(table, leak) do
      table
      |> events()
      |> Enum.any?(fn ev ->
        String.contains?(inspect(%{attributes: ev.attributes, objects: ev.objects}), leak)
      end)
    end
  end

  # -- harness ---------------------------------------------------------------

  setup do
    {table, handler_id} = EventLog.start()

    on_exit(fn -> EventLog.stop(handler_id) end)

    name = :"conference_sim_venue_#{System.unique_integer([:positive])}"
    start_supervised!({ObservabilityVenue, name: name})

    %{table: table, venue: name}
  end

  defp register!(venue, table, attendee) do
    assert {:ok, %Protocol.Task{status: %{state: :completed}} = task} =
             Protocol.call(venue, data_message(%{"activity" => "register", "attendee" => attendee}))

    task
  end

  defp stream_talk!(venue, table) do
    assert {:ok, %Protocol.Task{} = task, stream} =
             Protocol.stream(venue, data_message(%{"activity" => "stream"}))

    assert %Protocol.Task{status: %{state: :working}} = task
    assert Enum.count(stream) == 3

    # The real {:stream_done, _} cast folds the task to :completed; poll the
    # real task store rather than sleeping blind.
    wait_until(2_000, fn ->
      match?({:ok, %Protocol.Task{status: %{state: :completed}}}, ObservabilityVenue.get_task(venue, task.id))
    end)

    task
  end

  defp create_task!(venue, attendee) do
    assert {:ok, %Protocol.Task{status: %{state: :completed}} = task} =
             Protocol.call(venue, data_message(%{"activity" => "task", "attendee" => attendee}))

    task
  end

  defp wait_until(timeout, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(deadline, fun)
  end

  defp do_wait(deadline, fun) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline, do: flunk("condition not met in time")

      Process.sleep(10)
      do_wait(deadline, fun)
    end
  end

  # -- courts ----------------------------------------------------------------

  @tag :ev11
  test "1. every registration produces an observable event", %{table: table, venue: venue} do
    attendees = for i <- 1..3, do: "attendee-#{i}-#{System.unique_integer([:positive])}"

    tasks = Enum.map(attendees, &register!(venue, table, &1))

    # Each registration task is observable by id: :working then :completed.
    for task <- tasks do
      transitions = EventLog.transitions(table, task.id)

      assert Enum.map(transitions, & &1.attributes.to) == [:working, :completed]
      assert Enum.map(transitions, & &1.attributes.from) == [:submitted, :working]
    end

    # And the venue-level call span observed each registration end to end.
    for task <- tasks do
      stops =
        table
        |> EventLog.events()
        |> Enum.filter(fn ev ->
          ev.activity == [:a2a, :agent, :call, :stop] and elem(ev.objects, 0) == task.id
        end)

      assert length(stops) == 1
      assert hd(stops).attributes.status == :completed
    end
  end

  @tag :ev11
  test "2. every task state transition is observable with the task id", %{
    table: table,
    venue: venue
  } do
    reg = register!(venue, table, "attendee-obs")
    plain = create_task!(venue, "attendee-obs")
    streamed = stream_talk!(venue, table)

    my_ids = MapSet.new([reg.id, plain.id, streamed.id])

    # Every transition event in the whole log carries a binary task id, a
    # valid source state, and a legal A2A v1.0 target state.
    for ev <- EventLog.transitions(table) do
      assert is_binary(elem(ev.objects, 0))
      assert ev.attributes.from in [nil, :submitted, :working, :input_required, :completed]
      assert ev.attributes.to in [:working, :completed, :input_required, :rejected, :failed]
    end

    # No silent drops: each task id the venue returned is present in the
    # transition log with its full observable lifecycle.
    for id <- my_ids do
      assert EventLog.transitions(table, id) != []
    end
  end

  @tag :ev11
  test "3. one attendee's journey is ordered and complete", %{table: table, venue: venue} do
    attendee = "journey-attendee"

    reg = register!(venue, table, attendee)
    plain = create_task!(venue, attendee)
    streamed = stream_talk!(venue, table)

    # Complete: each of the three activities observed the full lifecycle.
    for task <- [reg, plain, streamed] do
      transitions = EventLog.transitions(table, task.id)

      assert Enum.map(transitions, & &1.attributes.to) == [:working, :completed]
    end

    # Ordered: first transition of each task appears in scripted journey order
    # (register -> task -> stream), per real ETS counter sequence.
    first_seqs =
      Enum.map([reg.id, plain.id, streamed.id], fn task_id ->
        first =
          table
          |> EventLog.for_task(task_id)
          |> Enum.find(&(&1.activity == [:a2a, :task, :transition]))

        {first.seq, elem(first.objects, 0)}
      end)

    assert Enum.map(first_seqs, &elem(&1, 1)) == [reg.id, plain.id, streamed.id]
    assert Enum.map(first_seqs, &elem(&1, 0)) == Enum.sort(Enum.map(first_seqs, &elem(&1, 0)))

    for task_id <- [reg.id, plain.id, streamed.id] do
      seqs = table |> EventLog.transitions(task_id) |> Enum.map(& &1.seq)

      assert seqs == Enum.sort(seqs)
    end

    # The stream connect (call span stop for the streamed task) happens after
    :ok
    # the plain task's completion - journey order is real, not assumed.
    stream_call_stop_seq =
      table
      |> EventLog.events()
      |> Enum.find(fn ev ->
        ev.activity == [:a2a, :agent, :call, :stop] and elem(ev.objects, 0) == streamed.id
      end)
      |> Map.get(:seq)

    plain_completed_seq =
      table
      |> EventLog.transitions(plain.id)
      |> Enum.find(&(&1.attributes.to == :completed))
      |> Map.get(:seq)

    assert stream_call_stop_seq > plain_completed_seq
  end

  @tag :ev11
  test "4. no event leaks another attendee's identity", %{table: table, venue: venue} do
    attendee_a = "attendee-privacy-a-#{System.unique_integer([:positive])}"
    attendee_b = "attendee-privacy-b-#{System.unique_integer([:positive])}"

    register!(venue, table, attendee_a)
    register!(venue, table, attendee_b)

    # Neither attendee's marker appears in ANY captured observability event
    # payload - the telemetry surface carries object ids (task/context ids),
    # test
    refute EventLog.leaks?(table, attendee_a)
    refute EventLog.leaks?(table, attendee_b)
  end

  @tag :ev11
  test "5. counter-integrity: events emitted == events expected", %{table: table, venue: venue} do
    tasks = [
      register!(venue, table, "attendee-count-1"),
      register!(venue, table, "attendee-count-1b"),
      create_task!(venue, "attendee-count-2"),
      stream_talk!(venue, table)
    ]

    task_ids = MapSet.new(Enum.map(tasks, & &1.id))

    # Expected: exactly two transitions per task (:working, :completed), no
    # drops, no dupes, canonical order per task.
    expected = MapSet.size(task_ids) * 2

    mine =
      table
      |> EventLog.transitions()
      |> Enum.filter(&MapSet.member?(task_ids, elem(&1.objects, 0)))

    assert Enum.count(mine) == expected

    for task_id <- task_ids do
      transitions = EventLog.transitions(table, task_id)

      assert Enum.map(transitions, & &1.attributes.to) == [:working, :completed]
      assert Enum.map(transitions, & &1.attributes.from) == [:submitted, :working]
    end
  end
end
