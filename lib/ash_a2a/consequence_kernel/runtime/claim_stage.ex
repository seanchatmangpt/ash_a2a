defmodule AshA2A.ConsequenceKernel.Runtime.ClaimStage do
  @moduledoc """
  Request and effect claims on the prepared-effect journal: `claim_request/3` and `finalize/2` are
  the two halves, `run/3` is both in order.
  """
  alias AshA2A.ConsequenceKernel.Runtime.{PreparedDigest, StoreHandle}

  def claim_request(store, prepared, owner),
    do: StoreHandle.call(store, :claim_request, [prepared.instance.request_id, owner])

  def finalize(store, prepared) do
    with {:ok, digest} <- PreparedDigest.fetch(prepared),
         do: StoreHandle.call(store, :transition, [digest, :prepared, :claimed])
  end

  def run(store, prepared, owner) do
    with {:ok, _digest} <- PreparedDigest.fetch(prepared),
         :ok <- claim_request(store, prepared, owner),
         :ok <- StoreHandle.call(store, :claim_effect, [prepared.instance.effect_id, owner]),
         do: finalize(store, prepared)
  end
end
