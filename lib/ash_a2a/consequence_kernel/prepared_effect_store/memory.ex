# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.PreparedEffectStore.Memory do
  use Agent
  @behaviour AshA2A.ConsequenceKernel.PreparedEffectStore

  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  def start_link(opts \\ []),
    do: Agent.start_link(fn -> %{records: %{}, requests: %{}, effects: %{}} end, opts)

  def put(pid, %{digest: digest} = record) do
    Agent.get_and_update(pid, fn state ->
      if Map.has_key?(state.records, digest),
        do: {{:error, :prepared_duplicate}, state},
        else: {:ok, put_in(state, [:records, digest], Map.put(record, :outcome, nil))}
    end)
  end

  def fetch(pid, digest) do
    Agent.get(pid, fn state ->
      case Map.fetch(state.records, digest) do
        {:ok, record} -> {:ok, record}
        :error -> :not_found
      end
    end)
  end

  def transition(pid, digest, from, to) do
    Agent.get_and_update(pid, fn state ->
      with {:ok, record} <- Map.fetch(state.records, digest),
           true <- record.state == from,
           :ok <- Transition.admit(from, to) do
        {:ok, put_in(state, [:records, digest, :state], to)}
      else
        _ -> {{:error, :prepared_transition_refused}, state}
      end
    end)
  end

  def claim_request(pid, id, owner), do: claim(pid, :requests, id, owner)
  def claim_effect(pid, id, owner), do: claim(pid, :effects, id, owner)

  def complete(pid, digest, outcome) do
    Agent.get_and_update(pid, fn state ->
      case Map.fetch(state.records, digest) do
        {:ok, %{state: :completed}} ->
          {:ok, put_in(state, [:records, digest, :outcome], outcome)}

        {:ok, _record} ->
          {{:error, :prepared_not_completed}, state}

        :error ->
          {{:error, :prepared_record_missing}, state}
      end
    end)
  end

  defp claim(pid, key, id, owner) do
    Agent.get_and_update(pid, fn state ->
      case get_in(state, [key, id]) do
        nil -> {:ok, put_in(state, [key, id], owner)}
        ^owner -> {:ok, state}
        _ -> {{:error, :claim_conflict}, state}
      end
    end)
  end
end
