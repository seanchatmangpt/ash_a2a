# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# Real-store court for the Runtime orphan-sweep + heartbeat hook. Real
# `Protocol.TaskStore.ETS`, real `OrphanSweep`, real `handle_message_call/6`
# continue path. The in-flight worker table is the runtime's own
# process-dictionary table; a live worker is represented by a real
# monitored process registered exactly as `spawn_worker/4` registers one.
defmodule AshA2A.Execution.OrphanSweepRuntimeTest do
  use ExUnit.Case, async: true

  alias AshA2A.Protocol.{Message, Task}
  alias AshA2A.Protocol.Agent.State
  alias AshA2A.Transport.Runtime

  @ets AshA2A.Protocol.TaskStore.ETS

  setup do
    name = :"orphan_store_#{System.unique_integer([:positive])}"
    {:ok, _} = @ets.start_link(name: name)
    state = %State{module: nil, task_store: {@ets, name}}
    on_exit(fn -> Process.delete(:ash_a2a_in_flight) end)
    {:ok, state: state, name: name}
  end

  defp stale_working(id) do
    task = Task.new(id: id, context_id: "ctx-#{id}")
    old = DateTime.add(DateTime.utc_now(), -600, :second)
    %{task | status: %{Task.Status.new(:working) | timestamp: old}}
  end

  defp put(state, task) do
    {:ok, state} = State.put_task_checked(state, task)
    state
  end

  defp register_live_worker(task_id) do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    mref = Process.monitor(pid)
    Process.put(:ash_a2a_in_flight, %{make_ref() => {mref, nil, task_id, false}})
    on_exit(fn -> Process.exit(pid, :kill) end)
  end

  defp continue(state, id, agent_opts \\ [mode: :inline, orphan_sweep_interval_ms: false]) do
    Runtime.handle_message_call(
      nil,
      agent_opts,
      Message.new_user("again"),
      [task_id: id],
      nil,
      state
    )
  end

  test "orphan (no live worker) is failed, then continue sees a terminal task", %{state: state} do
    state = put(state, stale_working("orph-1"))

    assert {:reply, {:error, %{code: :task_in_progress}}, _} = continue(state, "orph-1")

    state = Runtime.sweep_orphans(state, %{lease_ms: 60_000})

    assert %{status: %{state: :failed}} = state.tasks["orph-1"]
    assert {:ok, %{status: %{state: :failed}}} = @ets.get(elem(state.task_store, 1), "orph-1")
    assert {:reply, {:error, :not_continuable}, _} = continue(state, "orph-1")
  end

  test "task with a live worker is left alone and heartbeat keeps it inside the lease", %{
    state: state
  } do
    task = stale_working("live-1")
    state = put(state, task)
    register_live_worker("live-1")

    state = Runtime.sweep_orphans(state, %{lease_ms: 60_000})
    assert %{status: %{state: :working}} = state.tasks["live-1"]

    state = Runtime.heartbeat(state)
    fresh = state.tasks["live-1"]
    assert DateTime.compare(fresh.status.timestamp, task.status.timestamp) == :gt
    assert DateTime.diff(DateTime.utc_now(), fresh.status.timestamp, :millisecond) < 5_000

    assert {:ok, %{status: %{timestamp: ts}}} = @ets.get(elem(state.task_store, 1), "live-1")
    assert ts == fresh.status.timestamp
  end

  test "ensure_sweep arms one timer message and sweeps at start", %{state: state} do
    state = put(state, stale_working("orph-2"))
    cfg = [orphan_sweep_interval_ms: 20, orphan_lease_ms: 60_000]

    state = Runtime.ensure_sweep(cfg, state)
    assert %{status: %{state: :failed}} = state.tasks["orph-2"]

    assert_receive :ash_a2a_orphan_sweep, 2_000
    assert {:noreply, _} = Runtime.handle_info(:ash_a2a_orphan_sweep, state)
    assert_receive :ash_a2a_orphan_sweep, 2_000
  end
end
