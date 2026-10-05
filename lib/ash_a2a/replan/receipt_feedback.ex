# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.ReceiptFeedback do
  def ingest(receipt, provider \\ nil) do
    receipt
    |> AshA2A.Replan.Feedback.from_receipt(provider)
    |> AshA2A.Replan.Observation.from_feedback()
    |> AshA2A.Replan.Router.decide()
  end
end
