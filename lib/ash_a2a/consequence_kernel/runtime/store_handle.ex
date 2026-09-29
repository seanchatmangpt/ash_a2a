defmodule AshA2A.ConsequenceKernel.Runtime.StoreHandle do
  @moduledoc false
  defstruct [:module, :server]
  def new(module, server), do: %__MODULE__{module: module, server: server}
  def call(%__MODULE__{module: m, server: s}, fun, args), do: apply(m, fun, [s | args])
end
