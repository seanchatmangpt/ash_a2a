defmodule AshA2A.ConsequenceKernel.Runtime.PrepareStage do
  alias AshA2A.ConsequenceKernel.Runtime.StoreHandle

  def run(s, p),
    do: StoreHandle.call(s, :put, [%{digest: p.digest, state: :prepared, prepared: p}])
end
