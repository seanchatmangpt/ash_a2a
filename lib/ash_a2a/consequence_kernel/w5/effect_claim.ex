# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W5.EffectClaim do
  @moduledoc false
  @enforce_keys [
    :claim_id,
    :request_id,
    :effect_id,
    :prepared_digest,
    :subject_digest,
    :owner,
    :state,
    :issued_at_ms,
    :mac
  ]
  defstruct @enforce_keys

  # The MAC covers the immutable claim identity only. `state` is deliberately outside it: the
  # store advances state (claimed -> doing -> outcome) without the key, each step is admitted by
  # `ClaimTransition` and journaled in the chained claim receipts.
  def body(%__MODULE__{} = c) do
    %{
      "schema" => "sa2a.effect-claim.v1",
      "claim_id" => c.claim_id,
      "request_id" => c.request_id,
      "effect_id" => c.effect_id,
      "prepared_digest" => c.prepared_digest,
      "subject_digest" => c.subject_digest,
      "owner" => c.owner,
      "issued_at_ms" => c.issued_at_ms
    }
  end
end
