defmodule AshA2A.C2.AuthorityClient do
  @callback authorize(AshA2A.C2.PreparedEffect.t(), map()) :: {:ok, map()} | {:error, term()}
end
