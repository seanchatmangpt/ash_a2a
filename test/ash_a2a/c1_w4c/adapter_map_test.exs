defmodule AshA2A.C1W4C.AdapterMapTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.W4C.{AdmittedTopology,ChicagoAdapter,ClosurePredicate,ClosureReceipt,GraphEdge,GraphReport,UnresolvedApply}
  test "adapter_map" do
    assert {:ok, _} = ChicagoAdapter.evaluate(%{edges: []})
  end
end
