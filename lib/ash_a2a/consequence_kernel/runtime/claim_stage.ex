defmodule AshA2A.ConsequenceKernel.Runtime.ClaimStage do
  alias AshA2A.ConsequenceKernel.Runtime.StoreHandle
  def claim_request(s,p,o), do: StoreHandle.call(s,:claim_request,[p.instance.request_id,o])
  def finalize(s,p), do: StoreHandle.call(s,:transition,[p.prepared_digest,:prepared,:claimed])
  def run(s,p,o) do
    with :ok<-claim_request(s,p,o), :ok<-StoreHandle.call(s,:claim_effect,[p.instance.effect_id,o]), :ok<-finalize(s,p), do: :ok
  end
end
