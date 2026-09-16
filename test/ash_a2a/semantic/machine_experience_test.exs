defmodule AshA2A.Semantic.MachineExperienceTest do
  @moduledoc """
  RFC S39/S65: a successfully resolved UNKNOWN compiles back into
  reusable machinery, so the same semantic class routes deterministically
  next time -- and the resulting decline in LLM allocation is
  **measured**, not asserted.

  The headline test (`Allocation_LLM(class, t+1) <= Allocation_LLM(class, t)`)
  runs the real `AshA2A.Semantic.Unknown.route/3` ten times against the
  same semantic class with a real attached
  `AshA2A.Telemetry.AllocationCounters` instrument, compiles back after
  the first resolution, and asserts on the real counter values the real
  telemetry handler accumulated. Nothing about that measurement is
  stubbed: real telemetry, real `:ets` counters, real routing.

  The resolver is a real injected 1-arity function (the same DI-seam
  idiom as `AshA2A.Semantic.Compiler`'s `:generate_object`). For the
  second epoch it is a real function that unconditionally raises -- so
  "the LLM was not called again" is proven by the absence of a crash on
  a real executed path, not by reading the router's code.
  """

  use ExUnit.Case, async: true

  alias AshA2A.CapabilityIndex.Changelog
  alias AshA2A.Semantic.LlmBoundary
  alias AshA2A.Semantic.MachineExperience
  alias AshA2A.Semantic.MachineExperience.Machinery
  alias AshA2A.Semantic.{Allocator, Unknown}
  alias AshA2A.Semantic.Unknown.Resolution
  alias AshA2A.Telemetry.AllocationCounters

  @class "shipment-eta-estimate"

  defp budget(n), do: Allocator.new!([inference_calls: n], issued_by: {:host, __MODULE__})

  # The real "LLM": returns a structured answer derived from the subject.
  # Deterministic here so the compiled-back rule can be checked against
  # it, but it is a genuine injected resolver, not a mock object.
  defp llm_resolver do
    fn %Unknown{subject: %{"days" => days}} ->
      {:ok, %{"eta_hours" => days * 24, "method" => "llm-derived"}}
    end
  end

  defp raising_resolver do
    fn %Unknown{} ->
      raise "machine-experience proof violated: the LLM resolver was invoked again"
    end
  end

  # --------------------------------------------------------------------
  # THE MEASUREMENT: Allocation_LLM(class, t+1) <= Allocation_LLM(class, t)
  # --------------------------------------------------------------------

  test "Allocation_LLM(class, t+1) <= Allocation_LLM(class, t) is measured by a real attached counter" do
    tid = AllocationCounters.new()
    handler = AllocationCounters.attach!(tid, make_ref(), owner: self())
    on_exit(fn -> AllocationCounters.detach(handler) end)

    store = MachineExperience.new_store()

    # --- Epoch t: the class is genuinely UNKNOWN. One real LLM route. ---
    assert {:ok, :resolved, %Resolution{} = resolution, _budget} =
             Unknown.route(@class, %{"days" => 3},
               machinery: store,
               budget: budget(1),
               resolver: {:llm, llm_resolver()}
             )

    assert resolution.payload == %{"eta_hours" => 72, "method" => "llm-derived"}

    allocation_llm_at_t = AllocationCounters.allocation(tid, @class, :llm)
    assert allocation_llm_at_t == 1
    assert AllocationCounters.allocation(tid, @class, :machinery) == 0

    # --- Compile back (RFC S39/S65). The caller derives the real
    # deterministic function; the resolution does not install itself. ---
    assert {:ok, %Machinery{} = machinery} =
             MachineExperience.compile_back(
               resolution,
               :rule,
               fn %{"days" => days} -> {:ok, %{"eta_hours" => days * 24, "method" => "rule"}} end,
               note: "compiled back from the epoch-t LLM resolution"
             )

    assert machinery.class == @class
    assert machinery.kind == :rule
    assert machinery.provenance["resolver"] == "llm"
    assert machinery.provenance["resolution_fingerprint"] == resolution.fingerprint

    assert {:ok, store, %Changelog{} = changelog} = MachineExperience.register(store, machinery)
    assert changelog.added == [@class]
    assert changelog.removed == []

    # --- Epoch t+1: nine more real routes of the SAME class. The
    # resolver is now a real function that raises if invoked, so any
    # regression here fails loudly rather than silently costing money. ---
    for days <- 1..9 do
      assert {:ok, :machinery, %{"eta_hours" => hours, "method" => "rule"}, _budget} =
               Unknown.route(@class, %{"days" => days},
                 machinery: store,
                 budget: budget(1),
                 resolver: {:llm, raising_resolver()}
               )

      assert hours == days * 24
    end

    allocation_llm_at_t_plus_1 = AllocationCounters.allocation(tid, @class, :llm)

    # The real measured inequality, over two real observations.
    assert AllocationCounters.non_increasing?(allocation_llm_at_t, allocation_llm_at_t_plus_1)
    assert allocation_llm_at_t_plus_1 == 1
    assert AllocationCounters.allocation(tid, @class, :machinery) == 9

    assert AllocationCounters.counts(tid) == %{@class => %{llm: 1, machinery: 9}}
  end

  test "adversarial completeness: without compile-back, the same ten routes really do spend LLM ten times" do
    # Without this companion, the test above could pass for the wrong
    # reason (a router that never emits, a counter that never counts, a
    # class key mismatch). This proves the same instrument, the same
    # class, and the same route DO accumulate real LLM allocations when
    # no machinery was compiled back.
    tid = AllocationCounters.new()
    handler = AllocationCounters.attach!(tid, make_ref(), owner: self())
    on_exit(fn -> AllocationCounters.detach(handler) end)

    for days <- 1..10 do
      assert {:ok, :resolved, %Resolution{}, _budget} =
               Unknown.route(@class, %{"days" => days},
                 budget: budget(1),
                 resolver: {:llm, llm_resolver()}
               )
    end

    assert AllocationCounters.allocation(tid, @class, :llm) == 10
    assert AllocationCounters.allocation(tid, @class, :machinery) == 0
  end

  # --------------------------------------------------------------------
  # Compile-back is gated, and registration is changelogged
  # --------------------------------------------------------------------

  test "compile_back/4 refuses anything that did not come through the candidate boundary" do
    {:ok, resolution} =
      LlmBoundary.candidate(Unknown.declare("c", %{}), :llm, %{"answer" => 1})

    promoted = %{resolution | standing: :admitted}

    assert {:error, %{code: :compile_back_requires_candidate, standing: :admitted}} =
             MachineExperience.compile_back(promoted, :rule, fn _ -> {:ok, 1} end)

    granted = %{resolution | authority: :granted}

    assert {:error, %{code: :compile_back_requires_candidate, authority: :granted}} =
             MachineExperience.compile_back(granted, :rule, fn _ -> {:ok, 1} end)

    assert {:error, %{code: :unknown_machinery_kind}} =
             MachineExperience.compile_back(resolution, :vibes, fn _ -> {:ok, 1} end)

    assert {:error, %{code: :machinery_requires_deterministic_function}} =
             MachineExperience.compile_back(resolution, :rule, "just do what I said")

    assert {:error, %{code: :compile_back_requires_resolution}} =
             MachineExperience.compile_back(%{"not" => "a resolution"}, :rule, fn _ ->
               {:ok, 1}
             end)
  end

  test "all four RFC S39 machinery kinds compile back and route deterministically" do
    assert MachineExperience.kinds() == [:rule, :shape, :plan, :generator]

    for kind <- MachineExperience.kinds() do
      class = "kind-#{kind}"

      {:ok, resolution} =
        LlmBoundary.candidate(Unknown.declare(class, %{}), :synthesis, %{"k" => to_string(kind)})

      {:ok, machinery} =
        MachineExperience.compile_back(resolution, kind, fn _subject -> {:ok, kind} end)

      {:ok, store, _changelog} =
        MachineExperience.register(MachineExperience.new_store(), machinery)

      assert {:ok, :machinery, ^kind, _budget} = Unknown.route(class, %{}, machinery: store)
    end
  end

  test "registration produces a real changelog over the deterministic class set" do
    store = MachineExperience.new_store()
    assert MachineExperience.classes(store) == []

    {:ok, first} = LlmBoundary.candidate(Unknown.declare("alpha", %{}), :prover, %{"p" => 1})
    {:ok, m1} = MachineExperience.compile_back(first, :rule, fn _ -> {:ok, :alpha} end)
    {:ok, store, changelog1} = MachineExperience.register(store, m1)

    assert changelog1.added == ["alpha"]
    assert changelog1.unchanged == []

    {:ok, second} = LlmBoundary.candidate(Unknown.declare("beta", %{}), :search, %{"p" => 2})
    {:ok, m2} = MachineExperience.compile_back(second, :plan, fn _ -> {:ok, :beta} end)
    {:ok, store, changelog2} = MachineExperience.register(store, m2)

    assert changelog2.added == ["beta"]
    assert changelog2.unchanged == ["alpha"]
    assert MachineExperience.classes(store) == ["alpha", "beta"]

    # Re-registering an existing class replaces the machinery without
    # widening the deterministic class set.
    {:ok, m1b} = MachineExperience.compile_back(first, :generator, fn _ -> {:ok, :alpha_v2} end)
    {:ok, store, changelog3} = MachineExperience.register(store, m1b)

    assert changelog3.added == []
    assert changelog3.unchanged == ["alpha", "beta"]
    assert {:ok, %Machinery{kind: :generator}} = MachineExperience.fetch(store, "alpha")
    assert {:ok, :machinery, :alpha_v2, _budget} = Unknown.route("alpha", %{}, machinery: store)
  end

  test "a raising compiled-back rule degrades to UNKNOWN rather than escaping the UNKNOWN state" do
    {:ok, resolution} = LlmBoundary.candidate(Unknown.declare("buggy", %{}), :llm, %{"x" => 1})

    {:ok, machinery} =
      MachineExperience.compile_back(resolution, :rule, fn _ -> raise "buggy rule" end)

    {:ok, store, _changelog} =
      MachineExperience.register(MachineExperience.new_store(), machinery)

    assert {:unknown, %Unknown{reason: :no_admitted_machinery}, %{code: :no_resolver}} =
             Unknown.route("buggy", %{"x" => 1}, machinery: store)
  end
end
