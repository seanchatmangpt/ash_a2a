# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W4C.TopologyRawTest do
  use ExUnit.Case, async: true

  alias AshA2A.ConsequenceKernel.Closure.AdmittedTopology
  alias AshA2A.ConsequenceKernel.Closure.ChicagoAdapter
  alias AshA2A.ConsequenceKernel.Closure.Predicate, as: ClosurePredicate
  alias AshA2A.ConsequenceKernel.Closure.Receipt, as: ClosureReceipt
  alias AshA2A.ConsequenceKernel.Closure.GraphEdge
  alias AshA2A.ConsequenceKernel.Closure.GraphReport
  alias AshA2A.ConsequenceKernel.Closure.UnresolvedApply

  test "topology_raw" do
    refute AdmittedTopology.admitted?("Elixir.Legacy", :effect)
  end
end
