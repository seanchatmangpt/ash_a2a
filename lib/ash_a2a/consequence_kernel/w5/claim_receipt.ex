# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W5.ClaimReceipt do
  alias AshA2A.ConsequenceKernel.W5.{EffectClaim, ReceiptChain}
  @root "sha256:root"
  def build(%EffectClaim{} = c, event, prev \\ @root) when is_atom(event) do
    body = %{
      "schema" => "sa2a.effect-claim-receipt.v1",
      "claim_id" => c.claim_id,
      "effect_id" => c.effect_id,
      "prepared_digest" => c.prepared_digest,
      "event" => Atom.to_string(event),
      "previous" => prev
    }

    with {:ok, d} <- ReceiptChain.append(prev, body), do: {:ok, Map.put(body, "chain_digest", d)}
  end

  def verify_chain(rs) when is_list(rs) do
    Enum.reduce_while(rs, {:ok, @root}, fn r, {:ok, p} ->
      e = Map.delete(r, "chain_digest")

      with ^p <- Map.get(e, "previous"),
           {:ok, d} <- ReceiptChain.append(p, e),
           ^d <- Map.get(r, "chain_digest"),
           do: {:cont, {:ok, d}},
           else: (_ -> {:halt, {:error, :receipt_chain_invalid}})
    end)
    |> case do
      {:ok, _} -> :ok
      e -> e
    end
  end

  def verify_chain(_), do: {:error, :receipt_chain_invalid}
end
