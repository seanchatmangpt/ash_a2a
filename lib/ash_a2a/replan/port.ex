defmodule AshA2A.Replan.Port do
  @callback observe(term(), term(), map()) :: {:ok,map()} | {:error,term()}
  @callback propose(map(), keyword()) :: {:ok,map()} | {:error,term()}
end