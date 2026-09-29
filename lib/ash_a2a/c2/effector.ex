defmodule AshA2A.C2.Effector do
  @callback perform(AshA2A.C2.PreparedEffect.t()) :: {:ok, term()} | {:error, term()}
end
