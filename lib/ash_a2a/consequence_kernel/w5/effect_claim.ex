defmodule AshA2A.ConsequenceKernel.W5.EffectClaim do
  @moduledoc false
  @enforce_keys [:claim_id, :request_id, :effect_id, :prepared_digest, :subject_digest, :owner, :state, :issued_at_ms, :mac]
  defstruct @enforce_keys
  def body(%__MODULE__{} = c) do
    %{"schema"=>"sa2a.effect-claim.v1","claim_id"=>c.claim_id,"request_id"=>c.request_id,
      "effect_id"=>c.effect_id,"prepared_digest"=>c.prepared_digest,"subject_digest"=>c.subject_digest,
      "owner"=>c.owner,"state"=>Atom.to_string(c.state),"issued_at_ms"=>c.issued_at_ms}
  end
end
