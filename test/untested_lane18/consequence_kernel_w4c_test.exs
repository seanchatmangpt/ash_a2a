defmodule AshA2A.UntestedLane18.ConsequenceKernelW4CTest do
  use ExUnit.Case, async: true

  alias AshA2A.ConsequenceKernel.W4C.{
    AdmittedTopology,
    CallerPolicy,
    ChicagoAdapter,
    Closure,
    ClosurePredicate,
    ClosureReceipt,
    ClosureStatus,
    Counterexample,
    Dedupe,
    DispatcherPolicy,
    EdgeIdentity,
    GraphEdge,
    GraphReport,
    KernelFilter,
    MigrationTarget,
    RawEffectEdges,
    ReceiptDigest,
    ReportSchema,
    UnresolvedApply,
    ZeroEdgeGuard
  }

  @k "Elixir.AshA2A.ConsequenceKernel.Foo"
  @raw %GraphEdge{caller: "Elixir.Other.Mod", callee: :do_it, kind: :effect}
  @kernel %GraphEdge{caller: @k, callee: :do_it, kind: :effect}
  @obs %GraphEdge{caller: "Elixir.Other.Mod", callee: :read, kind: :observe}

  test "topology and caller policy: kernel prefix only" do
    assert CallerPolicy.kernel?(@k)
    assert CallerPolicy.kernel?(AshA2A.ConsequenceKernel.Receipt)
    refute CallerPolicy.kernel?("Elixir.Other")
    assert AdmittedTopology.admitted?(@k, :effect)
    assert AdmittedTopology.admitted?(@k, :dispatcher)
    refute AdmittedTopology.admitted?("Elixir.Other", :dynamic_effect)
    assert AdmittedTopology.admitted?("Elixir.Other", :observe)
    refute AdmittedTopology.admitted?(@k, :weird)
  end

  test "GraphEdge consequential kinds and enforce_keys" do
    assert GraphEdge.consequential?(@raw)
    refute GraphEdge.consequential?(@obs)
    assert_raise ArgumentError, fn -> struct!(GraphEdge, caller: "a") end
  end

  test "GraphReport normalizes maps into structs and keeps structs" do
    [e1, e2] =
      GraphReport.normalize([%{caller: "c", callee: :d, kind: :effect, source: "f.ex:1"}, @obs])

    assert %GraphEdge{source: "f.ex:1"} = e1
    assert e2 == @obs
  end

  test "RawEffectEdges drops observation and kernel edges" do
    assert [@raw] = RawEffectEdges.from_report([@raw, @kernel, @obs])
    assert [] = RawEffectEdges.from_report([])
    assert [%GraphEdge{kind: :dispatcher}] =
             RawEffectEdges.from_report([%{caller: "x", callee: :y, kind: :dispatcher}])
  end

  test "KernelFilter keeps only outside-kernel callers" do
    assert [@raw, @obs] = KernelFilter.outside([@raw, @kernel, @obs])
  end

  test "ClosurePredicate / ChicagoAdapter / ClosureReceipt agree" do
    assert {:ok, :zero_consequential_raw_effect_edges} = ClosurePredicate.evaluate([@kernel, @obs])
    assert {:error, {:raw_effect_edges, [@raw]}} = ClosurePredicate.evaluate([@raw, @kernel])
    assert {:ok, _} = ChicagoAdapter.evaluate(%{edges: [@kernel]})
    assert {:error, {:raw_effect_edges, [_]}} = ChicagoAdapter.evaluate([@raw])
    assert {:error, :invalid_chicago_report} = ChicagoAdapter.evaluate(:nope)
    assert {:error, :invalid_chicago_report} = ChicagoAdapter.evaluate(%{x: 1})

    assert %{standing: :derived, raw_edges: 0} = ClosureReceipt.issue([@kernel])
    assert %{standing: :refused, raw_edges: 2} = ClosureReceipt.issue([@raw, @raw])
  end

  test "Closure, ClosureStatus, ZeroEdgeGuard, Counterexample on empty vs non-empty" do
    assert Closure.closed?([])
    refute Closure.closed?([@raw])
    assert ClosureStatus.from_edges([]) == :closed
    assert ClosureStatus.from_edges([@raw]) == :open
    assert :ok = ZeroEdgeGuard.admit([])
    assert {:error, {:raw_effect_edges, 2}} = ZeroEdgeGuard.admit([@raw, @obs])
    assert Counterexample.minimal([]) == nil
    assert Counterexample.minimal([@raw, @obs]) == @raw
  end

  test "EdgeIdentity and Dedupe ignore source, keep distinct edges" do
    a = %GraphEdge{caller: "c", callee: :d, kind: :effect, source: "a"}
    b = %GraphEdge{caller: "c", callee: :d, kind: :effect, source: "b"}
    other = %GraphEdge{caller: "c", callee: :d, kind: :dispatcher}
    assert EdgeIdentity.key(a) == EdgeIdentity.key(b)
    assert EdgeIdentity.key(%{caller: "c", callee: :d, kind: :effect}) == EdgeIdentity.key(a)
    assert [^a, ^other] = Dedupe.edges([a, b, other])
  end

  test "DispatcherPolicy and MigrationTarget" do
    assert DispatcherPolicy.classify(:dispatch) == :consequence
    assert DispatcherPolicy.classify(:dispatch_observe) == :observation
    assert MigrationTarget.for_kind(:observe) == :dispatch_observe
    assert MigrationTarget.for_kind(:effect) == :consequence_kernel
  end

  test "ReceiptDigest deterministic and sensitive; ReportSchema" do
    assert ReceiptDigest.digest([@raw]) == ReceiptDigest.digest([@raw])
    refute ReceiptDigest.digest([@raw]) == ReceiptDigest.digest([@obs])
    assert ReceiptDigest.digest([]) =~ ~r/\A[0-9a-f]{64}\z/
    assert ReportSchema.valid?(%{edges: []})
    refute ReportSchema.valid?(%{edges: :x})
    refute ReportSchema.valid?([])
  end

  test "UnresolvedApply yields a consequential dynamic edge that blocks closure" do
    e = UnresolvedApply.edge("Elixir.Other", "f.ex:9")
    assert %GraphEdge{callee: :unresolved_apply, kind: :dynamic_effect, source: "f.ex:9"} = e
    assert GraphEdge.consequential?(e)
    assert {:error, {:raw_effect_edges, [^e]}} = ClosurePredicate.evaluate([e])
    assert {:ok, _} = ClosurePredicate.evaluate([UnresolvedApply.edge(@k, "x")])
  end
end
