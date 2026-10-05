# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W5.ClaimIdentity do
  alias AshA2A.Identity.Canonical

  def bind(r, e, p, s) when is_binary(r) and is_binary(e) and is_binary(p) and is_binary(s),
    do:
      Canonical.digest(%{
        "schema" => "sa2a.effect-claim-identity.v1",
        "request_id" => r,
        "effect_id" => e,
        "prepared_digest" => p,
        "subject_digest" => s
      })

  def bind(_, _, _, _), do: {:error, :invalid_claim_identity}
end
