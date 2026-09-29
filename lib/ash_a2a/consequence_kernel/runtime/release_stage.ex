defmodule AshA2A.ConsequenceKernel.Runtime.ReleaseStage do
  alias AshA2A.ConsequenceKernel.Runtime.StoreHandle

  def release(s, p, from) when from in [:prepared, :claimed],
    do: StoreHandle.call(s, :transition, [p.digest, from, :released])

  def release(_, _, from), do: {:error, {:release_after_apply_forbidden, from}}
end
