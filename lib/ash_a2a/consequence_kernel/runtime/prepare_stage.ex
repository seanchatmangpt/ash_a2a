defmodule AshA2A.ConsequenceKernel.Runtime.PrepareStage do
  alias AshA2A.ConsequenceKernel.Runtime.{PreparedDigest, StoreHandle}
  def run(store, prepared) do
    with {:ok, digest} <- PreparedDigest.fetch(prepared), do: StoreHandle.call(store, :put, [%{digest: digest, state: :prepared, prepared: prepared}])
  end
end
