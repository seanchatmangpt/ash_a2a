defmodule AshA2A.ConsequenceKernel.W4C.CallerPolicy do
  def kernel?(caller), do: String.starts_with?(to_string(caller), "Elixir.AshA2A.ConsequenceKernel")
end
