# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W5.EffectClaimStore.Memory do
  use Agent
  @behaviour AshA2A.ConsequenceKernel.W5.EffectClaimStore
  alias AshA2A.ConsequenceKernel.W5.{ClaimTransition, EffectClaim}

  def start_link(opts \\ []),
    do: Agent.start_link(fn -> %{claims: %{}, effects: %{}, receipts: %{}} end, opts)

  def put(pid, %EffectClaim{} = c),
    do:
      Agent.get_and_update(pid, fn s ->
        cond do
          Map.has_key?(s.claims, c.claim_id) ->
            {{:error, :effect_claim_duplicate}, s}

          Map.has_key?(s.effects, c.effect_id) ->
            {{:error, :effect_already_claimed}, s}

          true ->
            n =
              s
              |> put_in([:claims, c.claim_id], c)
              |> put_in([:effects, c.effect_id], c.claim_id)
              |> put_in([:receipts, c.claim_id], [])

            {:ok, n}
        end
      end)

  def fetch(pid, id),
    do:
      Agent.get(pid, fn s ->
        case Map.fetch(s.claims, id) do
          {:ok, c} -> {:ok, c}
          :error -> :not_found
        end
      end)

  def fetch_effect(pid, id),
    do:
      Agent.get(pid, fn s ->
        with {:ok, cid} <- Map.fetch(s.effects, id),
             {:ok, c} <- Map.fetch(s.claims, cid),
             do: {:ok, c},
             else: (_ -> :not_found)
      end)

  def transition(pid, id, from, to),
    do:
      Agent.get_and_update(pid, fn s ->
        with {:ok, c} <- Map.fetch(s.claims, id),
             true <- c.state == from,
             :ok <- ClaimTransition.admit(from, to) do
          {:ok, put_in(s, [:claims, id], %{c | state: to})}
        else
          _ -> {{:error, :effect_claim_transition_refused}, s}
        end
      end)

  def append_receipt(pid, id, r) when is_map(r),
    do:
      Agent.get_and_update(pid, fn s ->
        if Map.has_key?(s.claims, id),
          do: {:ok, put_in(s, [:receipts, id], Map.get(s.receipts, id, []) ++ [r])},
          else: {{:error, :effect_claim_not_found}, s}
      end)

  def receipts(pid, id),
    do:
      Agent.get(pid, fn s ->
        if Map.has_key?(s.claims, id), do: {:ok, Map.get(s.receipts, id, [])}, else: :not_found
      end)
end
