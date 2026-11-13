defmodule AshA2A.Protocol.Artifact do
  @moduledoc """
  An output produced by an agent in response to a task.

  Artifacts contain typed parts representing the result of agent work.
  """

  @type t :: %__MODULE__{
          artifact_id: String.t(),
          name: String.t() | nil,
          description: String.t() | nil,
          parts: [AshA2A.Protocol.Part.t()],
          extensions: [String.t()],
          metadata: map(),
          start_generation: non_neg_integer() | nil,
          end_generation: non_neg_integer() | nil,
          role: :user | :agent | nil
        }

  # v1.1: `role` nil means agent-originated; `:user` marks client-written.
  @enforce_keys [:parts]
  defstruct [
    :artifact_id,
    :name,
    :description,
    :start_generation,
    :end_generation,
    :role,
    parts: [],
    extensions: [],
    metadata: %{}
  ]

  @doc """
  Creates a new artifact from parts.
  """
  @spec new([AshA2A.Protocol.Part.t()], keyword()) :: t()
  def new(parts, opts \\ []) do
    %__MODULE__{
      artifact_id: AshA2A.Protocol.ID.generate("art"),
      parts: parts,
      name: Keyword.get(opts, :name),
      description: Keyword.get(opts, :description),
      extensions: Keyword.get(opts, :extensions, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end
