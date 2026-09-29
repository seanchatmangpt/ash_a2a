defmodule AshA2A.ConsequenceKernel.Runtime.AuthorityStage do
  def run(a,principal,p) do
    case a.revalidate(principal,p) do
      :ok -> :ok
      {:ok,_} -> :ok
      {:error,_}=e -> e
      other -> {:error,{:authority_invalid,other}}
    end
  end
end
