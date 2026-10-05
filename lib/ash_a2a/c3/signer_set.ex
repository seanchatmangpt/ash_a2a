# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C3.SignerSet do
  @moduledoc """
  C3 signer quorum. Delegates to `Sa2aCrypto.Quorum`: a signer counts only through a
  registry-verified signature under an active, non-revoked kid, and independence is
  counted over DISTINCT `custodian_id` at the required tier (RFC-SA2A-007 E-C), never over
  a `.signer` label or a `kid`.

  Crypto standing certifies; this module counts. It never authorizes an effect.

    * `quorum/2,3` - over standings already computed per signature
      (`AshA2A.CryptoStanding`): `{:ok, %{custodians, tier, ...}} | {:error, code}`
    * `evaluate/4` - over raw envelopes plus the signed bytes and a registry view
  """
  alias Sa2aCrypto.Quorum

  @spec quorum([term()], pos_integer(), atom()) :: {:ok, map()} | {:error, atom()}
  def quorum(standings, k, min_tier \\ :i1), do: Quorum.from_standings(standings, k, min_tier)

  @spec evaluate([term()], term(), {module(), term()}, map() | keyword()) ::
          {:ok, map()} | {:error, atom()}
  def evaluate(envelopes, message, registry, policy),
    do: Quorum.evaluate(envelopes, message, registry, policy)
end
