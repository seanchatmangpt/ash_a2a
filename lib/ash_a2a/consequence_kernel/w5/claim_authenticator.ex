# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W5.ClaimAuthenticator do
  alias AshA2A.ConsequenceKernel.W5.{ClaimIdentity, EffectClaim}
  alias AshA2A.Identity.Canonical

  def issue(a, k) when is_map(a) and is_binary(k) and byte_size(k) >= 16 do
    with {:ok, id} <-
           ClaimIdentity.bind(
             Map.fetch!(a, :request_id),
             Map.fetch!(a, :effect_id),
             Map.fetch!(a, :prepared_digest),
             Map.fetch!(a, :subject_digest)
           ) do
      c =
        struct!(EffectClaim,
          claim_id: id,
          request_id: Map.fetch!(a, :request_id),
          effect_id: Map.fetch!(a, :effect_id),
          prepared_digest: Map.fetch!(a, :prepared_digest),
          subject_digest: Map.fetch!(a, :subject_digest),
          owner: a |> Map.fetch!(:owner) |> owner_string(),
          state: :claimed,
          issued_at_ms: Map.get(a, :issued_at_ms, System.system_time(:millisecond)),
          mac: ""
        )

      with {:ok, b} <- Canonical.encode(EffectClaim.body(c)), do: {:ok, %{c | mac: mac(b, k)}}
    end
  end

  def issue(_, _), do: {:error, :effect_claim_key_invalid}

  def verify(%EffectClaim{} = c, k) when is_binary(k) and byte_size(k) >= 16 do
    with {:ok, b} <- Canonical.encode(EffectClaim.body(c)),
         e <- mac(b, k),
         true <- is_binary(c.mac) and byte_size(c.mac) == byte_size(e),
         true <- :crypto.hash_equals(e, c.mac),
         do: :ok,
         else: (_ -> {:error, :effect_claim_authentication_failed})
  end

  def verify(_, _), do: {:error, :effect_claim_authentication_failed}
  # Runtime owners are arbitrary terms (pids, atoms); the claim body carries their stable text.
  defp owner_string(o) when is_binary(o), do: o
  defp owner_string(o), do: inspect(o)

  defp mac(b, k), do: :crypto.mac(:hmac, :sha256, k, b) |> Base.encode16(case: :lower)
end
