defmodule AshA2A.Protocol.Task.Status do
  @moduledoc """
  The current status of a task, including state, optional message, and timestamp.
  """

  @type state ::
          :submitted
          | :working
          | :input_required
          | :completed
          | :canceled
          | :failed
          | :rejected
          | :auth_required
          | :unknown

  @type t :: %__MODULE__{
          state: state(),
          message: AshA2A.Protocol.Message.t() | nil,
          timestamp: DateTime.t()
        }

  @enforce_keys [:state, :timestamp]
  defstruct [:state, :message, :timestamp]

  @doc """
  Creates a new status with the given state and current timestamp.
  """
  @spec new(state(), AshA2A.Protocol.Message.t() | nil) :: t()
  def new(state, message \\ nil) do
    %__MODULE__{
      state: state,
      message: message,
      timestamp: DateTime.utc_now()
    }
  end

  @interrupted_states [:input_required, :auth_required]

  @doc """
  Whether a state (or a status / task carrying one) is *interrupted*: parked
  and resumable by a follow-up message (`:input_required`, `:auth_required`).
  Sibling of `AshA2A.Protocol.Task.terminal?/1`; the two sets are disjoint.
  """
  @spec interrupted?(state() | t() | AshA2A.Protocol.Task.t()) :: boolean()
  def interrupted?(%__MODULE__{state: state}), do: interrupted?(state)
  def interrupted?(%AshA2A.Protocol.Task{status: status}), do: interrupted?(status)
  def interrupted?(state) when is_atom(state), do: state in @interrupted_states
  def interrupted?(_), do: false
end
