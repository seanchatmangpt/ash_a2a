defmodule AshA2A.C1W4C.AdapterListTest do
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

  test "adapter_list" do
    assert {:ok, _} = ChicagoAdapter.evaluate([])
  end
end
