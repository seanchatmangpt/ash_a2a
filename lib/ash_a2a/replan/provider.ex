defmodule AshA2A.Replan.Provider do
  @callback propose(map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback supports?(atom()) :: boolean()
end
