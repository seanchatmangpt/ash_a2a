defmodule AshA2A.ConsequenceKernel.Claim do
  def request(store, request_id, owner), do: store.claim_request(request_id, owner)
  def effect(store, effect_id, owner), do: store.claim_effect(effect_id, owner)
  def release_effect(store, effect_id, owner), do: store.release_effect(effect_id, owner)
end
