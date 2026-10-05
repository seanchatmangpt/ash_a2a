defmodule AshA2A.Protocol.Event do
  @moduledoc """
  Streaming events emitted during task execution.

  Three variants exist:

  - `AshA2A.Protocol.Event.StatusUpdate` — task status changed
  - `AshA2A.Protocol.Event.ArtifactUpdate` — artifact produced or appended
  - `AshA2A.Protocol.Message` — the agent answered out-of-band with a bare message, so
    the stream carries it alone and there is no task to update
  """

  @type t :: AshA2A.Protocol.Event.StatusUpdate.t() | AshA2A.Protocol.Event.ArtifactUpdate.t() | AshA2A.Protocol.Message.t()
end

defmodule AshA2A.Protocol.Event.StatusUpdate do
  @moduledoc """
  A streaming event indicating a task status change.

  Wire shape (v1.0): `{"statusUpdate": {"taskId": ..., "status": {...},
  "contextId"?}}` — the encoder emits no `kind` key and no `final` boolean.
  Finality is carried by a terminal status state (`completed`, `canceled`,
  `failed`, `rejected`, `input_required`, `auth_required`). The `final`
  field is internal only: it is never serialized, and on decode it is
  reconstructed from the status state or from a legacy v0.3 `"final": true`
  frame.
  """

  @type t :: %__MODULE__{
          task_id: String.t(),
          context_id: String.t() | nil,
          status: AshA2A.Protocol.Task.Status.t(),
          final: boolean(),
          metadata: map()
        }

  @enforce_keys [:task_id, :status, :final]
  defstruct [
    :task_id,
    :context_id,
    :status,
    final: false,
    metadata: %{}
  ]

  @doc """
  Creates a new status update event.
  """
  @spec new(String.t(), AshA2A.Protocol.Task.Status.t(), keyword()) :: t()
  def new(task_id, status, opts \\ []) do
    %__MODULE__{
      task_id: task_id,
      context_id: Keyword.get(opts, :context_id),
      status: status,
      final: Keyword.get(opts, :final, false),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end

defmodule AshA2A.Protocol.Event.ArtifactUpdate do
  @moduledoc """
  A streaming event indicating an artifact was produced or appended.
  """

  @type t :: %__MODULE__{
          task_id: String.t(),
          context_id: String.t() | nil,
          artifact: AshA2A.Protocol.Artifact.t(),
          append: boolean() | nil,
          last_chunk: boolean() | nil,
          metadata: map()
        }

  @enforce_keys [:task_id, :artifact]
  defstruct [
    :task_id,
    :context_id,
    :artifact,
    :append,
    :last_chunk,
    metadata: %{}
  ]

  @doc """
  Creates a new artifact update event.
  """
  @spec new(String.t(), AshA2A.Protocol.Artifact.t(), keyword()) :: t()
  def new(task_id, artifact, opts \\ []) do
    %__MODULE__{
      task_id: task_id,
      context_id: Keyword.get(opts, :context_id),
      artifact: artifact,
      append: Keyword.get(opts, :append),
      last_chunk: Keyword.get(opts, :last_chunk),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end
