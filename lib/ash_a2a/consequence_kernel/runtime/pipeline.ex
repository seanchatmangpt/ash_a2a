defmodule AshA2A.ConsequenceKernel.Runtime.Pipeline do
  alias AshA2A.ConsequenceKernel.Runtime.{
    StoreHandle,
    PrepareStage,
    ClaimStage,
    AuthorityStage,
    ApplyingStage,
    OutcomeStage,
    EffectorToken
  }

  def execute(p, opts) do
    s = StoreHandle.new(Keyword.fetch!(opts, :store), Keyword.fetch!(opts, :store_handle))
    owner = Keyword.fetch!(opts, :owner)
    a = Keyword.fetch!(opts, :authority)
    e = Keyword.fetch!(opts, :effector)

    with :ok <- PrepareStage.run(s, p),
         :ok <- ClaimStage.run(s, p, owner),
         :ok <- AuthorityStage.run(a, Keyword.fetch!(opts, :principal), p),
         true <- AshA2A.ConsequenceClass.admitted?(p.consequence_class),
         :ok <- ApplyingStage.run(s, p) do
      token = EffectorToken.issue(p, owner)
      result = if function_exported?(e, :apply, 2), do: e.apply(p, token), else: e.apply(p)
      OutcomeStage.persist(s, p, result)
    else
      false -> {:error, :consequence_unclassified}
      {:error, _} = x -> x
      {:unknown, _} = x -> x
    end
  end
end
