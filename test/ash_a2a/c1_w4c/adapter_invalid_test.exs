defmodule AshA2A.C1W4C.AdapterInvalidTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.W4C.{AdmittedTopology,ChicagoAdapter,ClosurePredicate,ClosureReceipt,GraphEdge,GraphReport,UnresolvedApply}
  test "adapter_invalid" do
    assert {:error, :invalid_chicago_report} = ChicagoAdapter.evaluate(:bad)
  end
end
