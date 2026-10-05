# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.Feedback do
  @enforce_keys [:subject, :receipt_id, :outcome]
  defstruct [:subject, :receipt_id, :outcome, :evidence, :provider]

  def from_receipt(r, provider \\ nil),
    do: %__MODULE__{
      subject: Map.get(r, :semantic_subject),
      receipt_id: Map.get(r, :receipt_id),
      outcome: AshA2A.Replan.Outcome.classify(r),
      evidence: r,
      provider: provider
    }
end
