defmodule AshA2A.ConsequenceKernel.W4.ArchitecturePolicy do
  @moduledoc false
  @forbidden ["AshA2A.Dispatcher.dispatch(", "Ash.create(", "Ash.update(", "Ash.destroy("]
  def forbidden_tokens, do: @forbidden

  def violations(source) when is_binary(source),
    do: Enum.filter(@forbidden, &String.contains?(source, &1))
end
