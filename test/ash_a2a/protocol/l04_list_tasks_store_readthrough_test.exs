defmodule AshA2A.Protocol.L04ListTasksStoreReadThroughTest do
  use ExUnit.Case, async: true

  alias AshA2A.Protocol.Agent.State
  alias AshA2A.Protocol.Task
  alias AshA2A.Protocol.TaskStore.ETS, as: Store
  alias AshA2A.Transport.Runtime

  defp task(id, owner) do
    %Task{
      id: id,
      context_id: "ctx-#{id}",
      status: %{state: :submitted},
      metadata: %{"ash_a2a.owner" => owner}
    }
  end

  defp ids({:ok, result}), do: result |> Map.fetch!(:tasks) |> Enum.map(& &1.id) |> Enum.sort()

  setup do
    name = :"l04_store_#{System.unique_integer([:positive])}"
    start_supervised!({Store, name: name})
    :ok = Store.put(name, task("stored-alice", "alice"))
    :ok = Store.put(name, task("stored-bob", "bob"))
    {:ok, store: {Store, name}}
  end

  test "an agent with an empty in-memory map lists the owner's stored tasks", %{store: store} do
    state = %State{tasks: %{}, task_store: store}

    assert ids(Runtime.list_tasks_for(state, "alice", %{})) == ["stored-alice"]
    assert ids(Runtime.list_tasks_for(state, "bob", %{})) == ["stored-bob"]
  end

  test "stored and in-memory tasks merge without duplicates", %{store: store} do
    state = %State{
      tasks: %{
        "mem-alice" => task("mem-alice", "alice"),
        "stored-alice" => task("stored-alice", "alice")
      },
      task_store: store
    }

    assert ids(Runtime.list_tasks_for(state, "alice", %{})) == ["mem-alice", "stored-alice"]
  end

  test "owner scoping holds against the store: unknown principal and anonymous see nothing",
       %{store: store} do
    state = %State{tasks: %{}, task_store: store}

    assert ids(Runtime.list_tasks_for(state, "mallory", %{})) == []
    assert ids(Runtime.list_tasks_for(state, :anonymous, %{})) == []
  end
end
