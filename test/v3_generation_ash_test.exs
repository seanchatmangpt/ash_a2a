# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.V3.Converse do
  @moduledoc false
  use Ash.Resource,
    domain: AshA2A.V3.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  actions do
    # Omitting `:text` parks the task `:input_required`; supplying it completes.
    action :converse, :map do
      argument(:text, :string, allow_nil?: false)
      run(fn input, _context -> {:ok, %{text: input.arguments.text}} end)
    end
  end

  a2a do
    skill(:converse, :converse, consequence: :observe)
  end
end

defmodule AshA2A.V3.Domain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.V3.Converse)
  end
end

defmodule AshA2A.V3.PlainAgent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.V3.Converse,
    name: "v3_plain_agent",
    require_authenticated_caller: false
end

defmodule AshA2A.V3.UserArtifactsAgent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.V3.Converse,
    name: "v3_user_artifacts_agent",
    require_authenticated_caller: false,
    capabilities: %{streaming: true, user_artifacts: true}
end

defmodule AshA2A.V3.UserArtifactsDomain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A, AshA2A.Domain], validate_config_inclusion?: false

  resources do
    resource(AshA2A.V3.Converse)
  end

  transport do
    user_artifacts(true)
  end
end

defmodule AshA2A.V3.GenerationAshTest do
  use ExUnit.Case, async: false

  alias AshA2A.Protocol.{Artifact, Message, Part, Task}
  alias AshA2A.Transport.{Principal, Runtime}

  @auth %{"a2a.auth" => %{"identity" => %{"sub" => "v3-alice"}}}
  @principal Principal.from_metadata(@auth)

  defp start(agent_module) do
    name = :"v3_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: name,
      start: {agent_module, :start_link, [[name: name]]}
    })

    name
  end

  defp data_message(data), do: Message.new_user([Part.Data.new(data)])

  defp send_msg(mod, agent, message, opts \\ []),
    do: mod.call(agent, message, Keyword.put_new(opts, :metadata, @auth))

  defp get(agent, task_id, opts \\ []),
    do: GenServer.call(agent, {:ash_a2a_get_task, @principal, task_id, opts})

  # Parks a task `:input_required`, then completes it: a 2-turn run.
  defp parked(mod, agent) do
    {:ok, %Task{status: %{state: :input_required}} = task} =
      send_msg(mod, agent, data_message(%{}))

    task
  end

  defp user_artifact(id, extra \\ []) do
    struct!(
      %Artifact{artifact_id: id, parts: [Part.Data.new(%{from: id})]},
      extra
    )
  end

  defp timeline_gens(task), do: Enum.map(task.timeline, & &1.generation)
  defp timeline_kinds(task), do: Enum.map(task.timeline, fn %{entry: {kind, _}} -> kind end)

  describe "generation across a multi-turn run" do
    test "every mutation bumps generation by exactly 1; timeline and history populated" do
      agent = start(AshA2A.V3.PlainAgent)
      task = parked(AshA2A.V3.PlainAgent, agent)

      # new: 1 -> message 2 -> working 3 -> input_required 4
      assert task.generation == 4
      assert timeline_gens(task) == [2, 3, 4]
      assert timeline_kinds(task) == [:message, :status, :status]
      assert [%Message{role: :user} | _] = task.history

      {:ok, done} =
        send_msg(AshA2A.V3.PlainAgent, agent, data_message(%{text: "hi"}), task_id: task.id)

      # message 5 -> working 6 -> artifact 7 -> completed 8
      assert done.status.state == :completed
      assert done.generation == 8
      assert timeline_gens(done) == [2, 3, 4, 5, 6, 8]
      assert timeline_kinds(done) == [:message, :status, :status, :message, :status, :status]

      # Monotonic, not contiguous: the artifact mutation (7) is a gap.
      assert timeline_gens(done) == Enum.sort(timeline_gens(done))
      refute 7 in timeline_gens(done)

      assert [%Artifact{start_generation: 7, end_generation: 7}] = done.artifacts
      assert length(done.history) >= 3

      # Round-trips through the stored task.
      assert {:ok, stored} = get(agent, task.id)
      assert stored.generation == 8
      assert timeline_gens(stored) == timeline_gens(done)
    end
  end

  describe "ifGenerationMatch" do
    test "mismatch on an existing task is refused and leaves the task untouched" do
      agent = start(AshA2A.V3.PlainAgent)
      task = parked(AshA2A.V3.PlainAgent, agent)

      assert {:error, :generation_mismatch} =
               send_msg(AshA2A.V3.PlainAgent, agent, data_message(%{text: "x"}),
                 task_id: task.id,
                 if_generation_match: task.generation + 1
               )

      assert {:ok, %Task{generation: 4, status: %{state: :input_required}}} = get(agent, task.id)
    end

    test "match proceeds; ignored for a new task" do
      agent = start(AshA2A.V3.PlainAgent)
      task = parked(AshA2A.V3.PlainAgent, agent)

      assert {:ok, %Task{status: %{state: :completed}}} =
               send_msg(AshA2A.V3.PlainAgent, agent, data_message(%{text: "x"}),
                 task_id: task.id,
                 if_generation_match: task.generation
               )

      assert {:ok, %Task{}} =
               send_msg(AshA2A.V3.PlainAgent, agent, data_message(%{}), if_generation_match: 999)
    end
  end

  describe "artifactUpdates (user_artifacts capability)" do
    test "refused when the card does not declare user_artifacts" do
      agent = start(AshA2A.V3.PlainAgent)
      task = parked(AshA2A.V3.PlainAgent, agent)

      assert {:error, {:unsupported_operation, :user_artifacts}} =
               send_msg(AshA2A.V3.PlainAgent, agent, data_message(%{text: "x"}),
                 task_id: task.id,
                 artifact_updates: [{user_artifact("u1"), false, nil}]
               )

      # Refused before any mutation.
      assert {:ok, %Task{generation: 4, artifacts: []}} = get(agent, task.id)

      # ... and before a new task is created.
      assert {:error, {:unsupported_operation, :user_artifacts}} =
               send_msg(AshA2A.V3.PlainAgent, agent, data_message(%{}),
                 artifact_updates: [{user_artifact("u2"), false, nil}]
               )

      assert {:ok, %{tasks: [only]}} =
               GenServer.call(agent, {:ash_a2a_list_tasks, @principal, %{}})

      assert only.id == task.id
    end

    test "applied in order after the message, role :user, client generation ignored" do
      agent = start(AshA2A.V3.UserArtifactsAgent)
      task = parked(AshA2A.V3.UserArtifactsAgent, agent)

      updates = [
        {user_artifact("u1", start_generation: 999, end_generation: 999), false, nil},
        {user_artifact("u2"), false, nil}
      ]

      assert {:ok, done} =
               send_msg(AshA2A.V3.UserArtifactsAgent, agent, data_message(%{text: "x"}),
                 task_id: task.id,
                 artifact_updates: updates
               )

      # message 5 -> u1 6 -> u2 7 -> working 8 -> agent artifact 9 -> completed 10
      assert done.generation == 10
      assert [u1, u2, agent_artifact] = done.artifacts
      assert {u1.artifact_id, u2.artifact_id} == {"u1", "u2"}
      assert u1.role == :user and u2.role == :user
      assert {u1.start_generation, u2.start_generation} == {6, 7}
      assert u1.end_generation == 6
      assert agent_artifact.start_generation == 9
      assert timeline_gens(done) == [2, 3, 4, 5, 8, 10]
    end

    test "domain DSL `transport do user_artifacts true` sets the card capability" do
      assert AshA2A.Domain.Info.transport(AshA2A.V3.UserArtifactsDomain).user_artifacts == true
      card = AshA2A.Info.agent_card(AshA2A.V3.UserArtifactsDomain)
      assert AshA2A.Protocol.ClientArtifacts.user_artifacts?(card)

      refute AshA2A.Protocol.ClientArtifacts.user_artifacts?(
               AshA2A.Info.agent_card(AshA2A.V3.Converse)
             )
    end
  end

  describe "timelineLength" do
    test "get and list truncate to the last N entries" do
      agent = start(AshA2A.V3.PlainAgent)
      task = parked(AshA2A.V3.PlainAgent, agent)
      assert length(task.timeline) == 3

      assert {:ok, two} = get(agent, task.id, timeline_length: 2)
      assert timeline_gens(two) == [3, 4]
      assert {:ok, none} = get(agent, task.id, timeline_length: 0)
      assert none.timeline == []
      assert {:ok, all} = get(agent, task.id)
      assert length(all.timeline) == 3

      assert {:ok, %{tasks: [listed]}} =
               GenServer.call(
                 agent,
                 {:ash_a2a_list_tasks, @principal, %{"timelineLength" => 1}}
               )

      assert timeline_gens(listed) == [4]
    end
  end

  describe "currentGeneration long-poll" do
    test "returns immediately when the task generation is already greater" do
      agent = start(AshA2A.V3.PlainAgent)
      task = parked(AshA2A.V3.PlainAgent, agent)

      assert {:ok, %Task{generation: 4}} = get(agent, task.id, current_generation: 3)
      assert {:ok, %Task{generation: 4}} = get(agent, task.id, current_generation: nil)
    end

    test "parks at the current generation, then wakes when the generation advances" do
      agent = start(AshA2A.V3.PlainAgent)
      task = parked(AshA2A.V3.PlainAgent, agent)

      poll = Elixir.Task.async(fn -> get(agent, task.id, current_generation: task.generation) end)
      await_waiters(agent, 1)
      refute Elixir.Task.yield(poll, 0)

      assert {:ok, _} =
               send_msg(AshA2A.V3.PlainAgent, agent, data_message(%{text: "go"}),
                 task_id: task.id
               )

      assert {:ok, %Task{generation: gen}} = Elixir.Task.await(poll, 5_000)
      assert gen > task.generation
      await_waiters(agent, 0)
    end

    test "answers the current task at the deadline when nothing advances" do
      agent = start(AshA2A.V3.PlainAgent)
      task = parked(AshA2A.V3.PlainAgent, agent)

      assert {:ok, %Task{generation: 4}} =
               get(agent, task.id, current_generation: 4, long_poll_timeout_ms: 20)

      await_waiters(agent, 0)
    end

    test "a foreign principal never parks: unknown-task answer" do
      agent = start(AshA2A.V3.PlainAgent)
      task = parked(AshA2A.V3.PlainAgent, agent)

      assert {:error, :not_found} =
               GenServer.call(
                 agent,
                 {:ash_a2a_get_task, "sub:mallory", task.id, [current_generation: 4]}
               )
    end
  end

  describe "stamped events" do
    test "status, artifact and message_update events carry the post-mutation generation" do
      agent = start(AshA2A.V3.PlainAgent)
      task = parked(AshA2A.V3.PlainAgent, agent)

      {:ok, done} =
        send_msg(AshA2A.V3.PlainAgent, agent, data_message(%{text: "x"}), task_id: task.id)

      assert %{generation: 8, final: true} = Runtime.status_event(done)
      [artifact] = done.artifacts
      assert %{generation: 7} = Runtime.artifact_event(done, artifact)

      msg = Message.new_user([Part.Data.new(%{})])
      assert %{generation: 8} = Runtime.message_update_event(done, msg)
    end
  end

  # Bounded poll on the real observable (the agent's parked-waiter table),
  # deadline-checked. POLL-STEP: the single receive-after below is the only
  # wait and lives inside this audited poll.
  defp await_waiters(agent, expected, deadline_ms \\ 5_000) do
    pid = Process.whereis(agent)
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_await_waiters(pid, expected, deadline)
  end

  defp do_await_waiters(pid, expected, deadline) do
    {:dictionary, dict} = Process.info(pid, :dictionary)

    count =
      case List.keyfind(dict, :ash_a2a_long_poll_waiters, 0) do
        {_, waiters} -> map_size(waiters)
        nil -> 0
      end

    cond do
      count == expected ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("expected #{expected} parked waiters, have #{count}")

      true ->
        receive do
        after
          1 -> do_await_waiters(pid, expected, deadline)
        end
    end
  end
end
