defmodule AshA2A.C1W4C.NormalizeMapTest do
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

  test "normalize_map" do
    assert [%GraphEdge{kind: :effect}] =
             GraphReport.normalize([%{caller: "A", callee: "B", kind: :effect}])
  end
end
