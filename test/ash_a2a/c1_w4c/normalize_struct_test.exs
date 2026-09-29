defmodule AshA2A.C1W4C.NormalizeStructTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.W4C.{AdmittedTopology,ChicagoAdapter,ClosurePredicate,ClosureReceipt,GraphEdge,GraphReport,UnresolvedApply}
  test "normalize_struct" do
    e=%GraphEdge{caller:"A",callee:"B",kind: :effect}; assert [^e]=GraphReport.normalize([e])
  end
end
