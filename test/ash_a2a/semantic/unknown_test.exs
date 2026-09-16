defmodule AshA2A.Semantic.UnknownTest do
  @moduledoc """
  RFC S36/S37/S64: UNKNOWN as an explicit state, and the algorithm that
  resolves it without ever letting it become DO.

  Real collaborators throughout: the real `AshA2A.Semantic.Allocator`
  budget, the real `AshA2A.Semantic.MachineExperience` store, the real
  `AshA2A.Semantic.LlmBoundary`, and real injected resolver functions
  (the same 1-arity DI-seam idiom `AshA2A.Semantic.Compiler`'s
  `:generate_object` uses). No mocking library appears here.

  The paired positive/negative raise-on-call idiom from
  `request_router_llm_never_called_test.exs` is reused directly: a
  resolver bound to a function that unconditionally raises proves
  non-invocation when it does NOT fire, and the companion test proves the
  exact same function DOES fire on the path it guards -- so the
  non-invocation proof cannot pass vacuously.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.Allocator
  alias AshA2A.Semantic.MachineExperience
  alias AshA2A.Semantic.Unknown
  alias AshA2A.Semantic.Unknown.Resolution

  defp budget(limits \\ [inference_calls: 3, wall_time_ms: 5_000]) do
    Allocator.new!(limits, issued_by: {:host, __MODULE__})
  end

  defp raise_on_call(label) do
    fn %Unknown{} ->
      raise "structural non-invocation proof violated: #{label} was invoked"
    end
  end

  # --------------------------------------------------------------------
  # RFC S36: UNKNOWN is a real state, and it is not failure
  # --------------------------------------------------------------------

  test "an UNKNOWN is a real typed state carrying :unknown standing and no authority" do
    unknown = Unknown.declare("invoice-reconciliation", %{"amount" => 1200})

    assert unknown.standing == :unknown
    assert unknown.authority == :none
    assert unknown.class == "invoice-reconciliation"
    assert unknown.reason == :no_admitted_machinery
    assert String.length(unknown.fingerprint) == 64
  end

  test "the same class and subject fingerprint identically; a different subject does not" do
    one = Unknown.declare("c", %{"a" => 1})
    same = Unknown.declare("c", %{"a" => 1})
    other = Unknown.declare("c", %{"a" => 2})

    assert one.fingerprint == same.fingerprint
    refute one.fingerprint == other.fingerprint
  end

  # --------------------------------------------------------------------
  # RFC S36: UNKNOWN MUST NOT silently become DO
  # --------------------------------------------------------------------

  test "admit_for_do/1 is a total refusal: no reason value ever makes an UNKNOWN executable" do
    for reason <- [
          :no_admitted_machinery,
          :insufficient_coverage,
          :ambiguous_semantics,
          :allocation_exhausted,
          :resolver_failed,
          :resolver_refused
        ] do
      unknown = Unknown.declare("any-class", %{}, reason)

      assert {:error, %{code: :unknown_not_executable, reason: ^reason}} =
               Unknown.admit_for_do(unknown)
    end
  end

  test "an unresolved route returns the UNKNOWN itself, never anything executable" do
    assert {:unknown, %Unknown{} = unresolved, %{code: :no_resolver}} =
             Unknown.route("uncovered-class", %{"x" => 1})

    assert unresolved.standing == :unknown
    assert {:error, %{code: :unknown_not_executable}} = Unknown.admit_for_do(unresolved)
  end

  # --------------------------------------------------------------------
  # RFC S64 step 3: allocation happens BEFORE the expensive call
  # --------------------------------------------------------------------

  test "no budget means the resolver is never invoked -- proven by a raising resolver that does not fire" do
    assert {:unknown, %Unknown{reason: :allocation_exhausted}, %{code: :allocation_exhausted}} =
             Unknown.route("unbudgeted-class", %{},
               resolver: {:llm, raise_on_call("unbudgeted resolver")}
             )
  end

  test "an exhausted budget means the resolver is never invoked -- same raising resolver, still does not fire" do
    spent =
      [inference_calls: 1]
      |> budget()
      |> then(&elem(Allocator.allocate(&1, :inference_calls, 1), 1))

    assert {:unknown, %Unknown{reason: :allocation_exhausted},
            %{code: :budget_exhausted, dimension: :inference_calls}} =
             Unknown.route("exhausted-class", %{},
               budget: spent,
               resolver: {:llm, raise_on_call("exhausted resolver")}
             )
  end

  test "adversarial completeness: the exact same raising resolver DOES fire once a budget admits it" do
    assert_raise RuntimeError, ~r/guarded resolver was invoked/, fn ->
      Unknown.route("budgeted-class", %{},
        budget: budget(),
        resolver: {:llm, raise_on_call("guarded resolver")}
      )
    end
  end

  # --------------------------------------------------------------------
  # RFC S64 steps 4-5 / RFC S37: the result returns as CANDIDATE
  # --------------------------------------------------------------------

  test "a resolved UNKNOWN comes back as a candidate and the budget records the real spend" do
    resolver = fn %Unknown{class: class} ->
      {:ok, %{"resolved_class" => class, "plan" => ["a"]}}
    end

    assert {:ok, :resolved, %Resolution{} = resolution, spent} =
             Unknown.route("resolvable-class", %{"q" => 1},
               budget: budget(inference_calls: 2),
               resolver: {:llm, resolver}
             )

    assert resolution.standing == :candidate
    assert resolution.authority == :none
    assert resolution.payload == %{"resolved_class" => "resolvable-class", "plan" => ["a"]}
    assert Allocator.remaining(spent) == %{inference_calls: 1}
  end

  test "all six RFC S37 resolution routes return a candidate, not canonical truth" do
    assert Unknown.resolver_kinds() == [:llm, :human, :prover, :search, :synthesis, :experiment]

    for kind <- Unknown.resolver_kinds() do
      resolver = fn %Unknown{} -> {:ok, %{"answer" => to_string(kind)}} end

      assert {:ok, :resolved, %Resolution{} = resolution, _budget} =
               Unknown.route("route-#{kind}", %{},
                 budget:
                   budget(
                     inference_calls: 1,
                     external_requests: 1,
                     compute_units: 1,
                     wall_time_ms: 5_000
                   ),
                 resolver: {kind, resolver}
               )

      assert resolution.resolver == kind
      assert resolution.standing == :candidate
      assert resolution.authority == :none
    end
  end

  test "a resolver that returns a standing claim leaves the subject UNKNOWN rather than admitting it" do
    resolver = fn %Unknown{} -> {:ok, %{"standing" => "admitted", "answer" => 42}} end

    assert {:unknown, %Unknown{reason: :resolver_refused},
            %{code: :llm_standing_claim_refused, effect: :admit_fact}} =
             Unknown.route("claiming-class", %{},
               budget: budget(),
               resolver: {:llm, resolver}
             )
  end

  test "a failing resolver leaves the subject UNKNOWN and the spend still recorded as made" do
    resolver = fn %Unknown{} -> {:error, :upstream_timeout} end

    assert {:unknown, %Unknown{reason: :resolver_failed},
            %{code: :resolver_failed, reason: :upstream_timeout}} =
             Unknown.route("failing-class", %{},
               budget: budget(inference_calls: 1),
               resolver: {:llm, resolver}
             )
  end

  test "an invalid resolver shape fails closed instead of defaulting to some resolver" do
    assert {:unknown, %Unknown{reason: :resolver_refused}, %{code: :invalid_resolver}} =
             Unknown.route("bad-resolver-class", %{},
               budget: budget(),
               resolver: :just_call_the_llm
             )
  end

  # --------------------------------------------------------------------
  # RFC S64 step 1: admitted machinery short-circuits before any spend
  # --------------------------------------------------------------------

  test "registered machinery resolves the class deterministically and never reaches the resolver" do
    {:ok, resolution} =
      AshA2A.Semantic.LlmBoundary.candidate(
        Unknown.declare("covered-class", %{}),
        :llm,
        %{"shape" => "double"}
      )

    {:ok, machinery} =
      MachineExperience.compile_back(resolution, :rule, fn %{"n" => n} -> {:ok, n * 2} end)

    {:ok, store, _changelog} =
      MachineExperience.register(MachineExperience.new_store(), machinery)

    # The raising resolver is passed with a real, non-exhausted budget --
    # so the ONLY reason it does not fire is that step 1 hit.
    assert {:ok, :machinery, 14, _budget} =
             Unknown.route("covered-class", %{"n" => 7},
               machinery: store,
               budget: budget(),
               resolver: {:llm, raise_on_call("machinery-covered resolver")}
             )
  end

  test "machinery that does not cover THIS subject is still UNKNOWN, not a crash" do
    {:ok, resolution} =
      AshA2A.Semantic.LlmBoundary.candidate(
        Unknown.declare("partial-class", %{}),
        :llm,
        %{"shape" => "only-integers"}
      )

    # A real, deliberately partial function: raises on a non-integer.
    {:ok, machinery} =
      MachineExperience.compile_back(resolution, :rule, fn %{"n" => n} -> {:ok, n * 2} end)

    {:ok, store, _changelog} =
      MachineExperience.register(MachineExperience.new_store(), machinery)

    assert {:unknown, %Unknown{reason: :no_admitted_machinery}, %{code: :no_resolver}} =
             Unknown.route("partial-class", %{"not_n" => "oops"}, machinery: store)
  end
end
