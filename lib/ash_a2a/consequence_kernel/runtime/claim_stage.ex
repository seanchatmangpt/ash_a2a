defmodule AshA2A.ConsequenceKernel.Runtime.ClaimStage do
  alias AshA2A.ConsequenceKernel.Runtime.StoreHandle

  def run(s, p, o) do
    with :ok <- StoreHandle.call(s, :claim_request, [p.instance.request_id, o]),
         :ok <- StoreHandle.call(s, :claim_effect, [p.instance.effect_id, o]),
         :ok <- StoreHandle.call(s, :transition, [p.digest, :prepared, :claimed]),
         do: :ok
  end
end
