defmodule AshA2A.Replan.Refusal do
  @codes [:replan_subject_drift,:replan_provider_unavailable,:replan_provider_refused,:replan_exhausted,:replan_candidate_invalid,:replan_authority_violation]
  def new(code, detail \\ nil) when code in @codes, do: %{code: code, detail: detail}
  def codes, do: @codes
end