defmodule AshA2A.ConsequenceKernel.W4B.MigrationRegistry do
  @moduledoc false
  @entries %{
    agent_observe: :dispatch_observe,
    command_bus_change: :kernel,
    command_bus_external_do: :kernel
  }
  def target(edge), do: Map.fetch(@entries, edge)
  def entries, do: @entries
end
