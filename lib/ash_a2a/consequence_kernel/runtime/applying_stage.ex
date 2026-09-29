defmodule AshA2A.ConsequenceKernel.Runtime.ApplyingStage do
  alias AshA2A.ConsequenceKernel.Runtime.StoreHandle
  def run(s,p), do: StoreHandle.call(s,:transition,[p.prepared_digest,:claimed,:applying])
end
