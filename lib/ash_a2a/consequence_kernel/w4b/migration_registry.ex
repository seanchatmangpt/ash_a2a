# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

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
