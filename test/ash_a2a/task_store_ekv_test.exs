defmodule AshA2A.TaskStoreEkvTest do
  @moduledoc """
  R3 (task durability, lane scope): `AshA2A.TaskStore.Ekv` against a real
  on-disk `EKV` instance and a real `AshA2A.Agent` GenServer
  (`AshA2A.Test.Fixture.EchoAgent`). Proves task state survives a real
  agent kill (`Process.exit(pid, :kill)`) and a real EKV restart against
  the same `data_dir`. No mocks.
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard

  alias AshA2A.Test.Fixture.EchoAgent
  alias AshA2A.TaskStore.Ekv, as: Store

  setup do
    id = System.unique_integer([:positive])
    name = :"ash_a2a_task_store_ekv_test_#{id}"
    data_dir = Path.join(System.tmp_dir!(), "ash_a2a_task_store_ekv_test_#{id}")
    File.rm_rf!(data_dir)
    on_exit(fn -> File.rm_rf!(data_dir) end)

    start_supervised!(Store.child_spec(name: name, data_dir: data_dir))
    %{name: name, data_dir: data_dir}
  end

  defp task(id, context_id, state \\ :submitted) do
    %A2A.Task{
      id: id,
      context_id: context_id,
      status: A2A.Task.Status.new(state),
      history: [],
      artifacts: []
    }
  end

  test "put/get/list/list_all/delete round-trip", %{name: name} do
    assert {:error, :not_found} = Store.get(name, "t-1")

    assert :ok = Store.put(name, task("t-1", "ctx-a"))
    assert :ok = Store.put(name, task("t-2", "ctx-a", :completed))
    assert :ok = Store.put(name, task("t-3", "ctx-b"))

    assert {:ok, %A2A.Task{id: "t-1", context_id: "ctx-a"}} = Store.get(name, "t-1")
    assert {:ok, ctx_a} = Store.list(name, "ctx-a")
    assert ctx_a |> Enum.map(& &1.id) |> Enum.sort() == ["t-1", "t-2"]

    assert {:ok, %{tasks: all}} = Store.list_all(name, [])
    assert all |> Enum.map(& &1.id) |> Enum.sort() == ["t-1", "t-2", "t-3"]

    assert :ok = Store.delete(name, "t-1")
    assert {:error, :not_found} = Store.get(name, "t-1")
  end

  test "tasks survive a real agent kill when the agent uses this store", %{name: name} do
    agent_name = :"echo_agent_durable_#{System.unique_integer([:positive])}"
    store = Store.task_store(name)

    {:ok, pid} = EchoAgent.start_link(name: agent_name, task_store: store)
    Process.unlink(pid)

    assert {:ok, %A2A.Task{id: task_id} = created} =
             EchoAgent.call(agent_name, A2A.Message.new_user("hello"))

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    {:ok, restarted} = EchoAgent.start_link(name: agent_name, task_store: store)
    assert {:ok, %A2A.Task{id: ^task_id} = recovered} = EchoAgent.get_task(agent_name, task_id)
    assert recovered.status.state == created.status.state
    GenServer.stop(restarted)

    # Control: an agent WITHOUT the store has lost the task after the same kill.
    control_name = :"echo_agent_memory_#{System.unique_integer([:positive])}"
    {:ok, control} = EchoAgent.start_link(name: control_name)
    Process.unlink(control)

    assert {:ok, %A2A.Task{id: control_task_id}} =
             EchoAgent.call(control_name, A2A.Message.new_user("hello"))

    control_ref = Process.monitor(control)
    Process.exit(control, :kill)
    assert_receive {:DOWN, ^control_ref, :process, ^control, :killed}

    {:ok, control2} = EchoAgent.start_link(name: control_name)
    assert {:error, :not_found} = EchoAgent.get_task(control_name, control_task_id)
    GenServer.stop(control2)
  end

  test "tasks survive a real EKV restart against the same data_dir",
       %{name: name, data_dir: data_dir} do
    assert :ok = Store.put(name, task("persist-1", "ctx-p", :working))

    child_id = {EKV, name}
    assert :ok = stop_supervised(child_id)
    start_supervised!(Store.child_spec(name: name, data_dir: data_dir))

    assert {:ok, %A2A.Task{id: "persist-1", context_id: "ctx-p"} = t} =
             Store.get(name, "persist-1")

    assert t.status.state == :working
  end

  test "a write EKV does not acknowledge raises instead of returning a silent error",
       %{name: name} do
    # A CAS-managed key refuses eventual (non-CAS) puts with
    # {:error, :cas_managed_key} -- a real, non-:ok EKV write result.
    assert {:ok, _vsn} = EKV.put(name, "a2a_task/cas-1", :placeholder, if_vsn: nil)

    assert_raise Store.WriteError, ~r/put of task "cas-1" failed/, fn ->
      Store.put(name, task("cas-1", "ctx"))
    end
  end

  test "the verified credential and node-local stream are never written to disk",
       %{name: name, data_dir: data_dir} do
    owner = AshA2A.Transport.Runtime.owner_key()

    working = %{
      task("auth-1", "ctx-auth", :working)
      | metadata: %{
          "a2a.auth" => %{identity: %{sub: "u1", token: "SECRET-BEARER-TOKEN"}},
          owner => "principal:u1",
          :stream => Stream.map([1], & &1),
          "keep" => "me"
        }
    }

    assert :ok = Store.put(name, working)

    # Raw EKV read (not through the store) -- what is actually persisted.
    persisted = EKV.get(name, "a2a_task/auth-1")
    refute Map.has_key?(persisted.metadata, "a2a.auth")
    refute Map.has_key?(persisted.metadata, :stream)
    assert persisted.metadata[owner] == "principal:u1"
    assert persisted.metadata["keep"] == "me"

    # And the token bytes are absent from the on-disk files themselves.
    assert :ok = stop_supervised({EKV, name})

    on_disk =
      data_dir
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.map_join(&File.read!/1)

    refute on_disk =~ "SECRET-BEARER-TOKEN"
    assert on_disk =~ "principal:u1"
  end

  test "child_spec fails closed without an explicit data_dir" do
    assert_raise ArgumentError, ~r/requires an explicit :data_dir/, fn ->
      Store.child_spec(name: :no_dir)
    end

    assert_raise ArgumentError, ~r/requires :name/, fn ->
      Store.child_spec(data_dir: "/tmp/x")
    end
  end
end
