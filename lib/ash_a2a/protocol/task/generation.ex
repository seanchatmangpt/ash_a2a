defmodule AshA2A.Protocol.Task.Generation do
  @moduledoc """
  Pure A2A v1.1 task generation and timeline semantics (spec 3.2.7 / 3.2.8).

  `Task.generation` starts at `1` and is incremented by exactly `1` on every
  state-changing mutation: a status append, a client message append, or an
  artifact add/update. Each timeline entry is stamped with the generation
  *after* its mutation, so entry generations are monotonic but not contiguous
  (artifact mutations leave gaps).

  The deprecated `history` field is kept in sync for 1.0 clients.
  """

  alias AshA2A.Protocol.{Artifact, Message, TimelineEntry}
  alias AshA2A.Protocol.Task, as: T
  alias AshA2A.Protocol.Task.Status

  @doc "The generation of a freshly created task."
  @spec initial() :: pos_integer()
  def initial, do: 1

  @doc "The task's current generation."
  @spec generation_of(T.t()) :: non_neg_integer()
  def generation_of(%{generation: gen}) when is_integer(gen), do: gen
  def generation_of(_task), do: initial()

  @doc """
  Records an agent status: bumps generation by 1, sets `task.status`, appends a
  `{:status, status}` timeline entry stamped with the new generation, and
  mirrors `status.message` (when present) into the legacy `history`.
  """
  @spec append_status(T.t(), Status.t()) :: T.t()
  def append_status(task, %Status{} = status) do
    gen = generation_of(task) + 1

    %{
      task
      | status: status,
        generation: gen,
        timeline: timeline_of(task) ++ [entry({:status, status}, gen)],
        history: sync_history(task.history, status.message)
    }
  end

  @doc """
  Records a client message: bumps generation by 1, appends a `{:message, m}`
  timeline entry and appends the message to the legacy `history`.
  """
  @spec append_message(T.t(), Message.t()) :: T.t()
  def append_message(task, %Message{} = message) do
    gen = generation_of(task) + 1

    %{
      task
      | generation: gen,
        timeline: timeline_of(task) ++ [entry({:message, message}, gen)],
        history: sync_history(task.history, message)
    }
  end

  @doc """
  Records an artifact add/update: bumps generation by 1. `start_generation`
  is set the first time an artifact id is seen (preserved afterwards);
  `end_generation` is set when `completed?` is true. A chunk whose id is
  already present follows append semantics (parts concatenated). A new
  artifact without a role is a client-written artifact only if the caller set
  `role: :user`; this function never overwrites an explicit role.

  Returns `{task, artifact}` with the stored (stamped) artifact.
  """
  @spec record_artifact(T.t(), Artifact.t(), boolean()) :: {T.t(), Artifact.t()}
  def record_artifact(task, %Artifact{} = artifact, completed?) do
    gen = generation_of(task) + 1
    existing = Enum.find(task.artifacts, &(&1.artifact_id == artifact.artifact_id))

    stored =
      case existing do
        nil ->
          %{artifact | start_generation: gen, end_generation: end_gen(nil, gen, completed?)}

        prior ->
          %{
            prior
            | parts: prior.parts ++ artifact.parts,
              metadata: Map.merge(prior.metadata || %{}, artifact.metadata || %{}),
              start_generation: prior.start_generation || gen,
              end_generation: end_gen(prior.end_generation, gen, completed?)
          }
      end

    artifacts =
      case existing do
        nil ->
          task.artifacts ++ [stored]

        _ ->
          Enum.map(
            task.artifacts,
            &if(&1.artifact_id == stored.artifact_id, do: stored, else: &1)
          )
      end

    {%{task | generation: gen, artifacts: artifacts}, stored}
  end

  @doc "True when `expected` is nil or equals the task's generation."
  @spec matches?(T.t(), integer() | nil) :: boolean()
  def matches?(_task, nil), do: true
  def matches?(task, expected) when is_integer(expected), do: generation_of(task) == expected

  @doc """
  Truncates the timeline to the last `n` entries (nil keeps all, 0 none).
  """
  @spec truncate_timeline(T.t(), non_neg_integer() | nil) :: T.t()
  def truncate_timeline(task, nil), do: task
  def truncate_timeline(task, 0), do: %{task | timeline: []}

  def truncate_timeline(task, n) when is_integer(n) and n > 0 do
    %{task | timeline: Enum.take(timeline_of(task), -n)}
  end

  def truncate_timeline(task, _), do: task

  defp entry(entry, gen), do: %TimelineEntry{entry: entry, generation: gen}

  defp timeline_of(%{timeline: tl}) when is_list(tl), do: tl
  defp timeline_of(_), do: []

  defp end_gen(prior, _gen, false), do: prior
  defp end_gen(_prior, gen, true), do: gen

  defp sync_history(history, nil), do: history

  defp sync_history(history, %Message{message_id: id} = message) do
    case List.last(history) do
      %Message{message_id: ^id} when not is_nil(id) -> history
      _ -> history ++ [message]
    end
  end
end
