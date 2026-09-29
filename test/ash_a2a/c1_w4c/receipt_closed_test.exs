defmodule AshA2A.C1W4C.ReceiptClosedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.W4C.{AdmittedTopology,ChicagoAdapter,ClosurePredicate,ClosureReceipt,GraphEdge,GraphReport,UnresolvedApply}
  test "receipt_closed" do
    assert %{standing: :derived, raw_edges: 0} = ClosureReceipt.issue([])
  end
end
