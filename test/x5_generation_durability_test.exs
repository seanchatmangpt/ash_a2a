defmodule AshA2A.X5GenerationDurabilityTest do
  @moduledoc """
  Lane X5: v1.1 `generation`, `timeline` and artifact `start_generation` /
  `end_generation` survive the task stores, and a stale (lower-generation)
  write never lowers the stored generation.

  Stale-write policy: NO-OP returning `:ok` (EKV and Ash stores). The ETS
  reference store has no guard (not owned by this lane); only its round trip
  is asserted.

  The Ash store's data layer is `Ash.DataLayer.Ets` (node-lifetime), so its
  "restart" is a fresh reader over the same namespace, not a process restart.
  """

  use ExUnit.Case, async: false

  @moduletag :serial

  alias AshA2A.Protocol.{Artifact, Message, Part, Task, TaskStore, TimelineEntry}
  alias AshA2A.TaskStore.Ash, as: AshStore
  alias AshA2A.TaskStore.Ekv, as: EkvStore

  defp uniq, do: System.unique_integer([:positive])

  defp gen_task(id, generation) do
    status = %Task.Status{state: :working, timestamp: DateTime.utc_now(), message: nil}

    %Task{
      id: id,
      context_id: "ctx-x5",
      status: status,
      history: [],
      artifacts: [
        %{
          Artifact.new([Part.Text.new("a")], name: "a")
          | start_generation: 2,
            end_generation: generation
        }
      ],
      metadata: %{},
      generation: generation,
      timeline: [
        %TimelineEntry{entry: {:message, Message.new_user("hi")}, generation: 1},
        %TimelineEntry{entry: {:status, status}, generation: generation}
      ]
    }
  end

  defp assert_fields(%Task{} = stored, %Task{} = expected) do
    assert stored.generation == expected.generation
    assert stored.timeline == expected.timeline
    assert Enum.map(stored.timeline, & &1.generation) == [1, expected.generation]
    [sa] = stored.artifacts
    [ea] = expected.artifacts
    assert sa.start_generation == 2
    assert sa.end_generation == ea.end_generation
  end

  defp ekv_setup do
    id = uniq()
    name = :"x5_gen_ekv_#{id}"
    dir = Path.join(System.tmp_dir!(), "x5_gen_#{id}")
    File.rm_rf!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    start_supervised!(EkvStore.child_spec(name: name, data_dir: dir))
    {name, dir}
  end

  test "ETS round trip preserves generation, timeline, artifact generations" do
    name = :"x5_gen_ets_#{uniq()}"
    start_supervised!({TaskStore.ETS, [name: name]})
    task = gen_task("tsk-x5-ets", 7)
    assert :ok = TaskStore.ETS.put(name, task)
    assert {:ok, stored} = TaskStore.ETS.get(name, task.id)
    assert_fields(stored, task)
  end

  test "EKV preserves fields across a real store restart; stale write is a no-op" do
    {name, dir} = ekv_setup()
    task = gen_task("tsk-x5-ekv", 7)
    assert :ok = EkvStore.put(name, task)

    assert :ok = stop_supervised({EKV, name})
    start_supervised!(EkvStore.child_spec(name: name, data_dir: dir))

    assert {:ok, stored} = EkvStore.get(name, task.id)
    assert_fields(stored, task)

    stale = gen_task("tsk-x5-ekv", 3)
    assert :ok = EkvStore.put(name, stale)
    assert {:ok, after_stale} = EkvStore.get(name, task.id)
    assert after_stale.generation == 7
    assert_fields(after_stale, task)

    # Equal and higher generations still write.
    assert :ok = EkvStore.put(name, gen_task("tsk-x5-ekv", 9))
    assert {:ok, %Task{generation: 9}} = EkvStore.get(name, task.id)
  end

  test "Ash store preserves fields for a fresh reader; stale write is a no-op" do
    ref = "x5_gen_ash_#{uniq()}"
    task = gen_task("tsk-x5-ash", 7)
    assert :ok = AshStore.put(ref, task)
    assert AshStore.version(ref, task.id) == 1

    assert {:ok, stored} = AshStore.get(ref, task.id)
    assert_fields(stored, task)

    assert :ok = AshStore.put(ref, gen_task("tsk-x5-ash", 3))
    assert {:ok, after_stale} = AshStore.get(ref, task.id)
    assert after_stale.generation == 7
    assert_fields(after_stale, task)
    assert AshStore.version(ref, task.id) == 1

    assert :ok = AshStore.put(ref, gen_task("tsk-x5-ash", 9))
    assert {:ok, %Task{generation: 9}} = AshStore.get(ref, task.id)
    assert AshStore.version(ref, task.id) == 2
  end
end
