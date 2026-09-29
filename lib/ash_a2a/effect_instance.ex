defmodule AshA2A.EffectInstance do
  @enforce_keys [:request_id, :effect_id, :subject_digest]
  defstruct [:request_id, :effect_id, :subject_digest, :generation, :policy_epoch]
  alias AshA2A.ConsequenceKernel.{RequestIdentity,EffectIdentity,ExactSubject}
  def new(attrs) do
    with {:ok, request} <- fetch(attrs,:request),
         {:ok, effect} <- fetch(attrs,:effect),
         {:ok, subject} <- fetch(attrs,:subject),
         {:ok, request_id} <- RequestIdentity.derive(request),
         {:ok, subject_digest} <- ExactSubject.bind(subject),
         {:ok, effect_id} <- EffectIdentity.derive(request_id,effect) do
      {:ok, struct!(__MODULE__,request_id: request_id,effect_id: effect_id,subject_digest: subject_digest,generation: Map.get(attrs,:generation,0),policy_epoch: Map.get(attrs,:policy_epoch,0))}
    end
  end
  defp fetch(m,k), do: case Map.fetch(m,k) do {:ok,v}->{:ok,v}; :error->{:error,:effect_instance_missing_field} end
end
