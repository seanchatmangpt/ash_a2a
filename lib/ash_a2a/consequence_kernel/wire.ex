defmodule AshA2A.ConsequenceKernel.Wire do
  def encode(value), do: JCS.encode(value)
  def digest(value), do: AshA2A.Identity.Canonical.digest(value)
end
