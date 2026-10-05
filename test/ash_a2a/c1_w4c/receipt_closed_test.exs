# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W4C.ReceiptClosedTest do
  use ExUnit.Case, async: true

  alias AshA2A.ConsequenceKernel.W4C.{
    AdmittedTopology,
    ChicagoAdapter,
    ClosurePredicate,
    ClosureReceipt,
    GraphEdge,
    GraphReport,
    UnresolvedApply
  }

  test "receipt_closed" do
    assert %{standing: :derived, raw_edges: 0} = ClosureReceipt.issue([])
  end
end
