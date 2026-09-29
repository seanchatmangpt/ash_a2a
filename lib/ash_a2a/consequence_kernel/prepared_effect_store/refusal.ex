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
