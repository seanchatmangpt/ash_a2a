defmodule AshA2A.ConsequenceKernel.W4C.GraphEdge do
  @enforce_keys [:caller, :callee, :kind]
  defstruct [:caller, :callee, :kind, :source]
  def consequential?(%__MODULE__{kind: k}), do: k in [:effect, :dynamic_effect, :dispatcher]
end
