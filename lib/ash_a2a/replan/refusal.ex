# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.Refusal do
  @codes [
    :replan_subject_drift,
    :replan_provider_unavailable,
    :replan_provider_refused,
    :replan_exhausted,
    :replan_candidate_invalid,
    :replan_authority_violation
  ]
  def new(code, detail \\ nil) when code in @codes, do: %{code: code, detail: detail}
  def codes, do: @codes
end
