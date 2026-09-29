defmodule AshA2A.C1W4C.TopologyRawTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.W4C.{AdmittedTopology,ChicagoAdapter,ClosurePredicate,ClosureReceipt,GraphEdge,GraphReport,UnresolvedApply}
  test "topology_raw" do
    refute AdmittedTopology.admitted?("Elixir.Legacy", :effect)
  end
end
