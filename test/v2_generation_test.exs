defmodule AshA2A.V2GenerationTest do
  use ExUnit.Case, async: true

  alias AshA2A.Protocol.{Artifact, Message, Task, TimelineEntry}
  alias AshA2A.Protocol.Agent.{Runtime, State}
  alias AshA2A.Protocol.Task.{Filter, Generation, Status}

  defmodule TurnAgent do
    # First turn asks for input; the continuation completes.
    def handle_message(%Message{} = msg, %{history: history}) do
      text = inspect(msg.parts)

      if String.contains?(text, "finish"), do: {:reply, "done"}, else: {:input_required, "more?" <> to_string(length(history))}
    end
  end

  describe "Generation (pure)" do
    test "initial is 1 and a new task carries it" do
      assert Generation.initial() == 1
      assert Generation.generation_of(Task.new()) == 1
    end

    test "each mutation increments by exactly 1 and stamps entries" do
      t0 = Task.new()
      t1 = Generation.append_message(t0, Message.new_user("hi"))
      t2 = Generation.append_status(t1, Status.new(:working))
      reply = Message.new_agent("ask")
      t3 = Generation.append_status(t2, Status.new(:input_required, reply))

      assert [g1, g2, g3] = Enum.map(t3.timeline, & &1.generation)
      assert {g1, g2, g3} == {2, 3, 4}
      assert t3.generation == 4

      assert [%TimelineEntry{entry: {:message, _}}, %TimelineEntry{entry: {:status, _}}, %TimelineEntry{entry: {:status, %Status{state: :input_required}}}] =
               t3.timeline

      assert t3.status.state == :input_required
    end

    test "history stays in sync, without duplicating an already-appended message" do
      reply = Message.new_agent("ask")
      t = %{Task.new() | history: [reply]}
      t = Generation.append_status(t, Status.new(:input_required, reply))
      assert t.history == [reply]

      u = Message.new_user("x")
      t = Generation.append_message(t, u)
      assert t.history == [reply, u]
    end

    test "artifacts leave generation gaps in the timeline and carry start/end generation" do
      t = Generation.append_status(Task.new(), Status.new(:working))
      art = Artifact.new([AshA2A.Protocol.Part.Text.new("a")])

      {t, a1} = Generation.record_artifact(t, art, false)
      assert a1.start_generation == 3
      assert a1.end_generation == nil
      assert t.generation == 3

      {t, a2} = Generation.record_artifact(t, art, true)
      assert a2.start_generation == 3
      assert a2.end_generation == 4
      assert length(a2.parts) == 2
      assert length(t.artifacts) == 1

      t = Generation.append_status(t, Status.new(:completed))
      assert Enum.map(t.timeline, & &1.generation) == [2, 5]
      assert t.generation == 5
    end

    test "matches?/2" do
      t = Task.new()
      assert Generation.matches?(t, nil)
      assert Generation.matches?(t, 1)
      refute Generation.matches?(t, 2)
    end

    test "truncate_timeline/2" do
      t =
        Task.new()
        |> Generation.append_status(Status.new(:working))
        |> Generation.append_status(Status.new(:completed))

      assert length(Generation.truncate_timeline(t, nil).timeline) == 2
      assert Generation.truncate_timeline(t, 0).timeline == []
      assert [%TimelineEntry{generation: 3}] = Generation.truncate_timeline(t, 1).timeline
      assert length(Generation.truncate_timeline(t, 10).timeline) == 2
    end
  end

  describe "state machine (real runtime)" do
    test "submitted -> working -> input_required -> working -> completed" do
      state = %State{module: TurnAgent}

      {task, state} = Runtime.process_message(TurnAgent, Message.new_user("start"), "ctx", state)
      assert %Task{status: %{state: :input_required}} = task
      # message(2) working(3) input_required(4)
      assert task.generation == 4
      assert Enum.map(task.timeline, & &1.generation) == [2, 3, 4]
      assert length(task.history) == 2

      assert {:ok, {task, _state}} =
               Runtime.continue_task(TurnAgent, Message.new_user("finish"), task, state)

      assert task.status.state == :completed
      gens = Enum.map(task.timeline, & &1.generation)
      assert gens == Enum.sort(gens)
      assert gens == Enum.uniq(gens)
      # message(5) working(6) artifact(7) completed(8)
      assert task.generation == 8
      assert gens == [2, 3, 4, 5, 6, 8]

      assert [
               {:message, _},
               {:status, %{state: :working}},
               {:status, %{state: :input_required}},
               {:message, _},
               {:status, %{state: :working}},
               {:status, %{state: :completed}}
             ] = Enum.map(task.timeline, & &1.entry)

      assert length(task.history) >= 4

      assert [%Artifact{start_generation: 7, end_generation: 7}] = task.artifacts
    end

    test "list truncation of timeline and history is independent" do
      state = %State{module: TurnAgent}
      {task, _} = Runtime.process_message(TurnAgent, Message.new_user("start"), "ctx", state)

      {:ok, %{tasks: [only]}} = Filter.apply([task], history_length: 1, timeline_length: 2)
      assert length(only.history) == 1
      assert length(only.timeline) == 2

      {:ok, %{tasks: [none]}} = Filter.apply([task], history_length: 2, timeline_length: 0)
      assert length(none.history) == 2
      assert none.timeline == []

      {:ok, %{tasks: [all]}} = Filter.apply([task], history_length: 0)
      assert all.history == []
      assert length(all.timeline) == 3
    end

    test "stores round-trip generation fields via ETS state put/get" do
      state = %State{module: TurnAgent}
      {task, state} = Runtime.process_message(TurnAgent, Message.new_user("start"), "ctx", state)
      state = State.put_task(state, task)
      assert {:ok, ^task} = State.get_task(state, task.id)
    end
  end
end
