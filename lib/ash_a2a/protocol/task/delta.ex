# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Protocol.Task.Delta do
  @moduledoc """
  The stream events that take a subscriber from one stored task to the next.

  A2A v1.1 (specification 3.2.7): every mutation of a task is exactly one
  event, and the event carries the task's generation after that mutation.
  `events/2` derives those events from two snapshots of the same task, so the
  event journal and every binding's subscribe stream emit the same sequence:

    * a timeline entry newer than `previous` is a `MessageUpdate` (client
      message) or a `StatusUpdate` at the entry's generation;
    * an artifact that is new, or has more parts than in `previous`, is an
      `ArtifactUpdate` carrying only the new parts (`append: true` when the
      artifact already existed, `last_chunk: true` once it is completed).
      Artifact writes have no timeline entry; each takes a generation between
      the two snapshots that no timeline entry holds.

  The result is `[{generation, event}]`, oldest first, every generation
  greater than `previous`'s and at most `task`'s. With `previous` `nil` the
  task is treated as new (every mutation since generation 0).

  When several chunks of one artifact were written between the two snapshots
  they are reported as one event at the last of those generations.
  """

  alias AshA2A.Protocol.Event.{ArtifactUpdate, MessageUpdate, StatusUpdate}
  alias AshA2A.Protocol.Task.Generation
  alias AshA2A.Protocol.{Artifact, Task, TimelineEntry}

  @type event :: StatusUpdate.t() | ArtifactUpdate.t() | MessageUpdate.t()

  @doc "The events between `previous` (or `nil`) and `task`. See the module doc."
  @spec events(Task.t() | nil, Task.t()) :: [{pos_integer(), struct()}]
  def events(previous, %Task{} = task) do
    from = if previous, do: Generation.generation_of(previous), else: 0
    to = Generation.generation_of(task)

    if to > from do
      timeline = timeline_events(task, from, to)
      taken = MapSet.new(timeline, &elem(&1, 0))
      free = Enum.reject((from + 1)..to//1, &MapSet.member?(taken, &1))

      Enum.sort_by(timeline ++ artifact_events(previous, task, free), &elem(&1, 0))
    else
      []
    end
  end

  @doc "`events/2` after generation `after_generation`, when no earlier snapshot is held."
  @spec events_after(Task.t(), non_neg_integer()) :: [{pos_integer(), struct()}]
  def events_after(%Task{} = task, after_generation) when is_integer(after_generation) do
    for {gen, _event} = pair <- events(nil, task), gen > after_generation, do: pair
  end

  defp timeline_events(task, from, to) do
    for %TimelineEntry{entry: entry, generation: gen} <- List.wrap(task.timeline),
        is_integer(gen) and gen > from and gen <= to,
        event = timeline_event(task, entry, gen),
        do: {gen, event}
  end

  defp timeline_event(task, {:message, message}, gen),
    do: MessageUpdate.new(task.id, message, context_id: task.context_id, generation: gen)

  defp timeline_event(task, {:status, status}, gen) do
    StatusUpdate.new(task.id, status,
      context_id: task.context_id,
      final: Task.terminal?(%{task | status: status}),
      generation: gen
    )
  end

  defp timeline_event(_task, _other, _gen), do: nil

  # Each changed artifact takes one free generation: the one stamped on it
  # (`end_generation`, else `start_generation` for a new artifact) when that
  # is free, otherwise the next free one in artifact order.
  defp artifact_events(previous, task, free) do
    prior = if previous, do: Map.new(previous.artifacts, &{&1.artifact_id, &1}), else: %{}

    {events, _free} =
      task.artifacts
      |> Enum.flat_map(&changed(&1, Map.get(prior, &1.artifact_id)))
      |> Enum.reduce({[], free}, fn {artifact, parts, append?}, {acc, free} ->
        case pick(artifact, append?, free) do
          nil ->
            {acc, free}

          gen ->
            event =
              ArtifactUpdate.new(task.id, %{artifact | parts: parts},
                context_id: task.context_id,
                append: if(append?, do: true),
                last_chunk: if(is_integer(artifact.end_generation), do: true),
                generation: gen
              )

            {[{gen, event} | acc], List.delete(free, gen)}
        end
      end)

    events
  end

  defp changed(%Artifact{} = artifact, nil), do: [{artifact, artifact.parts, false}]

  defp changed(%Artifact{} = artifact, %Artifact{} = prior) do
    case Enum.drop(artifact.parts, length(prior.parts)) do
      [] -> []
      parts -> [{artifact, parts, true}]
    end
  end

  defp pick(_artifact, _append?, []), do: nil

  defp pick(artifact, append?, free) do
    stamped = if append?, do: artifact.end_generation, else: artifact.start_generation

    cond do
      is_integer(artifact.end_generation) and artifact.end_generation in free ->
        artifact.end_generation

      is_integer(stamped) and stamped in free ->
        stamped

      append? ->
        List.last(free)

      true ->
        hd(free)
    end
  end
end
