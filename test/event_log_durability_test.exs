# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.EventLogDurabilityTest do
  use ExUnit.Case, async: false

  alias AshA2A.A2ATransport
  alias AshA2A.A2ATransport.{EventLog, PushConfigStore, TaskEvents}
  alias AshA2A.Cluster.{Checkpoint, Handover}
  alias AshA2A.Protocol.Task
  alias AshA2A.Protocol.TaskStore.ETS, as: EtsStore

  @transport :Y3Transport

  defp start_events(event_log) do
    unless Process.whereis(A2ATransport.registry_name(@transport)) do
      start_supervised!(
        {Registry, keys: :duplicate, name: A2ATransport.registry_name(@transport)}
      )
    end

    unless Process.whereis(A2ATransport.push_store_name(@transport)) do
      start_supervised!(
        {PushConfigStore, name: A2ATransport.push_store_name(@transport), max_per_task: 4}
      )
    end

    start_supervised!(
      {TaskEvents,
       name: A2ATransport.events_name(@transport),
       transport: @transport,
       retention_ms: 600_000,
       max_events: 100,
       push: [],
       event_log: event_log}
    )
  end

  defp status(task_id, state),
    do: %{"statusUpdate" => %{"taskId" => task_id, "status" => %{"state" => state}}}

  setup do
    dir = Path.join(System.tmp_dir!(), "y3_event_log_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "default backend: log is in-memory and gone after restart" do
    start_events(nil)
    TaskEvents.publish(@transport, "t1", "status-update", status("t1", "working"))
    assert [{1, "status-update", _, false}] = TaskEvents.backlog(@transport, "t1")

    stop_supervised!(TaskEvents)
    start_events(nil)
    assert [] = TaskEvents.backlog(@transport, "t1")
  end

  test "dets backend replays seq and generation across a real restart", %{dir: dir} do
    log = {EventLog.Dets, dir: dir}
    start_events(log)

    for s <- ~w(submitted working working) do
      TaskEvents.publish(@transport, "t1", "status-update", status("t1", s))
    end

    before = TaskEvents.backlog(@transport, "t1")
    assert [1, 2, 3] = Enum.map(before, &elem(&1, 0))
    assert [1, 2, 3] = Enum.map(before, fn {_, _, p, _} -> TaskEvents.generation_of(p) end)

    stop_supervised!(TaskEvents)
    start_events(log)

    assert TaskEvents.backlog(@transport, "t1") == before

    # seq and generation continue monotonically after the restart
    assert 4 = TaskEvents.publish(@transport, "t1", "status-update", status("t1", "working"))
    {_, _, p4, _} = List.last(TaskEvents.backlog(@transport, "t1"))
    assert TaskEvents.generation_of(p4) == 4

    # lastSeenGeneration resume works from the replayed log
    log_rows = TaskEvents.backlog(@transport, "t1")
    assert {:ok, replay, _cursor} = TaskEvents.replay_from_generation(log_rows, 2, nil)
    assert Enum.map(replay, &elem(&1, 0)) == [3, 4]
  end

  test "dets backend: trimmed events stay trimmed after restart", %{dir: dir} do
    log = {EventLog.Dets, dir: dir}
    start_events(log)

    for _ <- 1..105,
        do: TaskEvents.publish(@transport, "t2", "status-update", status("t2", "working"))

    before = TaskEvents.backlog(@transport, "t2")
    assert length(before) == 100

    stop_supervised!(TaskEvents)
    start_events(log)
    assert TaskEvents.backlog(@transport, "t2") == before
  end

  test "ETS task store drops a stale (lower-generation) put" do
    name = :"y3_tasks_#{System.unique_integer([:positive])}"
    start_supervised!({EtsStore, name: name})
    task = Task.new(id: "g1")
    :ok = EtsStore.put(name, %{task | generation: 5})
    :ok = EtsStore.put(name, %{task | generation: 3})
    assert {:ok, %{generation: 5}} = EtsStore.get(name, "g1")
    :ok = EtsStore.put(name, %{task | generation: 6})
    assert {:ok, %{generation: 6}} = EtsStore.get(name, "g1")
  end

  test "checkpoint envelope carries generation; handover restores it" do
    name = :"y3_cp_#{System.unique_integer([:positive])}"
    start_supervised!({EtsStore, name: name})
    store = {EtsStore, name}
    :ok = EtsStore.put(name, %{Task.new(id: "c1") | generation: 7})

    landed = Checkpoint.land(store, "c1", %{step: 2})
    assert Checkpoint.generation(landed) == 7

    assert {:ok, [%{task_id: "c1"}]} = Handover.rehydrate(store, fn _t, _f -> {:ok, :done} end)
    assert {:ok, %{generation: g}} = EtsStore.get(name, "c1")
    assert g == 8
  end
end
