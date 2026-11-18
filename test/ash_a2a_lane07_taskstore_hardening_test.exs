defmodule AshA2A.Lane07TaskStoreHardeningTest do
  @moduledoc "Lane 07 courts: terminal safety, store errors, Ekv push-config, handover CAS, filter."
  use ExUnit.Case, async: false

  alias AshA2A.Cluster.{Checkpoint, Handover}
  alias AshA2A.Protocol.Agent.State
  alias AshA2A.Protocol.Task
  alias AshA2A.Protocol.Task.Status
  alias AshA2A.Protocol.TaskStore
  alias AshA2A.TaskStore.Ekv

  defmodule Agent1 do
    use AshA2A.Agent,
      resource_or_domain: AshA2A.Test.Fixture.Echo,
      name: "lane07_hardening_agent"

    @impl AshA2A.Protocol.Agent
    def handle_message(_m, _c), do: {:reply, [AshA2A.Protocol.Part.Text.new("ok")]}
  end

  # Hand-written real store whose writes always fail.
  defmodule FullStore do
    def put(_ref, _task), do: {:error, :disk_full}
    def get(_ref, _id), do: {:error, :not_found}
  end

  defp ekv!(tag) do
    id = System.unique_integer([:positive])
    name = :"lane07_#{tag}_#{id}"
    dir = Path.join(System.tmp_dir!(), "lane07_#{tag}_#{id}")
    File.rm_rf!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {name, dir}
  end

  defp with_state(task, st), do: %{task | status: Status.new(st)}

  test "stream_done after cancel never overwrites the terminal state" do
    name = :"lane07_ets_#{System.unique_integer([:positive])}"
    start_supervised!({TaskStore.ETS, [name: name]})
    {:ok, pid} = Agent1.start_link(name: Agent1, task_store: {TaskStore.ETS, name})

    task = Task.new(id: "tsk-cancel-race") |> with_state(:canceled)
    :ok = TaskStore.ETS.put(name, task)

    GenServer.cast(
      pid,
      {:stream_done, task.id, nil, [AshA2A.Protocol.Part.Text.new("late")], :complete}
    )

    assert {:ok, got} = GenServer.call(pid, {:get_task, task.id})
    assert got.status.state == :canceled
    assert got.artifacts == []
  end

  test "terminal states are never transitioned out of (no resurrect)" do
    for t <- [:completed, :failed, :canceled, :rejected] do
      task = Task.new() |> with_state(t)
      assert State.transition(task, :working).status.state == t
    end

    assert State.transition(Task.new(), :working).status.state == :working
  end

  test "put_task_checked surfaces store errors and does not cache the task" do
    state = %State{module: Agent1, task_store: {FullStore, :x}}
    task = Task.new()
    assert {:error, {:store_write_failed, :disk_full}} = State.put_task_checked(state, task)
  end

  test "Ekv push configs survive a store restart; delete is authoritative" do
    {name, dir} = ekv!(:push)
    spec = Ekv.child_spec(name: name, data_dir: dir)
    {:ok, sup} = Supervisor.start_link([spec], strategy: :one_for_one)

    cfg = %AshA2A.Protocol.PushNotificationConfig{
      id: "c1",
      task_id: "t1",
      url: "https://x.test/h"
    }

    cfg2 = %{cfg | id: "c2"}
    assert {:ok, ^cfg} = Ekv.set_push_config(name, cfg)
    assert {:ok, ^cfg2} = Ekv.set_push_config(name, cfg2)
    :ok = Ekv.delete_push_config(name, "t1", "c2")

    Supervisor.stop(sup)
    {:ok, sup2} = Supervisor.start_link([spec], strategy: :one_for_one)

    assert {:ok, ^cfg} = Ekv.get_push_config(name, "t1", "c1")
    assert {:error, :not_found} = Ekv.get_push_config(name, "t1", "c2")
    assert {:ok, [^cfg]} = Ekv.list_push_configs(name, "t1")
    assert {:ok, []} = Ekv.list_push_configs(name, "other")
  end

  test ":input_required and :auth_required survive an Ekv store restart" do
    {name, dir} = ekv!(:park)
    spec = Ekv.child_spec(name: name, data_dir: dir)
    {:ok, sup} = Supervisor.start_link([spec], strategy: :one_for_one)

    for {id, st} <- [{"tsk-ir", :input_required}, {"tsk-ar", :auth_required}] do
      :ok = Ekv.put(name, Task.new(id: id) |> with_state(st))
    end

    Supervisor.stop(sup)
    {:ok, sup2} = Supervisor.start_link([spec], strategy: :one_for_one)

    assert {:ok, %{status: %{state: :input_required}}} = Ekv.get(name, "tsk-ir")
    assert {:ok, %{status: %{state: :auth_required}}} = Ekv.get(name, "tsk-ar")
  end

  test "filter ties break deterministically by id; nil status is safe; dead cursor is typed" do
    ts = ~U[2026-01-01 00:00:00Z]

    mk = fn id ->
      %{Task.new(id: id) | status: %Status{state: :working, timestamp: ts}}
    end

    nil_status = %{Task.new(id: "nil") | status: nil}
    tasks = [mk.("b"), mk.("a"), mk.("c"), nil_status]

    {:ok, %{tasks: page}} = Task.Filter.apply(tasks, page_size: 10)
    assert Enum.map(page, & &1.id) == ["c", "b", "a", "nil"]
    {:ok, %{tasks: page2}} = Task.Filter.apply(Enum.reverse(tasks), page_size: 10)
    assert Enum.map(page2, & &1.id) == ["c", "b", "a", "nil"]

    assert {:ok, %{tasks: only}} = Task.Filter.apply(tasks, status: :working)
    assert length(only) == 3
    assert {:error, :invalid_page_token} = Task.Filter.apply(tasks, page_token: "gone")
  end

  test "checkpoint land does not resurrect a terminal task" do
    name = :"lane07_ets_#{System.unique_integer([:positive])}"
    start_supervised!({TaskStore.ETS, [name: name]})
    done = Task.new(id: "tsk-done") |> with_state(:completed)
    :ok = TaskStore.ETS.put(name, done)

    landed = Checkpoint.land({TaskStore.ETS, name}, "tsk-done", %{step: 1})
    refute Checkpoint.checkpointed?(landed)
    assert {:ok, %{status: %{state: :completed}} = stored} = TaskStore.ETS.get(name, "tsk-done")
    refute Checkpoint.checkpointed?(stored)
  end

  test "two peers rehydrating concurrently resume the task exactly once" do
    name = :"lane07_ets_#{System.unique_integer([:positive])}"
    start_supervised!({TaskStore.ETS, [name: name]})
    store = {TaskStore.ETS, name}
    :ok = TaskStore.ETS.put(name, Task.new(id: "tsk-cas") |> with_state(:working))
    Checkpoint.land(store, "tsk-cas", %{step: 1})
    {:ok, [task]} = Handover.list_checkpointed(store)

    counter = :counters.new(1, [])

    resume = fn _t, _frame ->
      :counters.add(counter, 1, 1)
      {:ok, :done}
    end

    results =
      1..8
      |> Enum.map(fn _ ->
        Elixir.Task.async(fn -> Handover.rehydrate_one(store, task, resume) end)
      end)
      |> Enum.map(&Elixir.Task.await(&1, 5_000))

    assert :counters.get(counter, 1) == 1
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert {:ok, %{status: %{state: :completed}}} = TaskStore.ETS.get(name, "tsk-cas")
  end

  test "resume throw/exit is collected and the checkpoint stays adoptable" do
    name = :"lane07_ets_#{System.unique_integer([:positive])}"
    start_supervised!({TaskStore.ETS, [name: name]})
    store = {TaskStore.ETS, name}
    Checkpoint.land(store, "tsk-throw", %{})
    {:ok, [task]} = Handover.list_checkpointed(store)

    assert {:error, %{reason: {:throw, :boom}}} =
             Handover.rehydrate_one(store, task, fn _, _ -> throw(:boom) end)

    assert {:ok, [_]} = Handover.list_checkpointed(store)
    assert {:ok, _} = Handover.rehydrate_one(store, task, fn _, _ -> {:ok, 1} end)
  end

  test "list_checkpointed on a store without list_all is a typed error" do
    assert {:error, {:unsupported, :list_all}} = Handover.list_checkpointed({FullStore, :x})
  end

  test "orphan sweep fails stale :working tasks without a live worker" do
    name = :"lane07_ets_#{System.unique_integer([:positive])}"
    start_supervised!({TaskStore.ETS, [name: name]})

    old = %{
      Task.new(id: "tsk-old")
      | status: %Status{state: :working, timestamp: ~U[2020-01-01 00:00:00Z]}
    }

    live = %{old | id: "tsk-live"}
    :ok = TaskStore.ETS.put(name, old)
    :ok = TaskStore.ETS.put(name, live)

    assert {:ok, ["tsk-old"]} =
             Task.OrphanSweep.sweep({TaskStore.ETS, name}, live?: &(&1 == "tsk-live"))

    assert {:ok, %{status: %{state: :failed}}} = TaskStore.ETS.get(name, "tsk-old")
    assert {:ok, %{status: %{state: :working}}} = TaskStore.ETS.get(name, "tsk-live")
  end
end
