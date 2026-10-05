# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W5.ClaimProtocol do
  @moduledoc """
  W5 independent effect-claim protocol: claim (authenticated, subject-bound, fenced against the
  request claim) -> begin_do -> record_outcome, with `recover/2` for unknown outcomes. Every
  transition appends a chained claim receipt.
  """
  alias AshA2A.ConsequenceKernel.W5.{
    ClaimAuthenticator,
    ClaimFence,
    ClaimReceipt,
    ClaimSubject,
    IndependentClaim,
    Reconciliation
  }

  def claim(p, owner, opts) do
    with {:ok, m, s, k} <- config(opts),
         {:ok, c} <-
           ClaimAuthenticator.issue(
             %{
               request_id: p.instance.request_id,
               effect_id: p.instance.effect_id,
               prepared_digest: p.prepared_digest,
               subject_digest: p.instance.subject_digest,
               owner: owner
             },
             k
           ),
         :ok <- ClaimSubject.bind(p, c),
         :ok <- IndependentClaim.admit(p.instance.request_id, c.claim_id),
         :ok <-
           ClaimFence.admit(%{
             request_claim: p.instance.request_id,
             effect_claim: c.claim_id,
             prepared_digest: p.prepared_digest,
             claimed_prepared_digest: c.prepared_digest
           }),
         :ok <- m.put(s, c),
         :ok <- ClaimAuthenticator.verify(c, k),
         :ok <- append(m, s, c, :claimed),
         do: {:ok, %{claim_id: c.claim_id, store: m, server: s, key: k}}
  end

  def begin_do(ctx) do
    with {:ok, c} <- fetch_verified(ctx),
         :ok <- ctx.store.transition(ctx.server, c.claim_id, :claimed, :doing),
         {:ok, n} <- ctx.store.fetch(ctx.server, c.claim_id),
         do: append(ctx.store, ctx.server, n, :doing)
  end

  def record_outcome(ctx, o) do
    with {:ok, c} <- fetch_verified(ctx),
         {:ok, t} <- target(o),
         :ok <- ctx.store.transition(ctx.server, c.claim_id, :doing, t),
         {:ok, n} <- ctx.store.fetch(ctx.server, c.claim_id),
         do: append(ctx.store, ctx.server, n, t)
  end

  def recover(ctx, obs) do
    with {:ok, c} <- fetch_verified(ctx),
         true <- c.state == :unknown_outcome,
         t = rt(Reconciliation.resolve(obs, c.effect_id)),
         :ok <- ctx.store.transition(ctx.server, c.claim_id, :unknown_outcome, t),
         {:ok, n} <- ctx.store.fetch(ctx.server, c.claim_id),
         :ok <- append(ctx.store, ctx.server, n, t) do
      {:ok, t}
    else
      false -> {:error, :reconciliation_requires_unknown_outcome}
      {:error, _} = e -> e
      x -> {:error, {:reconciliation_refused, x}}
    end
  end

  def fetch_verified(%{store: m, server: s, key: k, claim_id: id}) do
    with {:ok, c} <- m.fetch(s, id),
         :ok <- ClaimAuthenticator.verify(c, k) do
      {:ok, c}
    else
      :not_found -> {:error, :effect_claim_not_found}
      {:error, _} = e -> e
    end
  end

  def receipts(%{store: m, server: s, claim_id: id}), do: m.receipts(s, id)

  defp config(opts) do
    with {:ok, m} <- Keyword.fetch(opts, :claim_store),
         {:ok, s} <- Keyword.fetch(opts, :claim_store_handle),
         {:ok, k} <- Keyword.fetch(opts, :claim_key),
         true <- Code.ensure_loaded?(m) and function_exported?(m, :put, 2),
         true <- function_exported?(m, :transition, 4),
         true <- is_binary(k) and byte_size(k) >= 16 do
      {:ok, m, s, k}
    else
      _ -> {:error, :independent_effect_claim_store_required}
    end
  end

  defp target({:ok, _}), do: {:ok, :completed}
  defp target(_), do: {:ok, :unknown_outcome}

  defp rt({:completed, _}), do: :reconciled_completed
  defp rt({:failed, _}), do: :reconciled_not_applied
  defp rt({:unknown_outcome, _}), do: :reconciled_unknown

  defp append(m, s, c, event) do
    prev =
      case m.receipts(s, c.claim_id) do
        {:ok, []} -> "sha256:root"
        {:ok, rs} -> List.last(rs)["chain_digest"]
        _ -> "sha256:root"
      end

    with {:ok, r} <- ClaimReceipt.build(c, event, prev),
         do: m.append_receipt(s, c.claim_id, r)
  end
end
