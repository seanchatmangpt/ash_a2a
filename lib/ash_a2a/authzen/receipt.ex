defmodule AshA2A.AuthZEN.Receipt do
  @moduledoc """
  Receipt of one observed AuthZEN evaluation, built by `build/2` with request digest,
  effect digest, PDP, and decision. Authority is fixed at `:none` and consequence at
  `:evidence_only`; it records evidence and confers no authority.
  """

  alias AshA2A.AuthZEN.{PolicyEvidence, Types, Wire}
  alias AshA2A.Identity.Canonical

  @enforce_keys [:request_digest, :effect_digest, :policy_decision_point, :decision, :observed_at]
  defstruct @enforce_keys ++ [authority: :none, consequence: :evidence_only]

  def build(%Types.Request{} = request, %PolicyEvidence{} = evidence) do
    with {:ok, digest} <- Canonical.digest(Wire.request(request)) do
      {:ok,
       %__MODULE__{
         request_digest: digest,
         effect_digest: evidence.effect_digest,
         policy_decision_point: evidence.policy_decision_point,
         decision: evidence.decision,
         observed_at: evidence.observed_at
       }}
    end
  end
end
