defmodule AshA2A.Protocol.TaskUpdater do
  @moduledoc """
  Author-facing helper for non-Ash `AshA2A.Protocol.Agent` handlers
  (a2a-python `TaskUpdater` parity).

  The updater is an immutable struct tracking the task's current state. Each
  function returns `{:ok, updater, event}` where `event` is an
  `AshA2A.Protocol.Event.StatusUpdate` or `AshA2A.Protocol.Event.ArtifactUpdate`,
  or `{:error, {:terminal_state, state}}` when the task is already terminal
  (legality from `AshA2A.TaskLifecycle.check_transition/2`).
  """

  alias AshA2A.Protocol.{Artifact, Event, Message, Part}
  alias AshA2A.Protocol.Task.Status

  @type t :: %__MODULE__{
          task_id: String.t(),
          context_id: String.t() | nil,
          state: atom() | nil
        }

  @enforce_keys [:task_id]
  defstruct [:task_id, :context_id, :state]

  @doc "Creates an updater for `task_id`. Options: `:context_id`, `:state` (current state)."
  @spec new(String.t(), keyword()) :: t()
  def new(task_id, opts \\ []) do
    %__MODULE__{
      task_id: task_id,
      context_id: Keyword.get(opts, :context_id),
      state: Keyword.get(opts, :state)
    }
  end

  @spec submit(t(), term()) :: {:ok, t(), Event.StatusUpdate.t()} | {:error, term()}
  def submit(u, message \\ nil), do: transition(u, :submitted, message)

  @spec start_work(t(), term()) :: {:ok, t(), Event.StatusUpdate.t()} | {:error, term()}
  def start_work(u, message \\ nil), do: transition(u, :working, message)

  @spec complete(t(), term()) :: {:ok, t(), Event.StatusUpdate.t()} | {:error, term()}
  def complete(u, message \\ nil), do: transition(u, :completed, message)

  @spec fail(t(), term()) :: {:ok, t(), Event.StatusUpdate.t()} | {:error, term()}
  def fail(u, message \\ nil), do: transition(u, :failed, message)

  @spec cancel(t(), term()) :: {:ok, t(), Event.StatusUpdate.t()} | {:error, term()}
  def cancel(u, message \\ nil), do: transition(u, :canceled, message)

  @spec requires_input(t(), term()) :: {:ok, t(), Event.StatusUpdate.t()} | {:error, term()}
  def requires_input(u, message \\ nil), do: transition(u, :input_required, message)

  @spec requires_auth(t(), term()) :: {:ok, t(), Event.StatusUpdate.t()} | {:error, term()}
  def requires_auth(u, message \\ nil), do: transition(u, :auth_required, message)

  @doc """
  Builds an artifact update event from `parts` (or a text string).

  Options: `:artifact_id` (generated when absent), `:name`, `:description`,
  `:append` (default `false`), `:last_chunk` (default `false`), `:metadata`.
  Refused once the task is terminal.
  """
  @spec add_artifact(t(), [struct()] | String.t(), keyword()) ::
          {:ok, t(), Event.ArtifactUpdate.t()} | {:error, term()}
  def add_artifact(%__MODULE__{} = u, parts, opts \\ []) do
    with :ok <- ensure_open(u) do
      parts = if is_binary(parts), do: [Part.Text.new(parts)], else: parts

      artifact = Artifact.new(parts, Keyword.take(opts, [:name, :description, :metadata]))

      artifact =
        case Keyword.get(opts, :artifact_id) do
          nil -> artifact
          id -> %{artifact | artifact_id: id}
        end

      event =
        Event.ArtifactUpdate.new(u.task_id, artifact,
          context_id: u.context_id,
          append: Keyword.get(opts, :append, false),
          last_chunk: Keyword.get(opts, :last_chunk, false)
        )

      {:ok, u, event}
    end
  end

  defp transition(%__MODULE__{} = u, to, message) do
    with :ok <- AshA2A.TaskLifecycle.check_transition(u.state, to) do
      status = Status.new(to, normalize_message(message, u))

      event =
        Event.StatusUpdate.new(u.task_id, status,
          context_id: u.context_id,
          final: to in [:completed, :failed, :canceled, :rejected]
        )

      {:ok, %{u | state: to}, event}
    end
  end

  defp ensure_open(%__MODULE__{state: nil}), do: :ok

  defp ensure_open(%__MODULE__{state: state}) do
    if state in [:completed, :failed, :canceled, :rejected],
      do: {:error, {:terminal_state, state}},
      else: :ok
  end

  defp normalize_message(nil, _u), do: nil
  defp normalize_message(text, u) when is_binary(text), do: normalize_message(Message.new_agent(text), u)

  defp normalize_message(%Message{} = m, u),
    do: %{m | task_id: m.task_id || u.task_id, context_id: m.context_id || u.context_id}
end
