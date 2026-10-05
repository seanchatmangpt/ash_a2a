# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.CandidateFence do
  def check(%{authority: :none, standing: :candidate}), do: :ok
  def check(_), do: {:error, AshA2A.Replan.Refusal.new(:replan_authority_violation)}
end
