defmodule AshA2A.Protocol.Task do
  @moduledoc """
  A unit of work managed by an agent runtime.

  Tasks track lifecycle state, message history, and produced artifacts.
  """

  @type state :: AshA2A.Protocol.Task.Status.state()

  @type t :: %__MODULE__{
          id: String.t(),
          context_id: String.t() | nil,
          status: AshA2A.Protocol.Task.Status.t(),
          history: [AshA2A.Protocol.Message.t()],
          artifacts: [AshA2A.Protocol.Artifact.t()],
          metadata: map()
        }

  @enforce_keys [:id, :status]
  defstruct [
    :id,
    :context_id,
    :status,
    history: [],
    artifacts: [],
    metadata: %{}
  ]

  # `:rejected` is terminal per v1.0 (refused at admission, never resumable);
  # `:input_required`/`:auth_required` are intentionally absent (resumable).
  @terminal_states [:completed, :canceled, :failed, :rejected]

  @doc """
  Returns `true` if the task is in a terminal state.
  """
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: %AshA2A.Protocol.Task.Status{state: state}}) do
    state in @terminal_states
  end

  @doc """
  Truncates the task history to the last `n` entries.

  Returns the task unchanged when `n` is `nil`. A value of `0` clears
  the history entirely.
  """
  @spec truncate_history(t(), non_neg_integer() | nil) :: t()
  def truncate_history(task, nil), do: task
  def truncate_history(task, 0), do: %{task | history: []}

  def truncate_history(task, n) when is_integer(n) and n > 0 do
    %{task | history: Enum.take(task.history, -n)}
  end

  def truncate_history(task, _), do: task

  @doc """
  Strips the internal `:stream` key from task metadata.

  The `:stream` key holds a raw enumerable/function ref used by the SSE
  path and must be removed before JSON encoding.
  """
  @spec strip_stream_metadata(t()) :: t()
  def strip_stream_metadata(%{metadata: metadata} = task) do
    %{task | metadata: Map.delete(metadata, :stream)}
  end

  def strip_stream_metadata(task), do: task

  @doc """
  Creates a new task in the `:submitted` state.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      id: Keyword.get_lazy(opts, :id, fn -> AshA2A.Protocol.ID.generate("tsk") end),
      context_id: Keyword.get(opts, :context_id),
      status: AshA2A.Protocol.Task.Status.new(:submitted),
      history: Keyword.get(opts, :history, []),
      artifacts: Keyword.get(opts, :artifacts, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end
