defmodule AshA2A.ConsequenceKernel do
  def execute(prepared, opts) do
    store=Keyword.fetch!(opts,:store); owner=Keyword.fetch!(opts,:owner); authority=Keyword.fetch!(opts,:authority); effector=Keyword.fetch!(opts,:effector)
    with :ok <- store.claim_request(prepared.instance.request_id,owner), :ok <- store.claim_effect(prepared.instance.effect_id,owner), :ok <- authority.revalidate(Keyword.fetch!(opts,:principal),prepared), true <- AshA2A.ConsequenceClass.admitted?(prepared.consequence_class), {:ok,outcome} <- effector.apply(prepared), do: {:ok,outcome}, else: (false -> {:error,:consequence_unclassified}; {:error,_}=e -> e; {:unknown,e} -> {:unknown,e})
  end
end
