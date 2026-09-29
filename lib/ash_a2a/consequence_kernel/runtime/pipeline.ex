defmodule AshA2A.ConsequenceKernel.Runtime.Pipeline do
  alias AshA2A.ConsequenceKernel.Runtime.{StoreHandle,PrepareStage,ClaimStage,AuthorityStage,ApplyingStage,OutcomeStage,EffectorToken}
  alias AshA2A.ConsequenceKernel.W5.ClaimProtocol
  def execute(p,opts) do
    s=StoreHandle.new(Keyword.fetch!(opts,:store),Keyword.fetch!(opts,:store_handle))
    owner=Keyword.fetch!(opts,:owner); authority=Keyword.fetch!(opts,:authority); effector=Keyword.fetch!(opts,:effector)
    with :ok<-PrepareStage.run(s,p), :ok<-ClaimStage.claim_request(s,p,owner),
      :ok<-AuthorityStage.run(authority,Keyword.fetch!(opts,:principal),p),
      true<-AshA2A.ConsequenceClass.admitted?(p.consequence_class),
      {:ok,ctx}<-ClaimProtocol.claim(p,owner,opts), :ok<-ClaimStage.finalize(s,p),
      :ok<-ClaimProtocol.begin_do(ctx), :ok<-ApplyingStage.run(s,p) do
      token=EffectorToken.issue(p,owner)
      result=if function_exported?(effector,:apply,2), do: effector.apply(p,token), else: effector.apply(p)
      outcome=OutcomeStage.persist(s,p,result); _=ClaimProtocol.record_outcome(ctx,outcome); outcome
    else false->{:error,:consequence_unclassified}; {:error,_}=e->e; {:unknown,_}=u->u end
  end
end
