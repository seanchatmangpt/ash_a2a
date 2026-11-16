# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Protocol.StreamGenerationTest do
  @moduledoc """
  A2A v1.1 specification 3.2.7: every mutation of a task is exactly one event,
  the event carries the task's generation after that mutation, generations
  increase by exactly 1, and the last one equals what `tasks/get` reports.

  Real agents, real `Plug.Test` SSE conns. No mocks.
  """
  use ExUnit.Case, async: true

  alias AshA2A.Protocol.Agent.Runtime
  alias AshA2A.Protocol.Part.Text
  alias AshA2A.Protocol.Task.{Delta, Generation}
  alias AshA2A.Protocol.Event.{ArtifactUpdate, MessageUpdate, StatusUpdate}

  defmodule Agent do
    use AshA2A.Protocol.Agent, name: "stream-generation", description: "streams or answers slowly"

    @impl AshA2A.Protocol.Agent
    def handle_message(message, _ctx) do
      case AshA2A.Protocol.Message.text(message) do
        "stream" -> {:stream, Stream.map(1..3, &Text.new("chunk #{&1}"))}
        "empty" -> {:stream, []}
        "ask" -> {:input_required, [Text.new("more?")]}
        _ -> {:reply, [Text.new("answer")]}
      end
    end
  end

  setup do
    agent = :"stream_generation_#{System.unique_integer([:positive])}"
    start_supervised!({Agent, name: agent})
    %{agent: agent}
  end

  defp stored(agent, id) do
    {:ok, task} = GenServer.call(agent, {:get_task, id})
    task
  end

  defp await_terminal(agent, id, tries \\ 100) do
    task = stored(agent, id)

    cond do
      AshA2A.Protocol.Task.terminal?(task) -> task
      tries == 0 -> flunk("task #{id} never finished")
      true -> Process.sleep(10) && await_terminal(agent, id, tries - 1)
    end
  end

  defp frames(conn) do
    for "data: " <> json <- String.split(conn.resp_body, "\n", trim: true),
        do: Jason.decode!(json)["result"]
  end

  defp frame_generation(frame) do
    case frame |> Map.values() |> hd() |> Map.get("generation") do
      g when is_binary(g) -> String.to_integer(g)
      g -> g
    end
  end

  test "each streamed chunk is one stored mutation at the generation tasks/get reports (3.2.7)",
       %{agent: agent} do
    {:ok, task, enum} = AshA2A.Protocol.stream(agent, "stream")
    start = Generation.generation_of(task)

    seen =
      Enum.map(enum, fn part ->
        gen = Runtime.chunk_generation(task.id)
        now = stored(agent, task.id)
        # The chunk is stored before it is handed out, at exactly this generation.
        assert Generation.generation_of(now) == gen
        assert part in Enum.flat_map(now.artifacts, & &1.parts)
        gen
      end)

    assert seen == [start + 1, start + 2, start + 3]

    final = await_terminal(agent, task.id)
    assert final.status.state == :completed
    # One more mutation: the terminal status. Completing the artifact is not one.
    assert Generation.generation_of(final) == start + 4
    assert [artifact] = final.artifacts
    assert Enum.map(artifact.parts, & &1.text) == ["chunk 1", "chunk 2", "chunk 3"]
    assert artifact.start_generation == start + 1
    assert artifact.end_generation == start + 3
    assert artifact.artifact_id == task.metadata.stream_artifact_id
  end

  test "a stream without chunks stores no artifact and skips no generation (3.2.7)",
       %{agent: agent} do
    {:ok, task, enum} = AshA2A.Protocol.stream(agent, "empty")
    assert Enum.to_list(enum) == []

    final = await_terminal(agent, task.id)
    assert final.artifacts == []
    assert Generation.generation_of(final) == Generation.generation_of(task) + 1
  end

  test "message/stream frames carry consecutive generations ending at the stored one (3.2.7)",
       %{agent: agent} do
    conn =
      Plug.Test.conn(:post, "/", "")
      |> AshA2A.Protocol.Plug.SSE.stream_message(
        agent,
        AshA2A.Protocol.Message.new_user("stream"),
        1
      )

    [%{"task" => snapshot} | events] = frames(conn)
    start = frame_generation(%{"task" => snapshot})
    gens = Enum.map(events, &frame_generation/1)

    assert Enum.map(events, &(&1 |> Map.keys() |> hd())) ==
             ["artifactUpdate", "artifactUpdate", "artifactUpdate", "statusUpdate"]

    assert gens == Enum.to_list((start + 1)..(start + 4))

    # All chunks belong to the one artifact the task stores.
    final = await_terminal(agent, snapshot["id"])
    assert Generation.generation_of(final) == List.last(gens)
    ids = for %{"artifactUpdate" => %{"artifact" => %{"artifactId" => id}}} <- events, do: id
    assert Enum.uniq(ids) == [hd(final.artifacts).artifact_id]
  end

  test "a subscriber receives the artifact mutation between the snapshot and the status (3.1.6, 3.2.7)",
       %{agent: agent} do
    {:ok, parked} = AshA2A.Protocol.call(agent, "ask")
    start = Generation.generation_of(parked)
    test = self()

    subscriber =
      Task.async(fn ->
        conn = Plug.Test.conn(:post, "/", "")
        send(test, :subscribing)

        AshA2A.Protocol.Plug.SSE.subscribe_task(conn, agent, parked.id, 1, 2_000, version: "1.1")
      end)

    assert_receive :subscribing
    # The subscriber registers inside the agent; this call is ordered after it.
    wait_for_subscriber(agent, parked.id)
    {:ok, done} = AshA2A.Protocol.call(agent, "finish", task_id: parked.id)

    [%{"task" => _} | events] = frames(Task.await(subscriber, 5_000))
    kinds = Enum.map(events, &(&1 |> Map.keys() |> hd()))
    gens = Enum.map(events, &frame_generation/1)

    assert "artifactUpdate" in kinds
    assert List.last(kinds) == "statusUpdate"
    # No gap: one event per generation, up to the stored one.
    assert gens == Enum.to_list((start + 1)..Generation.generation_of(done))

    assert [%{"artifactUpdate" => %{"artifact" => %{"parts" => [%{"text" => "answer"}]}}}] =
             Enum.filter(events, &Map.has_key?(&1, "artifactUpdate"))
  end

  defp wait_for_subscriber(agent, task_id, tries \\ 200) do
    state = :sys.get_state(agent)

    cond do
      AshA2A.Protocol.Agent.State.subscribers_for(state, task_id) != [] -> :ok
      tries == 0 -> flunk("the stream never subscribed")
      true -> Process.sleep(5) && wait_for_subscriber(agent, task_id, tries - 1)
    end
  end

  describe "Task.Delta.events/2" do
    test "one event per mutation, each at its own generation, none for a completed artifact",
         %{agent: agent} do
      {:ok, parked} = AshA2A.Protocol.call(agent, "ask")
      {:ok, done} = AshA2A.Protocol.call(agent, "finish", task_id: parked.id)

      events = Delta.events(parked, done)
      gens = Enum.map(events, &elem(&1, 0))

      assert gens ==
               Enum.to_list(
                 (Generation.generation_of(parked) + 1)..Generation.generation_of(done)
               )

      assert [%MessageUpdate{} | _] = Enum.map(events, &elem(&1, 1))

      assert {gen, %ArtifactUpdate{last_chunk: true, append: nil} = artifact} =
               Enum.find(events, &match?({_, %ArtifactUpdate{}}, &1))

      assert artifact.generation == gen
      assert {_, %StatusUpdate{final: true}} = List.last(events)

      assert Delta.events(done, done) == []

      assert Delta.events(nil, done) |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() ==
               length(Delta.events(nil, done))
    end

    test "an appended chunk is reported with only its new parts", %{agent: agent} do
      {:ok, task, enum} = AshA2A.Protocol.stream(agent, "stream")

      snapshots =
        Enum.map(enum, fn _part -> stored(agent, task.id) end)

      [first, second, third] = snapshots

      assert [{g1, %ArtifactUpdate{append: nil} = a1}] = Delta.events(task, first)
      assert [{g2, %ArtifactUpdate{append: true} = a2}] = Delta.events(first, second)
      assert [{g3, %ArtifactUpdate{append: true} = a3}] = Delta.events(second, third)
      assert [g2, g3] == [g1 + 1, g1 + 2]

      assert Enum.map([a1, a2, a3], &Enum.map(&1.artifact.parts, fn p -> p.text end)) ==
               [["chunk 1"], ["chunk 2"], ["chunk 3"]]
    end
  end
end
