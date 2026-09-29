defmodule AshA2A.C1W4C.ReceiptOpenTest do
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

  test "receipt_open" do
    assert %{standing: :refused, raw_edges: 1} =
             ClosureReceipt.issue([
               %GraphEdge{caller: "Elixir.Legacy", callee: "Elixir.Ash", kind: :effect}
             ])
  end
end
