defmodule AshA2A.Effector do
  @callback apply(AshA2A.PreparedEffect.t()) :: {:ok,term()} | {:unknown,term()} | {:error,term()}
end
