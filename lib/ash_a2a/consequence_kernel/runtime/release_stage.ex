defmodule AshA2A.ConsequenceKernel.Runtime.ReleaseStage do
  alias AshA2A.ConsequenceKernel.Runtime.{PreparedDigest, StoreHandle}

  def release(s, p, from) when from in [:prepared, :claimed] do
    with {:ok, digest} <- PreparedDigest.fetch(p),
         do: StoreHandle.call(s, :transition, [digest, from, :released])
  end

  def release(_, _, from), do: {:error, {:release_after_apply_forbidden, from}}
end
