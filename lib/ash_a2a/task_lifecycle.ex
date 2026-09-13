defmodule AshA2A.TaskLifecycle do
  @moduledoc """
  Adapter over host-owned AshStateMachine task truth.

  The canonical A2A vocabulary is declared here for interoperability, but
  transition legality comes from `AshStateMachine.possible_next_states/1,2`
  when that extension is installed. This module never performs a transition.
  """

  @states [
    :submitted,
    :working,
    :input_required,
    :auth_required,
    :completed,
    :failed,
    :canceled,
    :rejected
  ]

  @spec states() :: [atom()]
  def states, do: @states

  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(AshStateMachine)

  @spec possible_next_states(struct(), atom() | nil) :: {:ok, [atom()]} | {:error, term()}
  def possible_next_states(record, action \\ nil) do
    cond do
      not available?() ->
        {:error, {:unsupported, :ash_state_machine}}

      is_nil(action) and function_exported?(AshStateMachine, :possible_next_states, 1) ->
        {:ok, apply(AshStateMachine, :possible_next_states, [record])}

      function_exported?(AshStateMachine, :possible_next_states, 2) ->
        {:ok, apply(AshStateMachine, :possible_next_states, [record, action])}

      true ->
        {:error, {:unsupported, :possible_next_states}}
    end
  end

  @spec admit(struct(), atom(), atom() | nil) :: :ok | {:error, term()}
  def admit(record, desired_state, action \\ nil) when desired_state in @states do
    with {:ok, possible} <- possible_next_states(record, action),
         true <- desired_state in possible do
      :ok
    else
      false -> {:error, {:transition_not_admitted, desired_state}}
      {:error, _} = error -> error
    end
  end

  def admit(_record, desired_state, _action), do: {:error, {:unknown_a2a_state, desired_state}}
end
