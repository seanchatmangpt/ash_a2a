defmodule AshA2A.C1W4C.TopologyKernelTest do
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

  test "topology_kernel" do
    assert AdmittedTopology.admitted?("Elixir.AshA2A.ConsequenceKernel.X", :effect)
  end
end
