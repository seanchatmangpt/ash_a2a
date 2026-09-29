defmodule AshA2A.ConsequenceKernel.Runtime.OutcomeStage do
  alias AshA2A.ConsequenceKernel.Runtime.StoreHandle
  def persist(s,p,{:ok,v}) do
    with :ok<-StoreHandle.call(s,:transition,[p.prepared_digest,:applying,:completed]), do: {:ok,v}
  end
  def persist(s,p,{:unknown,r}) do
    _=StoreHandle.call(s,:transition,[p.prepared_digest,:applying,:unknown_outcome]); {:unknown,r}
  end
  def persist(s,p,{:error,r}) do
    _=StoreHandle.call(s,:transition,[p.prepared_digest,:applying,:unknown_outcome]); {:unknown,{:effector_error_after_apply_boundary,r}}
  end
end
