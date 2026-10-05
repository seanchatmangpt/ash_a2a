# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.Receipt do
  @enforce_keys [:effect_id, :prepared_digest, :subject_digest, :outcome]
  defstruct [
    :effect_id,
    :prepared_digest,
    :subject_digest,
    :outcome,
    :previous_digest,
    :authority_epoch,
    :receipt_digest
  ]

  def issue(p, o, prev \\ nil) do
    body = %{
      "effect_id" => p.instance.effect_id,
      "prepared_digest" => p.prepared_digest,
      "subject_digest" => p.instance.subject_digest,
      "outcome" => to_string(o),
      "previous_digest" => prev,
      "authority_epoch" => p.authority_epoch
    }

    with {:ok, d} <- AshA2A.Identity.Canonical.digest(body),
         do:
           {:ok,
            struct!(__MODULE__,
              effect_id: p.instance.effect_id,
              prepared_digest: p.prepared_digest,
              subject_digest: p.instance.subject_digest,
              outcome: o,
              previous_digest: prev,
              authority_epoch: p.authority_epoch,
              receipt_digest: d
            )}
  end
end
