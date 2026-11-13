# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Cluster.DrainIsolationTest.FlakyStore do
  @moduledoc false
  # A real (hand-written) task-store interface implementation: an Agent-backed
  # map whose `put/2` fails for tasks whose id starts with "bad-".
  def start, do: Agent.start_link(fn -> %{} end)

  def get(agent, id) do
    case Agent.get(agent, &Map.get(&1, id)) do
      nil -> {:error, :not_found}
      task -> {:ok, task}
    end
  end

  def put(_agent, %{id: "bad-" <> _}), do: {:error, :disk_full}

  def put(agent, task) do
    Agent.update(agent, &Map.put(&1, task.id, task))
  end
end

defmodule AshA2A.Cluster.DrainIsolationTest do
  use ExUnit.Case, async: false

  alias AshA2A.Cluster.DrainIsolationTest.FlakyStore
  alias AshA2A.Cluster.DrainManager

  test "one failing checkpoint does not abort the drain of the other tasks" do
    {:ok, store} = FlakyStore.start()
    name = :"drain_isolation_#{System.unique_integer([:positive])}"
    parent = self()
    handler = "drain-isolation-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [
        [:ash_a2a, :cluster, :drain, :complete],
        [:ash_a2a, :cluster, :drain, :task_skipped]
      ],
      fn event, _m, meta, _ -> send(parent, {:telemetry, event, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    manager =
      start_supervised!(
        {DrainManager,
         name: name,
         task_store: {FlakyStore, store},
         drain_timeout_ms: 20,
         install_signal_handler: false}
      )

    ref = Process.monitor(manager)

    # `track/3` registers the CALLING process as the worker, so each worker
    # tracks itself.
    start_worker = fn id, frame ->
      worker =
        spawn(fn ->
          :ok = DrainManager.track(name, id)
          :ok = DrainManager.update_frame(name, id, frame)
          send(parent, {:tracked, id})
          receive do: (:stop -> :ok)
        end)

      assert_receive {:tracked, ^id}, 1_000
      worker
    end

    bad = start_worker.("bad-1", %{step: 1})
    good = start_worker.("good-1", %{step: 2})

    assert {:ok, _cordon_at} = DrainManager.drain(name)

    assert_receive {:telemetry, [:ash_a2a, :cluster, :drain, :complete], meta}, 5_000
    assert meta.checkpointed == ["good-1"]

    assert_receive {:telemetry, [:ash_a2a, :cluster, :drain, :task_skipped],
                    %{task_id: "bad-1", reason: :checkpoint_failed}},
                   1_000

    assert_receive {:DOWN, ^ref, :process, ^manager, :shutdown}, 5_000

    # The worker whose frame did not land is NOT evicted; the landed one is.
    assert Process.alive?(bad)
    refute Process.alive?(good)
    assert {:ok, _} = FlakyStore.get(store, "good-1")
    assert {:error, :not_found} = FlakyStore.get(store, "bad-1")
    send(bad, :stop)
  end
end

defmodule AshA2A.Cluster.CheckpointFencingTest.DroppingStore do
  @moduledoc false
  # A real store interface that answers `:ok` to a put but keeps the previous
  # value, the way a stale-generation guard does.
  def start, do: Agent.start_link(fn -> %{} end)
  def get(_agent, _id), do: {:error, :not_found}
  def put(_agent, _task), do: :ok
end

defmodule AshA2A.Cluster.CheckpointFencingTest do
  use ExUnit.Case, async: true

  alias AshA2A.Cluster.Checkpoint
  alias AshA2A.Cluster.CheckpointFencingTest.DroppingStore

  test "a store that silently drops the write is not reported as landed" do
    {:ok, store} = DroppingStore.start()

    assert_raise RuntimeError, ~r/was not stored/, fn ->
      Checkpoint.land({DroppingStore, store}, "task-1", %{step: 1})
    end
  end
end
