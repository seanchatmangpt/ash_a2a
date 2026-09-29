defmodule AshA2A.EffectInstance do
  @enforce_keys [:request_id, :effect_id, :subject_digest]
  defstruct [:request_id, :effect_id, :subject_digest, :generation, :policy_epoch]

  def new(attrs) do
    with {:ok, request_id} <- AshA2A.Identity.Canonical.digest(Map.fetch!(attrs, :request)),
         {:ok, subject_digest} <- AshA2A.Identity.Canonical.digest(Map.fetch!(attrs, :subject)),
         {:ok, effect_id} <-
           AshA2A.Identity.Canonical.digest(%{
             "request_id" => request_id,
             "effect" => Map.fetch!(attrs, :effect)
           }) do
      {:ok,
       struct!(__MODULE__,
         request_id: request_id,
         effect_id: effect_id,
         subject_digest: subject_digest,
         generation: Map.get(attrs, :generation, 0),
         policy_epoch: Map.get(attrs, :policy_epoch, 0)
       )}
    end
  rescue
    KeyError -> {:error, :effect_instance_missing_field}
  end
end
