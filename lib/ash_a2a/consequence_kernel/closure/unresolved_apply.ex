# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.Closure.UnresolvedApply do
  alias AshA2A.ConsequenceKernel.Closure.GraphEdge

  def edge(caller, source),
    do: %GraphEdge{
      caller: caller,
      callee: :unresolved_apply,
      kind: :dynamic_effect,
      source: source
    }
end
