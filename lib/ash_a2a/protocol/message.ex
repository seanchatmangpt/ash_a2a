defmodule AshA2A.Protocol.Message do
  @moduledoc """
  A single turn of communication between user and agent.

  Messages contain typed parts and are identified by role (`:user` or `:agent`).
  """

  @type role :: :user | :agent

  @type t :: %__MODULE__{
          message_id: String.t(),
          role: role(),
          parts: [AshA2A.Protocol.Part.t()],
          task_id: String.t() | nil,
          context_id: String.t() | nil,
          reference_task_ids: [String.t()],
          metadata: map(),
          extensions: map()
        }

  @enforce_keys [:role, :parts]
  defstruct [
    :message_id,
    :role,
    :task_id,
    :context_id,
    parts: [],
    reference_task_ids: [],
    metadata: %{},
    extensions: %{}
  ]

  @doc """
  Creates a new user message from text or parts.
  """
  @spec new_user(String.t() | [AshA2A.Protocol.Part.t()]) :: t()
  def new_user(text) when is_binary(text) do
    new_user([AshA2A.Protocol.Part.Text.new(text)])
  end

  def new_user(parts) when is_list(parts) do
    %__MODULE__{
      message_id: AshA2A.Protocol.ID.generate("msg"),
      role: :user,
      parts: parts
    }
  end

  @doc """
  Creates a new agent message from text or parts.
  """
  @spec new_agent(String.t() | [AshA2A.Protocol.Part.t()]) :: t()
  def new_agent(text) when is_binary(text) do
    new_agent([AshA2A.Protocol.Part.Text.new(text)])
  end

  def new_agent(parts) when is_list(parts) do
    %__MODULE__{
      message_id: AshA2A.Protocol.ID.generate("msg"),
      role: :agent,
      parts: parts
    }
  end

  @doc """
  Extracts the text from the first `AshA2A.Protocol.Part.Text` part, or `nil` if none.
  """
  @spec text(t()) :: String.t() | nil
  def text(%__MODULE__{parts: parts}) do
    Enum.find_value(parts, fn
      %AshA2A.Protocol.Part.Text{text: text} -> text
      _ -> nil
    end)
  end
end
