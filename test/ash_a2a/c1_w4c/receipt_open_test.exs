# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W4C.ReceiptOpenTest do
  use ExUnit.Case, async: true

  alias AshA2A.ConsequenceKernel.Closure.AdmittedTopology
  alias AshA2A.ConsequenceKernel.Closure.ChicagoAdapter
  alias AshA2A.ConsequenceKernel.Closure.Predicate, as: ClosurePredicate
  alias AshA2A.ConsequenceKernel.Closure.Receipt, as: ClosureReceipt
  alias AshA2A.ConsequenceKernel.Closure.GraphEdge
  alias AshA2A.ConsequenceKernel.Closure.GraphReport
  alias AshA2A.ConsequenceKernel.Closure.UnresolvedApply

  test "receipt_open" do
    assert %{standing: :refused, raw_edges: 1} =
             ClosureReceipt.issue([
               %GraphEdge{caller: "Elixir.Legacy", callee: "Elixir.Ash", kind: :effect}
             ])
  end
end
