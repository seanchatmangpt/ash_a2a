defmodule AshA2A.Telemetry.AllocationCountersTest do
  @moduledoc """
  The real instrument behind RFC S65's `Allocation_LLM(class, t+1) <=
  Allocation_LLM(class, t)` claim.

  Real `:telemetry`, real `:ets`, real events emitted by the real
  `AshA2A.Semantic.Unknown.route/3` -- assertions are on the real
  accumulated integers.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{Allocator, Unknown}
  alias AshA2A.Telemetry.AllocationCounters

  # `owner: self()` makes the measurement genuinely this test's own.
  # `:telemetry` handlers attach to an event NAME globally and run in the
  # emitting process, so without it a concurrent `async: true` test that
  # also routes a real UNKNOWN lands its allocations in this table and the
  # whole-table `counts/1` assertion below becomes order-dependent.
  defp attached do
    tid = AllocationCounters.new()
    handler = AllocationCounters.attach!(tid, make_ref(), owner: self())
    on_exit(fn -> AllocationCounters.detach(handler) end)
    tid
  end

  defp budget, do: Allocator.new!(inference_calls: 1, compute_units: 1)

  test "an unobserved pair is a real zero, not missing data" do
    tid = attached()
    assert AllocationCounters.allocation(tid, "never-seen", :llm) == 0
    assert AllocationCounters.counts(tid) == %{}
  end

  test "real route/3 calls accumulate per class and per resolver" do
    tid = attached()

    resolver = fn %Unknown{} -> {:ok, %{"answer" => 1}} end

    assert {:ok, :resolved, _r, _b} =
             Unknown.route("class-a", %{}, budget: budget(), resolver: {:llm, resolver})

    assert {:ok, :resolved, _r, _b} =
             Unknown.route("class-a", %{}, budget: budget(), resolver: {:llm, resolver})

    assert {:ok, :resolved, _r, _b} =
             Unknown.route("class-b", %{}, budget: budget(), resolver: {:prover, resolver})

    assert AllocationCounters.allocation(tid, "class-a", :llm) == 2
    assert AllocationCounters.allocation(tid, "class-b", :prover) == 1
    assert AllocationCounters.allocation(tid, "class-b", :llm) == 0

    assert AllocationCounters.counts(tid) == %{
             "class-a" => %{llm: 2},
             "class-b" => %{prover: 1}
           }
  end

  test "a resolver that fails still records the spend it actually made" do
    tid = attached()

    assert {:unknown, %Unknown{reason: :resolver_failed}, _reason} =
             Unknown.route("burned-class", %{},
               budget: Allocator.new!(inference_calls: 1),
               resolver: {:llm, fn %Unknown{} -> {:error, :timeout} end}
             )

    # The call was made and the budget was spent; not counting it would
    # under-report real cost.
    assert AllocationCounters.allocation(tid, "burned-class", :llm) == 1
  end

  test "a route refused BEFORE the resolver call records no spend" do
    tid = attached()

    assert {:unknown, %Unknown{reason: :allocation_exhausted}, _reason} =
             Unknown.route("unspent-class", %{},
               resolver: {:llm, fn %Unknown{} -> {:ok, %{}} end}
             )

    assert AllocationCounters.allocation(tid, "unspent-class", :llm) == 0
  end

  test "two independent instruments never share state" do
    one = attached()
    two = attached()

    assert {:ok, :resolved, _r, _b} =
             Unknown.route("shared-class", %{},
               budget: Allocator.new!(inference_calls: 1),
               resolver: {:llm, fn %Unknown{} -> {:ok, %{}} end}
             )

    # Both are attached, so both saw it -- and detaching one later must
    # not disturb the other's accumulated counts.
    assert AllocationCounters.allocation(one, "shared-class", :llm) == 1
    assert AllocationCounters.allocation(two, "shared-class", :llm) == 1

    fresh = AllocationCounters.new()
    assert AllocationCounters.allocation(fresh, "shared-class", :llm) == 0
  end

  test "non_increasing?/2 is a real comparison over two measured integers" do
    assert AllocationCounters.non_increasing?(10, 10)
    assert AllocationCounters.non_increasing?(10, 3)
    refute AllocationCounters.non_increasing?(3, 10)
  end

  test "a malformed event fails closed instead of crashing the emitting process" do
    tid = attached()

    :telemetry.execute(Unknown.allocation_event(), %{count: 1}, %{unexpected: :shape})

    assert AllocationCounters.counts(tid) == %{}
  end
end
