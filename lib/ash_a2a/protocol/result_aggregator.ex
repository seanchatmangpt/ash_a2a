defmodule AshA2A.Protocol.ResultAggregator do
  @moduledoc """
  Folds an enumerable of `AshA2A.Protocol.Event` values into a final
  `AshA2A.Protocol.Task` (a2a-python `ResultAggregator` parity). Pure.

  * `StatusUpdate` replaces the status; a status message is appended to history.
    Status updates after a terminal state are ignored.
  * `ArtifactUpdate` with `append` falsy replaces/adds the artifact by id;
    with `append: true` its parts are appended to the existing artifact
    (dropped if no such artifact exists). `last_chunk: true` records the id in
    `metadata[:finalized_artifacts]`.
  * A bare `Message` is appended to history.
  """

  alias AshA2A.Protocol.{Event, Message}
  alias AshA2A.Protocol.Task, as: PTask

  @doc """
  Folds `events` into a task. `initial` is a task or `nil` (a task is then
  created from the first event's task id).
  """
  @spec aggregate(Enumerable.t(), PTask.t() | nil) :: PTask.t() | nil
  def aggregate(events, initial \\ nil), do: Enum.reduce(events, initial, &apply_event/2)

  @spec apply_event(Event.t(), PTask.t() | nil) :: PTask.t() | nil
  def apply_event(%Message{}, nil), do: nil
  def apply_event(%Message{} = m, %PTask{} = t), do: %{t | history: t.history ++ [m]}

  def apply_event(%{task_id: id} = ev, nil) when is_binary(id) do
    apply_event(ev, PTask.new(id: id, context_id: Map.get(ev, :context_id)))
  end

  def apply_event(%Event.StatusUpdate{} = ev, %PTask{} = t) do
    if PTask.terminal?(t) do
      t
    else
      history = if ev.status.message, do: t.history ++ [ev.status.message], else: t.history
      %{t | status: ev.status, history: history, context_id: t.context_id || ev.context_id}
    end
  end

  def apply_event(%Event.ArtifactUpdate{} = ev, %PTask{} = t) do
    id = ev.artifact.artifact_id
    t = %{t | context_id: t.context_id || ev.context_id}

    artifacts =
      if ev.append == true do
        if Enum.any?(t.artifacts, &(&1.artifact_id == id)) do
          Enum.map(t.artifacts, fn
            %{artifact_id: ^id} = a -> %{a | parts: a.parts ++ ev.artifact.parts}
            a -> a
          end)
        else
          t.artifacts
        end
      else
        if Enum.any?(t.artifacts, &(&1.artifact_id == id)) do
          Enum.map(t.artifacts, fn
            %{artifact_id: ^id} -> ev.artifact
            a -> a
          end)
        else
          t.artifacts ++ [ev.artifact]
        end
      end

    t = %{t | artifacts: artifacts}

    if ev.last_chunk == true do
      done = Map.get(t.metadata, :finalized_artifacts, [])
      %{t | metadata: Map.put(t.metadata, :finalized_artifacts, Enum.uniq(done ++ [id]))}
    else
      t
    end
  end
end
