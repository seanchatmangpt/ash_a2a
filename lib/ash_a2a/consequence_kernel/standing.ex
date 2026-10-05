# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.Standing do
  def derive(%{outcome: :observed, receipt_verified?: true}), do: {:ok, :evidenced}
  def derive(%{outcome: :unknown}), do: {:error, :standing_unknown_outcome}
  def derive(_), do: {:error, :standing_evidence_missing}
end
