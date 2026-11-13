defmodule AshA2A.TaskStoreAshContractTest do
  use AshA2A.TaskStoreContract, store: AshA2A.TaskStore.Ash

  alias AshA2A.TaskStore.Ash, as: Store

  # Ash ETS data layer: no process to start; isolation is per-namespace ref.
  def start_store(tag), do: "w18_ash_#{tag}_#{System.unique_integer([:positive])}"

  test "version increments on every put and starts at 0 when absent" do
    ref = start_store("version")
    assert Store.version(ref, "tsk-1") == 0
    :ok = Store.put(ref, contract_task("tsk-1", "ctx-1", :working, 1))
    assert Store.version(ref, "tsk-1") == 1
    :ok = Store.put(ref, contract_task("tsk-1", "ctx-1", :completed, 2))
    assert Store.version(ref, "tsk-1") == 2
  end

  test "optimistic concurrency: stale expected_version is refused and leaves state intact" do
    ref = start_store("occ")
    working = contract_task("tsk-1", "ctx-1", :working, 1)
    done = contract_task("tsk-1", "ctx-1", :completed, 2)

    assert :ok = Store.put(ref, working, expected_version: 0)
    assert {:error, :version_conflict} = Store.put(ref, working, expected_version: 0)
    assert :ok = Store.put(ref, done, expected_version: 1)
    assert {:error, :version_conflict} = Store.put(ref, working, expected_version: 1)
    assert {:ok, %{status: %{state: :completed}}} = Store.get(ref, "tsk-1")
    assert Store.version(ref, "tsk-1") == 2
  end

  test "columns are really persisted in the resource row" do
    ref = start_store("columns")
    owner_key = AshA2A.Transport.Runtime.owner_key()
    task = contract_task("tsk-9", "ctx-9", :working, 3)
    task = %{task | metadata: Map.put(task.metadata, owner_key, "principal:u1")}
    :ok = Store.put(ref, task)

    row =
      AshA2A.TaskStore.Ash.TaskRow
      |> Ash.read!(authorize?: false)
      |> Enum.find(&(&1.namespace == ref and &1.task_id == "tsk-9"))

    assert row.owner == "principal:u1"
    assert row.context_id == "ctx-9"
    assert row.status_state == "working"
    assert DateTime.compare(row.last_updated, contract_ts(3)) == :eq
    assert row.protocol_version == "1.0"
    assert row.version == 1
  end

  test "auth and stream metadata are not persisted" do
    ref = start_store("redact")
    task = contract_task("tsk-r", "ctx-1", :working, 1)

    task = %{
      task
      | metadata:
          Map.merge(task.metadata, %{"a2a.auth" => %{"token" => "SECRET"}, :stream => [1]})
    }

    :ok = Store.put(ref, task)
    {:ok, stored} = Store.get(ref, "tsk-r")
    refute Map.has_key?(stored.metadata, "a2a.auth")
    refute Map.has_key?(stored.metadata, :stream)
    assert stored.metadata["keep"] == "me"
  end
end
