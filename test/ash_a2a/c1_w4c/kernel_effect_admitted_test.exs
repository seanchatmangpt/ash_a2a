defmodule AshA2A.C1W4C.KernelEffectAdmittedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.W4C.{AdmittedTopology,ChicagoAdapter,ClosurePredicate,ClosureReceipt,GraphEdge,GraphReport,UnresolvedApply}
  test "kernel_effect_admitted" do
    assert {:ok, _} = ClosurePredicate.evaluate([%GraphEdge{caller: "Elixir.AshA2A.ConsequenceKernel.Effector", callee: "Elixir.Ash", kind: :effect}])
  end
end
