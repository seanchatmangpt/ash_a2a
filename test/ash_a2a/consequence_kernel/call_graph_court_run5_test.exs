defmodule AshA2A.ConsequenceKernel.CallGraphCourtRun5Test do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.{CallGraphCourt, SourceCallGraph}

  test "kernel route is admitted" do
    edges = SourceCallGraph.project("AshA2A.ConsequenceKernel.execute(effect, opts)", "subject:ok")
    assert :ok = CallGraphCourt.judge(edges)
  end

  test "dispatcher bypass is refused" do
    edges = SourceCallGraph.project("AshA2A.Dispatcher.dispatch(skill, msg, resource, [], nil)", "subject:bypass")
    assert {:error, %{reason: :kernel_bypass}} = CallGraphCourt.judge(edges)
  end

  test "direct Ash effect is refused" do
    edges = SourceCallGraph.project("Ash.create(changeset)", "subject:ash")
    assert {:error, %{reason: :direct_effect_bypass}} = CallGraphCourt.judge(edges)
  end

  test "dynamic apply is unresolved and refused" do
    edges = SourceCallGraph.project("apply(mod, fun, args)", "subject:dynamic")
    assert {:error, %{reason: :unresolved_dynamic_consequence}} = CallGraphCourt.judge(edges)
  end
end
