# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.TaskLifecycle do
  @moduledoc """
  Adapter over host-owned AshStateMachine task truth.

  The canonical A2A vocabulary is declared here for interoperability, but
  transition legality comes from `AshStateMachine.possible_next_states/1,2`
  when that extension is installed. This module never performs a transition.

  Producer map (v1.0 semantics):

  * `:rejected` — refused at admission, before any handler effect: an
    authority-gate denial or capability-resolution refusal. Produced by
    `AshA2A.Protocol.Agent.Runtime.handle_reply/2`'s `admission_refusal?/1`
    classifier (`lib/ash_a2a/protocol/agent/runtime.ex`). Terminal —
    `AshA2A.Protocol.Task.terminal?/1` includes it; never resumable.
  * `:auth_required` — refused for missing credentials; parked resumable
    (`auth_failure?/1`, same classifier family).
  * `:failed` — attempted-and-errored: the handler ran and failed mid-run.
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

  @doc """
  The canonical A2A task lifecycle states (v1.0 producer vocabulary).

      iex> AshA2A.TaskLifecycle.states()
      [:submitted, :working, :input_required, :auth_required, :completed, :failed,
       :canceled, :rejected]
  """
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
  def admit(record, desired_state, action)

  def admit(record, desired_state, action) when desired_state in @states do
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
