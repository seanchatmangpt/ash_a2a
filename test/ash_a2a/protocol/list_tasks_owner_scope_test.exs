defmodule AshA2A.Protocol.ListTasksOwnerScopeTest do
  use ExUnit.Case, async: true

  alias AshA2A.Protocol.Agent.State
  alias AshA2A.Protocol.Task
  alias AshA2A.Transport.Runtime

  defp task(id, owner) do
    %Task{
      id: id,
      context_id: "ctx-#{id}",
      status: %{state: :submitted},
      metadata: %{"ash_a2a.owner" => owner}
    }
  end

  defp state do
    tasks = %{"t-alice" => task("t-alice", "alice"), "t-bob" => task("t-bob", "bob")}
    %State{tasks: tasks}
  end

  defp ids({:ok, result}) do
    result |> Map.fetch!(:tasks) |> Enum.map(& &1.id) |> Enum.sort()
  end

  test "a principal lists only its own tasks" do
    assert ids(Runtime.list_tasks_for(state(), "alice", %{})) == ["t-alice"]
    assert ids(Runtime.list_tasks_for(state(), "bob", %{})) == ["t-bob"]
  end

  test "an unknown principal sees nothing" do
    assert ids(Runtime.list_tasks_for(state(), "mallory", %{})) == []
  end

  test "anonymous never lists" do
    assert ids(Runtime.list_tasks_for(state(), :anonymous, %{})) == []
  end
end
