defmodule AshA2A.ConsequenceKernel.Runtime.ClaimStage do
  alias AshA2A.ConsequenceKernel.Runtime.{PreparedDigest, StoreHandle}

  def run(store, prepared, owner) do
    with {:ok, digest} <- PreparedDigest.fetch(prepared),
         :ok <- StoreHandle.call(store, :claim_request, [prepared.instance.request_id, owner]),
         :ok <- StoreHandle.call(store, :claim_effect, [prepared.instance.effect_id, owner]),
         :ok <- StoreHandle.call(store, :transition, [digest, :prepared, :claimed]),
         do: :ok
  end
end
