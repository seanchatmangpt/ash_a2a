defmodule AshA2A.TaskUpdaterFixtures.UpperIdGenerator do
  @behaviour AshA2A.Protocol.Id.Generator

  @impl true
  def generate(kind, _ctx), do: "custom-" <> String.upcase(kind)
end

defmodule AshA2A.TaskUpdaterTest do
  use ExUnit.Case, async: false

  alias AshA2A.Protocol.{Part, ResultAggregator, TaskUpdater}
  alias AshA2A.Protocol.Event.{ArtifactUpdate, StatusUpdate}

  defp text_of(artifact), do: Enum.map_join(artifact.parts, & &1.text)

  test "lifecycle events and terminal guard" do
    u = TaskUpdater.new("t1", context_id: "c1")

    assert {:ok, u, %StatusUpdate{status: %{state: :working}, final: false}} =
             TaskUpdater.start_work(u)

    assert {:ok, u, %StatusUpdate{status: %{state: :input_required}}} =
             TaskUpdater.requires_input(u, "more?")

    assert {:ok, u, %StatusUpdate{status: %{state: :completed}, final: true}} =
             TaskUpdater.complete(u)

    assert {:error, {:terminal_state, :completed}} = TaskUpdater.fail(u)
    assert {:error, {:terminal_state, :completed}} = TaskUpdater.cancel(u)
    assert {:error, {:terminal_state, :completed}} = TaskUpdater.add_artifact(u, "x")
  end

  test "chunk assembly with append and last_chunk" do
    u = TaskUpdater.new("t2")
    {:ok, u, s1} = TaskUpdater.start_work(u, "go")
    {:ok, u, a1} = TaskUpdater.add_artifact(u, "Hel", artifact_id: "A")
    {:ok, u, a2} = TaskUpdater.add_artifact(u, "lo", artifact_id: "A", append: true)

    {:ok, u, a3} =
      TaskUpdater.add_artifact(u, [Part.Text.new("!")],
        artifact_id: "A",
        append: true,
        last_chunk: true
      )

    {:ok, _u, s2} = TaskUpdater.complete(u)

    assert %ArtifactUpdate{append: true, last_chunk: true} = a3

    task = ResultAggregator.aggregate([s1, a1, a2, a3, s2])
    assert task.id == "t2"
    assert task.status.state == :completed
    assert [%{artifact_id: "A"} = art] = task.artifacts
    assert text_of(art) == "Hello!"
    assert task.metadata.finalized_artifacts == ["A"]
    assert length(task.history) == 1
  end

  test "aggregator ignores status after terminal and replaces non-append artifact" do
    u = TaskUpdater.new("t3")
    {:ok, u, a1} = TaskUpdater.add_artifact(u, "one", artifact_id: "A")
    {:ok, u, a2} = TaskUpdater.add_artifact(u, "two", artifact_id: "A")
    {:ok, _u, done} = TaskUpdater.complete(u)
    late = StatusUpdate.new("t3", AshA2A.Protocol.Task.Status.new(:working))
    task = ResultAggregator.aggregate([a1, a2, done, late])
    assert task.status.state == :completed
    assert [art] = task.artifacts
    assert text_of(art) == "two"
  end

  test "id generator default and pluggable" do
    assert Application.get_env(:ash_a2a, :id_generator) == nil
    assert "tsk-" <> suffix = AshA2A.Protocol.ID.generate("tsk")
    assert byte_size(suffix) == 12

    Application.put_env(:ash_a2a, :id_generator, AshA2A.TaskUpdaterFixtures.UpperIdGenerator)
    on_exit(fn -> Application.delete_env(:ash_a2a, :id_generator) end)

    assert AshA2A.Protocol.ID.generate("msg") == "custom-MSG"
    assert AshA2A.Protocol.Task.new().id == "custom-TSK"
  end
end
