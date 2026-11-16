# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.EventJournalWriterTest do
  @moduledoc """
  The journal writer end to end: a real agent journals its task writes into a
  real ETS journal; after the agent is killed and restarted (empty memory,
  same task store and journal) a `tasks/resubscribe` with `lastSeenGeneration`
  replays the missed events in order over a real `Plug.Test` SSE conn. A
  failing journal never fails the task write. No mocks.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AshA2A.Protocol.EventJournal
  alias AshA2A.Protocol.TaskStore.ETS, as: TaskStore
  alias AshA2A.TaskStore.EventJournalEts
  alias AshA2A.Test.EventJournalFixture, as: Fixture
  alias AshA2A.Test.EventJournalFixture.Agent

  # A journal that refuses, raises or exits, per ref. Hand-written module
  # implementing the real behaviour.
  defmodule BrokenJournal do
    @behaviour AshA2A.Protocol.EventJournal

    @impl true
    def append(:refuses, _task_id, _generation, _event), do: {:error, :not_stored}
    def append(:raises, _task_id, _generation, _event), do: raise("journal down")
    def append(:exits, _task_id, _generation, _event), do: exit(:journal_down)

    @impl true
    def replay_after(_ref, _task_id, _generation), do: {:error, :journal_unavailable}

    @impl true
    def trim(_ref, _task_id, _keep_last), do: {:error, :journal_unavailable}
  end

  def forward(_event, measurements, metadata, pid),
    do: send(pid, {:append_failed, measurements, metadata})

  setup do
    id = System.unique_integer([:positive])
    store = :"journal_writer_store_#{id}"
    table = :"journal_writer_events_#{id}"

    start_supervised!(%{id: :store, start: {TaskStore, :start_link, [[name: store]]}})
    start_supervised!({EventJournalEts, name: table})

    old = Application.get_all_env(:ash_a2a)
    Application.put_env(:ash_a2a, :event_journal, {EventJournalEts, table})

    on_exit(fn ->
      for key <- [:event_journal, :event_journal_keep_last] do
        case Keyword.fetch(old, key) do
          {:ok, value} -> Application.put_env(:ash_a2a, key, value)
          :error -> Application.delete_env(:ash_a2a, key)
        end
      end
    end)

    %{journal: {EventJournalEts, table}, agent_spec: {Agent, task_store: {TaskStore, store}}}
  end

  defp restart_agent(spec) do
    pid = Process.whereis(Agent)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    :ok = stop_supervised(Agent)
    new = start_supervised!(spec)
    assert new != pid
    new
  end

  test "every task write is journaled with its generation", %{journal: j, agent_spec: spec} do
    start_supervised!(spec)
    {task_id, [g1, g2]} = Fixture.drive(Agent, ["still thinking"])

    assert {:ok, events} = EventJournal.replay_after(j, task_id, 0)
    summaries = Enum.map(events, &Fixture.summary/1)
    gens = Enum.map(summaries, &elem(&1, 1))

    assert gens == Enum.sort(gens)
    assert List.last(summaries) == {:status, g2, "TASK_STATE_INPUT_REQUIRED"}
    assert {:status, g1, "TASK_STATE_INPUT_REQUIRED"} in summaries
    assert Enum.any?(summaries, &match?({:message, g, nil} when g > g1 and g <= g2, &1))

    # Only what followed g1 is replayed for a subscriber that holds g1.
    assert {:ok, tail} = EventJournal.replay_after(j, task_id, g1)
    assert Enum.all?(tail, fn e -> elem(Fixture.summary(e), 1) > g1 end)
    assert tail != []
  end

  test "after the agent is killed and restarted, resubscribe replays the missed events in order",
       %{agent_spec: spec} do
    start_supervised!(spec)
    {task_id, [g1, g2, g3]} = Fixture.drive(Agent, ["still thinking", "done"])

    restart_agent(spec)

    # The fresh agent holds nothing in memory: everything below comes from the
    # task store (the terminal task) and the journal (the events).
    frames = Fixture.resubscribe(Agent, task_id, g1)
    summaries = Enum.map(frames, &Fixture.summary/1)
    gens = Enum.map(summaries, &elem(&1, 1))

    refute Enum.any?(summaries, &match?({:task, _, _}, &1)), "a resume carries no Task snapshot"
    assert gens == Enum.sort(gens)
    assert Enum.all?(gens, &(&1 > g1))
    assert {:status, g2, "TASK_STATE_INPUT_REQUIRED"} in summaries
    assert List.last(summaries) == {:status, g3, "TASK_STATE_COMPLETED"}
    assert Enum.count(summaries, &match?({:message, _, _}, &1)) == 2

    # The artifact write is journaled as its own event, one generation before
    # the terminal status (A2A v1.1 3.2.7: one event per mutation).
    assert {:artifact, g3 - 1, nil} in summaries
    assert Fixture.artifact_texts(frames) == ["finished"]
    assert gens == Enum.to_list((g1 + 1)..g3), "one event per generation, no gap"

    texts =
      for %{"messageUpdate" => %{"message" => %{"parts" => [%{"text" => text}]}}} <- frames,
          do: text

    assert texts == ["still thinking", "done"]
  end

  test "a restarted agent replays a non-terminal task and keeps the stream open for the next turn",
       %{agent_spec: spec} do
    start_supervised!(spec)
    {task_id, [g1, g2]} = Fixture.drive(Agent, ["still thinking"])

    restart_agent(spec)

    summaries = Agent |> Fixture.resubscribe(task_id, g1, 150) |> Enum.map(&Fixture.summary/1)

    assert List.last(summaries) == {:status, g2, "TASK_STATE_INPUT_REQUIRED"}
    assert Enum.all?(summaries, fn {kind, g, _} -> kind in [:message, :status] and g > g1 end)

    # The restarted agent keeps journaling the same task from the stored
    # generation: the earlier events are not appended a second time.
    {:ok, done} = AshA2A.Protocol.call(Agent, "done", task_id: task_id)
    g3 = AshA2A.Protocol.Task.Generation.generation_of(done)

    after_frames = Fixture.resubscribe(Agent, task_id, g2)
    after_restart = Enum.map(after_frames, &Fixture.summary/1)
    assert List.last(after_restart) == {:status, g3, "TASK_STATE_COMPLETED"}
    assert {:artifact, g3 - 1, nil} in after_restart
    assert Fixture.artifact_texts(after_frames) == ["finished"]
    assert Enum.count(after_restart, &match?({:message, _, _}, &1)) == 1
  end

  test "a terminal task's journal is trimmed to :event_journal_keep_last",
       %{journal: j, agent_spec: spec} do
    Application.put_env(:ash_a2a, :event_journal_keep_last, 2)
    start_supervised!(spec)
    {task_id, [_g1, _g2, g3]} = Fixture.drive(Agent, ["still thinking", "done"])

    assert {:ok, kept} = EventJournal.replay_after(j, task_id, 0)
    assert length(kept) == 2
    assert kept |> List.last() |> Fixture.summary() == {:status, g3, "TASK_STATE_COMPLETED"}
  end

  for ref <- [:refuses, :raises, :exits] do
    test "a journal that #{ref} does not fail the task write", %{agent_spec: spec} do
      Application.put_env(:ash_a2a, :event_journal, {BrokenJournal, unquote(ref)})
      handler = "journal-writer-#{unquote(ref)}-#{System.unique_integer([:positive])}"
      me = self()

      :telemetry.attach(
        handler,
        [:ash_a2a, :event_journal, :append_failed],
        &__MODULE__.forward/4,
        me
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      agent = start_supervised!(spec)

      log =
        capture_log(fn ->
          {task_id, [_g1, _g2]} = Fixture.drive(Agent, ["done"])
          assert {:ok, task} = GenServer.call(Agent, {:get_task, task_id})
          assert task.status.state == :completed
          send(me, {:task_id, task_id})
        end)

      assert_received {:task_id, task_id}
      assert_received {:append_failed, %{count: 1}, %{task_id: ^task_id, operation: :append}}
      assert log =~ "event journal: append failed"
      assert Process.alive?(agent)
    end
  end

  test "no journal configured: nothing is appended and tasks still work",
       %{journal: j, agent_spec: spec} do
    Application.delete_env(:ash_a2a, :event_journal)
    start_supervised!(spec)
    {task_id, _gens} = Fixture.drive(Agent, ["done"])

    assert EventJournal.configured() == nil
    assert {:ok, []} = EventJournal.replay_after(j, task_id, 0)
  end
end
