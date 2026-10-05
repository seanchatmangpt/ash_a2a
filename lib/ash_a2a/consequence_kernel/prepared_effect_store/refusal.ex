# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.PreparedEffectStore.Refusal do
  @codes [
    :prepared_duplicate,
    :prepared_authentication_failed,
    :prepared_key_unavailable,
    :prepared_transition_refused,
    :claim_conflict,
    :prepared_state_unknown
  ]
  def codes, do: @codes
  def known?(code), do: code in @codes
end
