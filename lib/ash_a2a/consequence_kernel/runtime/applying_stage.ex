defmodule AshA2A.ConsequenceKernel.Runtime.ApplyingStage do
  alias AshA2A.ConsequenceKernel.Runtime.{PreparedDigest, StoreHandle}

  def run(store, prepared) do
    with {:ok, digest} <- PreparedDigest.fetch(prepared),
         do: StoreHandle.call(store, :transition, [digest, :claimed, :applying])
  end
end
