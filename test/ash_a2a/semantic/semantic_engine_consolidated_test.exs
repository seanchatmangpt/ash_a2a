# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: Semantic Engine & Falsifier Suite
# Target: test/ash_a2a/semantic/semantic_engine_consolidated_test.exs
# Consolidated by Worker 17 from 19 source files:
#   - test/ash_a2a/semantic/allocator_test.exs
#   - test/ash_a2a/semantic/bounded_production_test.exs
#   - test/ash_a2a/semantic/canonical_graph_test.exs
#   - test/ash_a2a/semantic/canonical_graph_three_way_agreement_test.exs
#   - test/ash_a2a/semantic/engine/ash_graphlaw_test.exs
#   - test/ash_a2a/semantic/falsifier_sparql_oracle_test.exs
#   - test/ash_a2a/semantic/falsifier_suite_test.exs
#   - test/ash_a2a/semantic/interchange_contract_test.exs
#   - test/ash_a2a/semantic/llm_boundary_falsifiers_test.exs
#   - test/ash_a2a/semantic/machine_experience_planning_seam_test.exs
#   - test/ash_a2a/semantic/machine_experience_test.exs
#   - test/ash_a2a/semantic/meta_admission_test.exs
#   - test/ash_a2a/semantic/package_store_bounds_test.exs
#   - test/ash_a2a/semantic/peer_capability_reconciliation_test.exs
#   - test/ash_a2a/semantic/policy_phenotype_benchmark_test.exs
#   - test/ash_a2a/semantic/root_manifest_test.exs
#   - test/ash_a2a/semantic/sa_namespace_test.exs
#   - test/ash_a2a/semantic/standing_ledger_key_test.exs
#   - test/ash_a2a/semantic/unknown_test.exs
# ==============================================================================

# --- SECTION 1: Original test/ash_a2a/semantic/allocator_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.AllocatorTest do
  @moduledoc """
  RFC S38 (the CMCA allocation boundary) and RFC S73 (a model must not
  grant itself additional budget).

  Every assertion below is on a real returned budget struct or a real
  returned refusal map -- real state, never an interaction claim.
  """

  use ExUnit.Case, async: true

  alias AshA2A.{Authority, Identity}
  alias AshA2A.Semantic.Allocator
  alias AshA2A.Semantic.Allocator.Budget

  # --------------------------------------------------------------------
  # RFC S38: a real bounded budget
  # --------------------------------------------------------------------

  test "a budget is bounded in every declared dimension and spends down for real" do
    {:ok, budget} =
      Allocator.new([inference_calls: 2, tokens: 1_000], issued_by: {:host, __MODULE__})

    assert Allocator.remaining(budget) == %{inference_calls: 2, tokens: 1_000}

    {:ok, budget} = Allocator.allocate(budget, :inference_calls, 1)
    {:ok, budget} = Allocator.allocate(budget, :tokens, 400)

    assert Allocator.remaining(budget) == %{inference_calls: 1, tokens: 600}
    assert budget.consumed == %{inference_calls: 1, tokens: 400}
  end

  test "exceeding a ceiling is refused with the real limit, consumed, and requested amounts" do
    budget = Allocator.new!([inference_calls: 2], issued_by: {:host, __MODULE__})
    {:ok, budget} = Allocator.allocate(budget, :inference_calls, 2)

    assert {:error,
            %{
              code: :budget_exhausted,
              dimension: :inference_calls,
              limit: 2,
              consumed: 2,
              requested: 1
            }} = Allocator.allocate(budget, :inference_calls, 1)
  end

  test "an unbudgeted dimension is a zero ceiling, never an unlimited one" do
    budget = Allocator.new!([inference_calls: 5], issued_by: {:host, __MODULE__})

    assert {:error, %{code: :dimension_not_budgeted, dimension: :money_micros}} =
             Allocator.allocate(budget, :money_micros, 1)
  end

  test "a negative allocation (a budget increase in disguise) is refused" do
    budget = Allocator.new!([tokens: 100], issued_by: {:host, __MODULE__})
    {:ok, budget} = Allocator.allocate(budget, :tokens, 50)

    assert {:error, %{code: :invalid_allocation_amount, requested: -50}} =
             Allocator.allocate(budget, :tokens, -50)

    assert Allocator.remaining(budget) == %{tokens: 50}
  end

  test "an unbounded budget is not representable: empty and non-integer limits are both refused" do
    assert {:error, %{code: :empty_budget}} = Allocator.new([], issued_by: {:host, :x})

    assert {:error, %{code: :invalid_budget_limits}} =
             Allocator.new([inference_calls: :unlimited], issued_by: {:host, :x})

    assert {:error, %{code: :invalid_budget_limits}} =
             Allocator.new([inference_calls: -1], issued_by: {:host, :x})

    assert {:error, %{code: :invalid_budget_limits}} =
             Allocator.new([not_a_dimension: 5], issued_by: {:host, :x})
  end

  test "wall time is measured from the real monotonic clock, not reported by the caller" do
    past = System.monotonic_time(:millisecond) - 5_000

    budget =
      Allocator.new!([inference_calls: 10, wall_time_ms: 10],
        issued_by: {:host, __MODULE__},
        started_at_ms: past
      )

    assert {:error, %{code: :budget_exhausted, dimension: :wall_time_ms, limit: 10}} =
             Allocator.check_wall_time(budget)

    # And every allocation re-checks it, so a slow resolver cannot spend
    # more simply by not allocating against wall time.
    assert {:error, %{code: :budget_exhausted, dimension: :wall_time_ms}} =
             Allocator.allocate(budget, :inference_calls, 1)
  end

  # --------------------------------------------------------------------
  # RFC S73: NeedMoreResources does NOT imply GrantMoreResources
  # --------------------------------------------------------------------

  test "RFC S73: request_increase/2 always refuses -- there is no success clause to reach" do
    budget = Allocator.new!([inference_calls: 1], issued_by: {:host, __MODULE__})
    {:ok, spent} = Allocator.allocate(budget, :inference_calls, 1)

    # The realistic shape: the model just ran out and is asking for more.
    for request <- [
          %{"reason" => "previous allocation was insufficient", "inference_calls" => 10},
          %{"tokens" => 1_000_000},
          %{"money_micros" => 500_000},
          %{"agents" => 5},
          %{"tools" => 3},
          %{"compute_units" => 99},
          %{"authority" => "admin"}
        ] do
      assert {:error, %{code: :self_grant_refused, requested: ^request}} =
               Allocator.request_increase(spent, request)
    end

    # The budget is genuinely unchanged by having been asked.
    assert Allocator.remaining(spent) == %{inference_calls: 0}
  end

  test "RFC S73: authority is not a budget dimension -- no amount of budget buys it" do
    budget = Allocator.new!(Enum.map(Allocator.dimensions(), &{&1, 1_000_000}))

    refute :authority in Allocator.dimensions()

    assert {:error, %{code: :authority_not_allocatable}} =
             Allocator.allocate(budget, :authority, 1)

    assert {:error, %{code: :authority_not_allocatable}} =
             Allocator.allocate(budget, :authority, 0)
  end

  test "RFC S73: a model may not issue its own budget" do
    assert {:error, %{code: :model_issued_budget_refused}} =
             Allocator.new([inference_calls: 1], issued_by: {:model, "gpt-whatever"})

    model_authority =
      Authority.new(Identity.principal("some-model"), "AshA2A.Test.Fixture.Item.create",
        source: :model
      )

    assert {:error, %{code: :model_issued_budget_refused}} =
             Allocator.new([inference_calls: 1], issued_by: model_authority)

    assert {:error, %{code: :invalid_budget_issuer}} =
             Allocator.new([inference_calls: 1], issued_by: "trust me")
  end

  test "reissue/3 is the only way to more budget, and it requires a real non-model issuer" do
    budget = Allocator.new!([inference_calls: 1], issued_by: {:host, __MODULE__})
    {:ok, spent} = Allocator.allocate(budget, :inference_calls, 1)

    assert {:error, %{code: :model_issued_budget_refused}} =
             Allocator.reissue(spent, {:model, "the model"}, inference_calls: 100)

    broker_authority =
      Authority.new(Identity.principal("ops-human"), "AshA2A.Test.Fixture.Item.create",
        source: :authority_broker
      )

    assert {:ok, reissued} =
             Allocator.reissue(spent, broker_authority, inference_calls: 5)

    # Consumed carries forward: reissue never launders past spend.
    assert reissued.consumed == %{inference_calls: 1}
    assert Allocator.remaining(reissued) == %{inference_calls: 4}
  end

  test "a reissue that would retroactively put the budget over its own new ceiling is refused" do
    budget = Allocator.new!([tokens: 100], issued_by: {:host, __MODULE__})
    {:ok, spent} = Allocator.allocate(budget, :tokens, 90)

    assert {:error, %{code: :reissue_below_consumed, dimensions: %{tokens: 90}}} =
             Allocator.reissue(spent, {:host, __MODULE__}, tokens: 50)

    # Dropping a dimension that has already been spent is the same problem.
    assert {:error, %{code: :reissue_below_consumed}} =
             Allocator.reissue(spent, {:host, __MODULE__}, inference_calls: 5)
  end

  # --------------------------------------------------------------------
  # DEFECT 1 regression (RFC S73): an exhausted budget admitted unlimited
  # calls through an unguarded door.
  #
  # `allocate/3` guarded `is_integer(amount) and amount >= 0` and then
  # tested `consumed + amount > limit`. With `amount == 0` at exhaustion,
  # `1 + 0 > 1` is false, so allocate returned `{:ok, budget}` on a budget
  # with ZERO headroom, unlimited times: the spender set the price of its
  # own calls. The verifier's minimal repro is the 1000-iteration loop
  # below, which admitted 1000 calls against a one-call budget.
  # --------------------------------------------------------------------

  test "S73 regression: a zero-amount call against an exhausted budget is refused, every time" do
    budget = Allocator.new!([inference_calls: 1], issued_by: {:host, __MODULE__})
    {:ok, spent} = Allocator.allocate(budget, :inference_calls, 1)

    assert Allocator.remaining(spent) == %{inference_calls: 0}

    # The exact verifier repro: 1000 zero-amount calls on zero headroom.
    {final, admitted} =
      Enum.reduce(1..1_000, {spent, 0}, fn _, {budget, admitted} ->
        case Allocator.allocate(budget, :inference_calls, 0) do
          {:ok, next} -> {next, admitted + 1}
          {:error, _} -> {budget, admitted}
        end
      end)

    assert admitted == 0
    assert final.consumed == %{inference_calls: 1}
    assert Allocator.remaining(final) == %{inference_calls: 0}

    assert {:error,
            %{
              code: :budget_exhausted,
              dimension: :inference_calls,
              limit: 1,
              consumed: 1,
              requested: 0,
              charged: 1
            }} = Allocator.allocate(spent, :inference_calls, 0)
  end

  test "S73 regression: a resolver call consumes a real issuer-set minimum, not a spender-set zero" do
    budget = Allocator.new!([inference_calls: 3], issued_by: {:host, __MODULE__})

    # Asking for zero still costs the issuer's minimum.
    assert Allocator.minimum(budget, :inference_calls) == Allocator.default_minimum()
    {:ok, after_one} = Allocator.allocate(budget, :inference_calls, 0)
    assert after_one.consumed == %{inference_calls: 1}

    # So a three-call budget affords exactly three zero-amount calls.
    {:ok, after_two} = Allocator.allocate(after_one, :inference_calls, 0)
    {:ok, after_three} = Allocator.allocate(after_two, :inference_calls, 0)
    assert after_three.consumed == %{inference_calls: 3}

    assert {:error, %{code: :budget_exhausted, charged: 1}} =
             Allocator.allocate(after_three, :inference_calls, 0)
  end

  test "S73 regression: the minimum is ISSUER-set and cannot be priced down to zero" do
    {:ok, budget} =
      Allocator.new([tokens: 100],
        issued_by: {:host, __MODULE__},
        minimums: %{tokens: 25}
      )

    assert Allocator.minimum(budget, :tokens) == 25

    # A request below the issuer's minimum is charged the minimum.
    {:ok, spent} = Allocator.allocate(budget, :tokens, 1)
    assert spent.consumed == %{tokens: 25}

    # A request above it is charged what it asked for.
    {:ok, spent} = Allocator.allocate(spent, :tokens, 40)
    assert spent.consumed == %{tokens: 65}

    # And a minimum of zero is simply not representable.
    assert {:error, %{code: :invalid_budget_minimums, invalid: %{tokens: 0}}} =
             Allocator.new([tokens: 100], issued_by: {:host, :x}, minimums: %{tokens: 0})

    assert {:error, %{code: :invalid_budget_minimums}} =
             Allocator.new([tokens: 100], issued_by: {:host, :x}, minimums: %{tokens: -1})

    assert {:error, %{code: :invalid_budget_minimums}} =
             Allocator.new([tokens: 100], issued_by: {:host, :x}, minimums: %{not_a_dim: 5})
  end

  test "S73 regression: a zero-limit dimension affords nothing at all, including a zero request" do
    budget = Allocator.new!([inference_calls: 0], issued_by: {:host, __MODULE__})

    assert {:error, %{code: :budget_exhausted, limit: 0, consumed: 0, charged: 1}} =
             Allocator.allocate(budget, :inference_calls, 0)

    assert {:error, %{code: :budget_exhausted}} = Allocator.allocate(budget, :inference_calls, 1)
  end

  test "S73 regression: reissue carries the issuer's minimums forward and never lowers them" do
    {:ok, budget} =
      Allocator.new([tokens: 100], issued_by: {:host, __MODULE__}, minimums: %{tokens: 10})

    {:ok, spent} = Allocator.allocate(budget, :tokens, 0)
    assert spent.consumed == %{tokens: 10}

    {:ok, reissued} = Allocator.reissue(spent, {:host, :ops}, tokens: 200)
    assert Allocator.minimum(reissued, :tokens) == 10
    assert reissued.consumed == %{tokens: 10}

    # A new issuer may set new minimums, but still not a zero one.
    assert {:ok, tightened} =
             Allocator.reissue(spent, {:host, :ops}, [tokens: 200], minimums: %{tokens: 50})

    assert Allocator.minimum(tightened, :tokens) == 50

    assert {:error, %{code: :invalid_budget_minimums}} =
             Allocator.reissue(spent, {:host, :ops}, [tokens: 200], minimums: %{tokens: 0})
  end

  test "the budget fingerprint moves with real spend and is stable for identical state" do
    a = Allocator.new!([tokens: 10], issued_by: {:host, :same})
    b = Allocator.new!([tokens: 10], issued_by: {:host, :same})

    assert a.fingerprint == b.fingerprint

    {:ok, spent} = Allocator.allocate(a, :tokens, 3)
    refute spent.fingerprint == a.fingerprint

    assert %Budget{} = spent
  end
end

# --- SECTION 2: Original test/ash_a2a/semantic/bounded_production_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.BoundedProductionTest do
  @moduledoc """
  RFC S72: a production operation MUST NOT require solving an
  unrestricted "continue reasoning until you believe you are done".

  The proofs here are executed, not described: the refusal tests drive
  real specs through the real `contract/2`, and the termination tests run
  the real bounded executor -- including against a predicate that is
  never satisfiable, which halts at the real step bound instead of
  looping.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.BoundedProduction

  # --------------------------------------------------------------------
  # The RFC S72 refusal
  # --------------------------------------------------------------------

  test "every named 'until you believe you are done' termination is refused by name" do
    assert BoundedProduction.unbounded_terminations() == [
             :model_judgment,
             :until_done,
             :until_believed_complete,
             :until_satisfied,
             :none,
             nil
           ]

    for termination <- BoundedProduction.unbounded_terminations() do
      assert {:error, %{code: :unbounded_production_operation, termination: ^termination}} =
               BoundedProduction.contract("reconcile-ledger",
                 max_steps: 100,
                 max_wall_time_ms: 1_000,
                 termination: termination
               )
    end
  end

  test "a prose description of when to stop is not a termination predicate" do
    assert {:error, %{code: :unbounded_production_operation}} =
             BoundedProduction.contract("reconcile-ledger",
               max_steps: 100,
               max_wall_time_ms: 1_000,
               termination: "keep going until the ledger looks right"
             )

    # Arity matters: a 0-arity function cannot decide anything about state.
    assert {:error, %{code: :unbounded_production_operation}} =
             BoundedProduction.contract("reconcile-ledger",
               max_steps: 100,
               max_wall_time_ms: 1_000,
               termination: fn -> true end
             )
  end

  test "an absent or non-positive bound is not a bound" do
    predicate = fn state -> state >= 3 end

    assert {:error, %{code: :unbounded_production_operation, bound: :max_steps, value: nil}} =
             BoundedProduction.contract("op", max_wall_time_ms: 1_000, termination: predicate)

    assert {:error, %{code: :unbounded_production_operation, bound: :max_wall_time_ms}} =
             BoundedProduction.contract("op", max_steps: 10, termination: predicate)

    assert {:error, %{code: :unbounded_production_operation, bound: :max_steps, value: 0}} =
             BoundedProduction.contract("op",
               max_steps: 0,
               max_wall_time_ms: 1_000,
               termination: predicate
             )
  end

  # --------------------------------------------------------------------
  # The bounded contract, admitted and executed
  # --------------------------------------------------------------------

  test "known production work reduces to a bounded contract that really terminates" do
    assert {:ok, contract} =
             BoundedProduction.contract("count-to-five",
               max_steps: 10,
               max_wall_time_ms: 1_000,
               termination: fn state -> state >= 5 end
             )

    assert contract.max_steps == 10
    assert String.length(contract.fingerprint) == 64

    assert {:ok, :terminated, 5, 5} = BoundedProduction.run(contract, &(&1 + 1), 0)
  end

  test "a contract whose goal already holds performs zero steps" do
    {:ok, contract} =
      BoundedProduction.contract("already-done",
        max_steps: 10,
        max_wall_time_ms: 1_000,
        termination: fn state -> state >= 5 end
      )

    assert {:ok, :terminated, 7, 0} = BoundedProduction.run(contract, &(&1 + 1), 7)
  end

  test "an unsatisfiable predicate still halts, at the real step bound, and says so" do
    # This is the executed form of the RFC S72 guarantee: even an
    # operation whose completion condition never becomes true terminates
    # decidably from outside, rather than running until something
    # "believes it is done".
    {:ok, contract} =
      BoundedProduction.contract("never-satisfied",
        max_steps: 25,
        max_wall_time_ms: 5_000,
        termination: fn _state -> false end
      )

    assert {:error,
            %{
              code: :bound_reached,
              bound: :max_steps,
              operation: "never-satisfied",
              limit: 25,
              steps: 25
            }} = BoundedProduction.run(contract, &(&1 + 1), 0)
  end

  test "the wall-clock bound halts a slow operation whose step count is nowhere near its ceiling" do
    {:ok, contract} =
      BoundedProduction.contract("slow-op",
        max_steps: 1_000_000,
        max_wall_time_ms: 20,
        termination: fn _state -> false end
      )

    assert {:error, %{code: :bound_reached, bound: :max_wall_time_ms, limit: 20, steps: steps}} =
             BoundedProduction.run(
               contract,
               fn state ->
                 Process.sleep(5)
                 state + 1
               end,
               0
             )

    # The real proof that wall time, not the step ceiling, stopped it.
    assert steps < 1_000_000
  end

  test "two contracts over the same real bounds fingerprint identically; different bounds do not" do
    predicate = fn state -> state end

    {:ok, a} =
      BoundedProduction.contract("op", max_steps: 5, max_wall_time_ms: 10, termination: predicate)

    {:ok, b} =
      BoundedProduction.contract("op", max_steps: 5, max_wall_time_ms: 10, termination: predicate)

    {:ok, c} =
      BoundedProduction.contract("op", max_steps: 6, max_wall_time_ms: 10, termination: predicate)

    assert a.fingerprint == b.fingerprint
    refute a.fingerprint == c.fingerprint
  end
end

# --- SECTION 3: Original test/ash_a2a/semantic/canonical_graph_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.CanonicalGraphTest do
  @moduledoc """
  Real RFC S12 canonical graph identity contract, exercised against the real
  `:rdf` (RDF.ex 3.0.1) canonicalizer -- no doubles of any kind.

  Every fixture in this module is a minimal reproducing input from the
  adversarial verification of the v26.9.16 SA2A branches. Each one reproduced a
  real defect in the praxis-graphlaw wasm `graph_hash` export that three
  branches nonetheless described as RDFC-1.0 / S12-conformant. These tests pin
  the corrected behaviour so the false claim cannot silently return.

  The measured GraphLaw digests those fixtures produce are recorded in
  `docs/explanation/canonical-graph-identity.md` and asserted, where the
  vendored wasm law package is available, in
  `AshA2A.Semantic.CanonicalGraphThreeWayAgreementTest`.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.CanonicalGraph

  doctest AshA2A.Semantic.CanonicalGraph

  # The three vendored graphlaw fixtures, verbatim.
  @base "@prefix ex: <http://example.org/> .\nex:a ex:p ex:b .\nex:b ex:p ex:c .\n"
  @reordered "@prefix zz: <http://example.org/> .\nzz:b zz:p zz:c .\nzz:a zz:p zz:b .\n"
  @mutated "@prefix ex: <http://example.org/> .\nex:a ex:p ex:b .\nex:b ex:p ex:ZZZ .\n"

  # The verifier's blank-node relabeling pair: the same graph, differing only
  # in the *name* of its one blank node.
  @blank_b1 "@prefix ex: <http://example.org/> .\nex:a ex:p _:b1 .\n_:b1 ex:p ex:c .\n"
  @blank_zzz9 "@prefix ex: <http://example.org/> .\nex:a ex:p _:zzz9 .\n_:zzz9 ex:p ex:c .\n"

  # Real measured values (RDF.ex 3.0.1, RDFC-1.0 + SHA-256 over sorted N-Quads).
  @digest_base "09be9b797c5854a65e9568cbfeb7a9435e8ce690bb8c67a299ac7e7c3b4e2efa"
  @digest_mutated "dff591ad4525e7884f91a8ddc118890d55c17f1acd1155eaa8e3414ed3a21e34"
  @digest_blank "3c2f833bf34d489b97894abd575e4a8ac8d6b89564ee074ed45492402f278e5c"
  @digest_empty "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  describe "canonical_digest/1 invariance" do
    test "is invariant under prefix relabeling and triple reordering" do
      assert {:ok, @digest_base} = CanonicalGraph.canonical_digest(@base)
      assert {:ok, @digest_base} = CanonicalGraph.canonical_digest(@reordered)
    end

    test "is invariant under blank-node relabeling -- the graphlaw defect this corrects" do
      # praxis-graphlaw v26.7.5 graph_hash gives these two DIFFERENT digests
      # (98d6f0bb... and fa6b931d...). RDFC-1.0 gives one digest, because they
      # are the same graph.
      assert {:ok, @digest_blank} = CanonicalGraph.canonical_digest(@blank_b1)
      assert {:ok, @digest_blank} = CanonicalGraph.canonical_digest(@blank_zzz9)

      assert CanonicalGraph.canonical_digest(@blank_b1) ==
               CanonicalGraph.canonical_digest(@blank_zzz9)
    end

    test "discriminates a genuinely different graph" do
      assert {:ok, @digest_mutated} = CanonicalGraph.canonical_digest(@mutated)
      refute @digest_mutated == @digest_base
    end

    test "accepts an already-parsed RDF.Graph and agrees with the Turtle form" do
      {:ok, graph} = CanonicalGraph.parse(@base)
      assert %RDF.Graph{} = graph
      assert {:ok, @digest_base} = CanonicalGraph.canonical_digest(graph)
    end
  end

  describe "canonical_digest/1 fails closed" do
    test "unparseable input is a typed error, NOT the empty-graph digest" do
      # This is the second graphlaw defect: graph_hash("@@@ not turtle")
      # returns graph_hash("") -- the BLAKE3 empty digest af1349b9... -- so a
      # garbage document and an empty document are indistinguishable.
      assert {:error, {:parse_error, message}} =
               CanonicalGraph.canonical_digest("@@@ not turtle")

      assert message =~ "Turtle scanner error"

      # And the empty graph still has its own real, distinct digest.
      assert {:ok, @digest_empty} = CanonicalGraph.canonical_digest("")
      refute {:ok, @digest_empty} == CanonicalGraph.canonical_digest("@@@ not turtle")
    end

    test "a lone 0xFF byte is refused before any parser sees it" do
      # The verifier's minimal reproducing input for the wasm marshalling
      # defect: the wasm bridge's graph_hash/3 (on its branch
      # AshA2A.GraphLaw.Wasm, merged as AshA2A.GraphLaw.WasmexHost) guarded
      # only is_binary/1, but the Rust export takes a &str, and this single
      # byte makes the engine commit 2,148,270,080 bytes and permanently
      # poison the instance.
      assert {:error, {:invalid_encoding, 0}} = CanonicalGraph.canonical_digest(<<0xFF>>)
    end

    test "an invalid byte inside otherwise valid Turtle is refused, at its real offset" do
      poisoned = @base <> <<0xFF>>

      assert {:error, {:invalid_encoding, offset}} = CanonicalGraph.canonical_digest(poisoned)
      assert offset == byte_size(@base)
    end

    test "a non-binary, non-graph term is refused rather than coerced" do
      assert {:error, {:unsupported_input, _}} = CanonicalGraph.canonical_digest(:not_a_graph)
      assert {:error, {:unsupported_input, _}} = CanonicalGraph.canonical_digest(%{a: 1})
    end

    test "ensure_utf8/1 reports the offset of the first invalid byte" do
      assert :ok = CanonicalGraph.ensure_utf8(@base)
      assert :ok = CanonicalGraph.ensure_utf8("ünïcödé is fine")
      assert {:error, {:invalid_encoding, 0}} = CanonicalGraph.ensure_utf8(<<0xFF>>)
      assert {:error, {:invalid_encoding, 2}} = CanonicalGraph.ensure_utf8(<<"ok", 0xFF>>)
      # "héllo" is 6 bytes, not 5 -- the offset is a real byte offset, not a
      # grapheme index, which is exactly what a wasm &str marshaller needs.
      assert 6 == byte_size("héllo")

      assert {:error, {:invalid_encoding, 6}} =
               CanonicalGraph.ensure_utf8(<<"héllo"::utf8, 0xC0>>)
    end

    test "the wasm host's encoding guard is this guard (one implementation, not a port)" do
      # Merge reconciliation: AshA2A.GraphLaw.WasmexHost.ensure_utf8/1 used to
      # carry its own ported byte-offset scanner; it now delegates here. Pin
      # that the two agree on every class of input, including a truncated
      # multi-byte sequence, an overlong encoding and a lone continuation byte.
      inputs = [
        "",
        @base,
        "ünïcödé is fine",
        <<0xFF>>,
        <<"ok", 0xFF>>,
        <<"héllo"::utf8, 0xC0>>,
        <<"ab", 0xE2, 0x82>>,
        <<0xC0, 0xAF>>,
        <<"x", 0x80, "y">>
      ]

      for input <- inputs do
        assert AshA2A.GraphLaw.WasmexHost.ensure_utf8(input) ==
                 CanonicalGraph.ensure_utf8(input),
               "guards disagree on #{inspect(input)}"
      end

      assert {:error, {:invalid_encoding, 2}} =
               AshA2A.GraphLaw.WasmexHost.ensure_utf8(<<"ab", 0xE2, 0x82>>)
    end

    test "canonical_digest!/1 raises with the typed reason instead of returning a digest" do
      assert @digest_base == CanonicalGraph.canonical_digest!(@base)

      assert_raise ArgumentError, ~r/not valid UTF-8 \(first invalid byte at offset 0\)/, fn ->
        CanonicalGraph.canonical_digest!(<<0xFF>>)
      end

      assert_raise ArgumentError, ~r/not well-formed Turtle/, fn ->
        CanonicalGraph.canonical_digest!("@@@ not turtle")
      end
    end
  end

  describe "canonical_nquads/1" do
    test "returns the exact byte string the digest is taken over" do
      assert {:ok, nquads} = CanonicalGraph.canonical_nquads(@base)

      assert nquads ==
               "<http://example.org/a> <http://example.org/p> <http://example.org/b> .\n" <>
                 "<http://example.org/b> <http://example.org/p> <http://example.org/c> .\n"

      assert @digest_base ==
               :sha256 |> :crypto.hash(nquads) |> Base.encode16(case: :lower)
    end

    test "relabels blank nodes to canonical c14n identifiers" do
      assert {:ok, nquads} = CanonicalGraph.canonical_nquads(@blank_b1)

      assert nquads ==
               "<http://example.org/a> <http://example.org/p> _:c14n0 .\n" <>
                 "_:c14n0 <http://example.org/p> <http://example.org/c> .\n"

      # Byte-identical for the relabeled variant -- this is what makes
      # feeding canonical N-Quads to a second engine meaningful.
      assert CanonicalGraph.canonical_nquads(@blank_b1) ==
               CanonicalGraph.canonical_nquads(@blank_zzz9)
    end

    test "fails closed on the same inputs canonical_digest/1 refuses" do
      assert {:error, {:parse_error, _}} = CanonicalGraph.canonical_nquads("@@@ not turtle")
      assert {:error, {:invalid_encoding, 0}} = CanonicalGraph.canonical_nquads(<<0xFF>>)
    end

    test "canonical N-Quads round-trip to the same digest" do
      {:ok, nquads} = CanonicalGraph.canonical_nquads(@blank_b1)
      assert {:ok, @digest_blank} = CanonicalGraph.canonical_digest(nquads)
    end
  end

  describe "algorithm identity, as pinned by the Root Manifest" do
    test "names the real algorithm and hash function" do
      assert "RDFC-1.0" == CanonicalGraph.algorithm()
      assert "SHA-256" == CanonicalGraph.hash_function()
      assert "application/n-quads; sorted=code-point" == CanonicalGraph.serialization()
      assert "RDFC-1.0/SHA-256/n-quads-sorted" == CanonicalGraph.algorithm_id()
      assert "text/turtle" == CanonicalGraph.input_media_type()
    end

    test "the named hash function is the one actually applied" do
      {:ok, nquads} = CanonicalGraph.canonical_nquads(@mutated)
      {:ok, digest} = CanonicalGraph.canonical_digest(@mutated)

      assert digest == :sha256 |> :crypto.hash(nquads) |> Base.encode16(case: :lower)
    end

    test "the digest is NOT BLAKE3 of the input, which is what graphlaw computes" do
      # graphlaw's graph_hash is BLAKE3 over its own sorted serialization; the
      # empty-graph digests of the two engines are therefore different, and a
      # receipt must say which one it means.
      assert {:ok, @digest_empty} = CanonicalGraph.canonical_digest("")
      graphlaw_empty = "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"
      refute @digest_empty == graphlaw_empty
    end
  end
end

# --- SECTION 4: Original test/ash_a2a/semantic/canonical_graph_three_way_agreement_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.CanonicalGraphThreeWayAgreementTest do
  @moduledoc """
  A real cross-engine conformance artifact: does the vendored praxis-graphlaw
  wasm law package agree with RDF.ex on canonical form?

  The experiment, for a Turtle document `T`:

      A = graphlaw.graph_hash(T)
      B = graphlaw.graph_hash(CanonicalGraph.canonical_nquads(T))

  If `A == B`, graphlaw's own notion of canonical form and RDFC-1.0's agree on
  `T` -- feeding graphlaw the RDFC-1.0 canonical serialization instead of the
  original concrete syntax does not move its digest.

  ## The real, measured answer (praxis-graphlaw v26.7.5, RDF.ex 3.0.1)

  **Blank-node-free graphs: the two engines AGREE.** Both `A` and `B` are
  `9b818096...` for the vendored `base.ttl` fixture.

  **Graphs containing blank nodes: the two engines DIVERGE**, and the
  divergence is informative rather than a failure. `A` is not even well-defined
  for a blank-node graph, because graphlaw's digest depends on the *arbitrary
  names* of the blank nodes (`_:b1` and `_:zzz9` give `98d6f0bb...` and
  `fa6b931d...` for the same graph). `B` is a single value, `37eef97d...`, for
  both -- so pre-canonicalizing with RDF.ex *repairs* graphlaw's blank-node
  non-invariance. `B` is the digest a receipt should carry if it wants a
  graphlaw-side BLAKE3 identity that is actually an identity.

  This is asserted below, in both directions, as the standing record.

  ## Real collaborators only

  This test executes the real vendored wasm law package in a real `node`
  process. It does not stub, fake or simulate graphlaw. The vendored artifact
  (`priv/graphlaw/praxis_graphlaw.wasm`, written by
  `mix ash_a2a.vendor_graphlaw`) and its node host are on `main`, so this
  runs for real there; wherever either (or `node`) is absent the test SKIPS
  visibly, naming what is missing. It never substitutes a double for the
  engine under comparison.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.CanonicalGraph

  @wasm_candidates ["praxis_graphlaw.wasm", "praxis_graphlaw_wasm.wasm"]
  @host_relative "graphlaw/host/graphlaw_host.mjs"

  # Resolved at compile time so the skip reason can be a module tag.
  @priv Path.join(File.cwd!(), "priv")
  @wasm Enum.find_value(@wasm_candidates, fn name ->
          path = Path.join([@priv, "graphlaw", name])
          if File.regular?(path), do: path
        end)
  @host (fn ->
           path = Path.join(@priv, @host_relative)
           if File.regular?(path), do: path
         end).()
  @node System.find_executable("node")

  @missing Enum.reject(
             [
               {@wasm, "priv/graphlaw/{praxis_graphlaw,praxis_graphlaw_wasm}.wasm"},
               {@host, "priv/#{@host_relative}"},
               {@node, "a `node` executable on PATH"}
             ],
             fn {found, _} -> found end
           )

  if @missing != [] do
    @moduletag skip:
                 "graphlaw wasm law package not available on this branch; missing: " <>
                   Enum.map_join(@missing, ", ", &elem(&1, 1)) <>
                   " (vendored by `mix ash_a2a.vendor_graphlaw`)"
  end

  @base "@prefix ex: <http://example.org/> .\nex:a ex:p ex:b .\nex:b ex:p ex:c .\n"
  @reordered "@prefix zz: <http://example.org/> .\nzz:b zz:p zz:c .\nzz:a zz:p zz:b .\n"
  @mutated "@prefix ex: <http://example.org/> .\nex:a ex:p ex:b .\nex:b ex:p ex:ZZZ .\n"
  @blank_b1 "@prefix ex: <http://example.org/> .\nex:a ex:p _:b1 .\n_:b1 ex:p ex:c .\n"
  @blank_zzz9 "@prefix ex: <http://example.org/> .\nex:a ex:p _:zzz9 .\n_:zzz9 ex:p ex:c .\n"

  # Real measured graphlaw v26.7.5 digests (BLAKE3, lowercase hex).
  @gl_base "9b8180962a93910d17c51d029626f393d65ac2f724b9ffc657c90bc4f3b5939d"
  @gl_mutated "610ccbcd4ed4b23cf4179fde360625da286557d18a15403f76797e28c1c68f66"
  @gl_blank_b1 "98d6f0bb8000170baa790b30dc641ce0bd49ca82f7f9c0ce45452c2994e2820e"
  @gl_blank_zzz9 "fa6b931d903050d2837bb557482f1669d8767ad12b1c340e68192a85de873215"
  @gl_blank_canonicalized "37eef97df291cd1de78fc2b5bb9009490cc6be459e57818a9c26c30d58e939bc"
  @gl_empty "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"

  describe "three-way agreement, blank-node-free graphs" do
    test "graphlaw(turtle) == graphlaw(RDFC-1.0 canonical N-Quads)" do
      {:ok, nquads} = CanonicalGraph.canonical_nquads(@base)

      assert [direct, via_canonical] = graph_hash([@base, nquads])

      assert direct == @gl_base
      assert via_canonical == @gl_base
      assert direct == via_canonical
    end

    test "agreement survives prefix relabeling and triple reordering on both sides" do
      {:ok, nquads} = CanonicalGraph.canonical_nquads(@reordered)

      assert [direct, via_canonical] = graph_hash([@reordered, nquads])

      assert direct == @gl_base
      assert via_canonical == @gl_base

      # And RDF.ex reaches the same conclusion about sameness, on its own digest.
      assert CanonicalGraph.canonical_digest(@base) ==
               CanonicalGraph.canonical_digest(@reordered)
    end

    test "both engines still discriminate a genuinely different graph" do
      {:ok, nquads} = CanonicalGraph.canonical_nquads(@mutated)

      assert [direct, via_canonical] = graph_hash([@mutated, nquads])

      assert direct == @gl_mutated
      assert via_canonical == @gl_mutated
      refute direct == @gl_base

      refute CanonicalGraph.canonical_digest(@mutated) ==
               CanonicalGraph.canonical_digest(@base)
    end
  end

  describe "documented divergence, graphs containing blank nodes" do
    test "graphlaw alone is NOT blank-node-relabel invariant" do
      assert [b1, zzz9] = graph_hash([@blank_b1, @blank_zzz9])

      assert b1 == @gl_blank_b1
      assert zzz9 == @gl_blank_zzz9

      # The defect, reproduced against the real engine: same graph, two digests.
      refute b1 == zzz9
    end

    test "pre-canonicalizing with RDF.ex repairs that non-invariance" do
      {:ok, nq_b1} = CanonicalGraph.canonical_nquads(@blank_b1)
      {:ok, nq_zzz9} = CanonicalGraph.canonical_nquads(@blank_zzz9)

      assert nq_b1 == nq_zzz9

      assert [via_b1, via_zzz9] = graph_hash([nq_b1, nq_zzz9])

      assert via_b1 == @gl_blank_canonicalized
      assert via_zzz9 == @gl_blank_canonicalized
      assert via_b1 == via_zzz9
    end

    test "the divergence is real: graphlaw(turtle) != graphlaw(canonical N-Quads)" do
      {:ok, nquads} = CanonicalGraph.canonical_nquads(@blank_b1)

      assert [direct, via_canonical] = graph_hash([@blank_b1, nquads])

      # Recorded honestly. The two engines do NOT agree here, because
      # graphlaw's digest is a function of the blank-node *labels* and
      # RDFC-1.0 rewrites them to _:c14n0.
      refute direct == via_canonical
      assert direct == @gl_blank_b1
      assert via_canonical == @gl_blank_canonicalized
    end
  end

  describe "the graphlaw failure modes this correction exists for" do
    test "graph_hash on unparseable input returns the empty-graph digest, not an error" do
      assert [garbage, empty] = graph_hash(["@@@ not turtle", ""])

      assert garbage == @gl_empty
      assert empty == @gl_empty
      assert garbage == empty

      # RDF.ex, on the identical inputs, distinguishes them and fails closed.
      assert {:error, {:parse_error, _}} = CanonicalGraph.canonical_digest("@@@ not turtle")
      assert {:ok, _} = CanonicalGraph.canonical_digest("")
    end

    test "the two engines use different hash functions, so digests must be labelled" do
      assert [gl_base] = graph_hash([@base])
      {:ok, rdf_base} = CanonicalGraph.canonical_digest(@base)

      assert gl_base == @gl_base
      refute gl_base == rdf_base
    end
  end

  # Executes the real vendored wasm law package via the real dependency-free
  # node host, once per call, and returns the results in order.
  defp graph_hash(inputs) when is_list(inputs) do
    Enum.each(inputs, fn input -> assert :ok = CanonicalGraph.ensure_utf8(input) end)

    request =
      Jason.encode!(%{
        "wasm" => @wasm,
        "calls" => Enum.map(inputs, &%{"fn" => "graph_hash", "args" => [&1]})
      })

    path = Path.join(System.tmp_dir!(), "graphlaw_req_#{System.unique_integer([:positive])}.json")
    File.write!(path, request)

    try do
      {out, status} = System.cmd(@node, [@host, path], stderr_to_stdout: true)
      assert status == 0, "graphlaw host exited #{status}: #{out}"

      assert %{"ok" => true, "results" => results} = Jason.decode!(out)
      assert length(results) == length(inputs)
      results
    after
      File.rm(path)
    end
  end
end

# --- SECTION 5: Original test/ash_a2a/semantic/engine/ash_graphlaw_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.Engine.AshGraphLawTest do
  use ExUnit.Case, async: false

  alias AshA2A.Semantic.Conformance
  alias AshA2A.Semantic.Engine.AshGraphLaw, as: Engine

  describe "AshA2A.Semantic.Engine.AshGraphLaw conformance surface" do
    test "exports all five RFC engine capability functions" do
      assert function_exported?(Engine, :validate_shex, 3)
      assert function_exported?(Engine, :validate_shacl, 2)
      assert function_exported?(Engine, :query_sparql, 2)
      assert function_exported?(Engine, :datalog_closure, 2)
      assert function_exported?(Engine, :n3_closure, 2)
    end

    test "AshA2A.Semantic.Conformance.engine_capability/2 returns :met for all capabilities" do
      assert Conformance.engine_capability(:validate_shex, 3) == :met
      assert Conformance.engine_capability(:validate_shacl, 2) == :met
      assert Conformance.engine_capability(:query_sparql, 2) == :met
      assert Conformance.engine_capability(:datalog_closure, 2) == :met
      assert Conformance.engine_capability(:n3_closure, 2) == :met
    end

    test "available?/0 returns true when AshGraphLaw is live" do
      assert Engine.available?() == true
    end

    test "version/0 returns release string" do
      assert {:ok, version} = Engine.version()
      assert byte_size(version) > 0
    end

    test "validate_shacl/2 executes against real engine" do
      data = """
      @prefix ex: <http://example.org/> .
      @prefix foaf: <http://xmlns.com/foaf/0.1/> .
      ex:alice a foaf:Person ;
               foaf:name "Alice" .
      """

      shapes = """
      @prefix sh: <http://www.w3.org/ns/shacl#> .
      @prefix foaf: <http://xmlns.com/foaf/0.1/> .
      @prefix ex: <http://example.org/> .

      ex:PersonShape a sh:NodeShape ;
          sh:targetClass foaf:Person ;
          sh:property [
              sh:path foaf:name ;
              sh:minCount 1 ;
          ] .
      """

      assert {:ok, res} = Engine.validate_shacl(data, shapes)
      assert res.conforms == true
    end

    test "query_sparql/2 executes against real engine" do
      data = """
      @prefix ex: <http://example.org/> .
      ex:bob ex:greeting "hello" .
      """

      query = """
      SELECT ?greeting WHERE {
        ?s <http://example.org/greeting> ?greeting .
      }
      """

      assert {:ok, %AshGraphLaw.Result.Sparql{} = res} = Engine.query_sparql(data, query)
      assert is_list(res.rows)
      assert length(res.rows) == 1
    end
  end
end

# --- SECTION 6: Original test/ash_a2a/semantic/falsifier_sparql_oracle_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.FalsifierSparqlOracleTest do
  @moduledoc """
  Holds every falsifier's **normative** SPARQL 1.1 `ASK` to agreement with the
  structural evaluator that actually runs in this build.

  RFC S18.2 says a graph-global falsifier *is* an ASK query. The measured
  reason this build evaluates them structurally instead is recorded in
  `AshA2A.Semantic.FalsifierSuite`'s moduledoc (the prebuilt GraphLaw wasm
  exposes no query export, and its `run_hooks/2` carries no hooks at all).
  That makes the `:ask` field a claim about semantics that nothing would
  otherwise check -- so this test executes it.

  Chicago school, strictly: the SPARQL engine here is a **real, independent
  SPARQL 1.1 implementation** running in a real OS process over a real file on
  disk, not a stub and not a second Elixir reimplementation of the same
  logic. Its disagreement would mean the structural evaluator is wrong about
  its own normative query. No `Mox`/`:meck`/`Mock(`/`patch`/`monkeypatch`
  equivalent appears anywhere in this file.

  On a machine without that engine the whole module **skips with a named,
  visible reason** -- it never silently substitutes a fake and never reports
  green for a check it did not perform.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.FalsifierFixtures, as: Fixtures
  alias AshA2A.Semantic.FalsifierSuite, as: Suite
  alias AshA2A.SparqlOracle

  @oracle SparqlOracle.available?()

  case @oracle do
    {:ok, version} ->
      @moduletag oracle: version

    {:error, reason} ->
      @moduletag skip:
                   "no real SPARQL 1.1 engine available, so the normative ASK text was NOT executed: #{reason}"
  end

  describe "the normative ASK text is real, executable SPARQL 1.1" do
    test "every falsifier's ASK parses and executes against a real engine" do
      pairs =
        Enum.map(Suite.falsifiers(), fn f ->
          {:ok, ask} = Suite.ask(f.id)
          {[], ask}
        end)

      assert {:ok, results} = SparqlOracle.ask_many(pairs),
             "at least one normative ASK failed to parse or execute"

      assert length(results) == 14
      assert Enum.all?(results, &is_boolean/1)
    end

    test "an ASK over the empty graph answers false for every falsifier" do
      # Nothing can be violated by a graph with no triples; an ASK that says
      # otherwise would mean the query matches vacuously.
      pairs =
        Enum.map(Suite.falsifiers(), fn f ->
          {:ok, ask} = Suite.ask(f.id)
          {[], ask}
        end)

      assert {:ok, results} = SparqlOracle.ask_many(pairs)

      for {f, fired} <- Enum.zip(Suite.falsifiers(), results) do
        refute fired, "#{f.id} (#{f.rfc}) fires on the empty graph"
      end
    end
  end

  describe "the structural evaluator agrees with a real SPARQL engine on every fixture" do
    for id <- Suite.ids() do
      test "#{id}: engine and structural evaluator agree on the positive fixture" do
        id = unquote(id)
        {:ok, graph} = Fixtures.positive(id)
        {:ok, ask} = Suite.ask(id)

        assert {:ok, engine} = SparqlOracle.ask(graph, ask)
        assert {:ok, structural} = Suite.evaluate(graph, id)

        assert engine == true,
               "the normative ASK for #{id} did NOT detect its own positive fixture"

        assert structural == engine,
               "structural evaluator (#{structural}) disagrees with SPARQL engine (#{engine}) for #{id}"
      end

      test "#{id}: engine and structural evaluator agree on the negative fixture" do
        id = unquote(id)
        {:ok, graph} = Fixtures.negative(id)
        {:ok, ask} = Suite.ask(id)

        assert {:ok, engine} = SparqlOracle.ask(graph, ask)
        assert {:ok, structural} = Suite.evaluate(graph, id)

        assert engine == false,
               "the normative ASK for #{id} fired on its own negative fixture"

        assert structural == engine,
               "structural evaluator (#{structural}) disagrees with SPARQL engine (#{engine}) for #{id}"
      end
    end

    test "cross-product: every ASK agrees with the structural evaluator on every fixture" do
      # Not just each falsifier against its own fixtures -- each of the
      # fourteen ASKs is executed against all twenty-eight fixture graphs, so
      # a falsifier that fires on some other falsifier's fixture is caught
      # here rather than assumed away. 14 x 28 = 392 real engine executions,
      # batched into one engine process (see AshA2A.SparqlOracle.ask_many/1).
      fixtures =
        Enum.flat_map(Fixtures.all(), fn {id, pos, neg} ->
          [{id, :positive, pos}, {id, :negative, neg}]
        end)

      cases =
        for f <- Suite.falsifiers(), {fixture_id, polarity, graph} <- fixtures do
          {:ok, ask} = Suite.ask(f.id)
          {f, fixture_id, polarity, graph, ask}
        end

      assert length(cases) == 392

      assert {:ok, engine_results} =
               SparqlOracle.ask_many(Enum.map(cases, fn {_, _, _, g, ask} -> {g, ask} end))

      for {{f, fixture_id, polarity, graph, _ask}, engine} <- Enum.zip(cases, engine_results) do
        assert {:ok, structural} = Suite.evaluate(graph, f.id)

        assert structural == engine,
               "#{f.id} (#{f.rfc}): structural=#{structural} engine=#{engine} " <>
                 "on the #{polarity} fixture of #{fixture_id}"
      end
    end
  end

  describe "the aggregating falsifiers agree at their boundaries" do
    test "fan-out: engine and structural evaluator agree at, and one over, the bound" do
      plan = "http://example.org/sa2a-fixture#planB"
      {:ok, ask} = Suite.ask(:plan_exceeds_fanout_bound)

      base = [
        {plan, Suite.sa("fanOutBound"), {:int, 3}},
        {plan, Suite.sa("hasSubStep"), "http://example.org/s1"},
        {plan, Suite.sa("hasSubStep"), "http://example.org/s2"},
        {plan, Suite.sa("hasSubStep"), "http://example.org/s3"}
      ]

      over = base ++ [{plan, Suite.sa("hasSubStep"), "http://example.org/s4"}]

      assert SparqlOracle.ask(base, ask) == {:ok, false}
      assert Suite.evaluate(base, :plan_exceeds_fanout_bound) == {:ok, false}
      assert SparqlOracle.ask(over, ask) == {:ok, true}
      assert Suite.evaluate(over, :plan_exceeds_fanout_bound) == {:ok, true}
    end

    test "resource envelope: engine and structural evaluator agree at, and one over, budget" do
      plan = "http://example.org/sa2a-fixture#planD"
      step = "http://example.org/sa2a-fixture#stepD"
      {:ok, ask} = Suite.ask(:plan_exceeds_resource_envelope)

      at_budget = [
        {plan, Suite.sa("resourceBudget"), {:int, 5}},
        {plan, Suite.sa("hasSubStep"), step},
        {step, Suite.sa("resourceCost"), {:int, 5}}
      ]

      over = List.replace_at(at_budget, 2, {step, Suite.sa("resourceCost"), {:int, 6}})

      assert SparqlOracle.ask(at_budget, ask) == {:ok, false}
      assert Suite.evaluate(at_budget, :plan_exceeds_resource_envelope) == {:ok, false}
      assert SparqlOracle.ask(over, ask) == {:ok, true}
      assert Suite.evaluate(over, :plan_exceeds_resource_envelope) == {:ok, true}
    end

    test "a budgeted plan with no declared costs: empty SPARQL group yields no row" do
      plan = "http://example.org/sa2a-fixture#planE"
      {:ok, ask} = Suite.ask(:plan_exceeds_resource_envelope)

      graph = [
        {plan, Suite.sa("resourceBudget"), {:int, 0}},
        {plan, Suite.sa("hasSubStep"), "http://example.org/sa2a-fixture#stepE"}
      ]

      assert SparqlOracle.ask(graph, ask) == {:ok, false}
      assert Suite.evaluate(graph, :plan_exceeds_resource_envelope) == {:ok, false}
    end
  end
end

# --- SECTION 7: Original test/ash_a2a/semantic/falsifier_suite_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.FalsifierSuiteTest do
  @moduledoc """
  RFC-SA2A-001 S18/S61 falsifier conformance.

  Chicago-school throughout: real graphs, real evaluators, state-based
  assertions on the real returned verdicts and the real refusal maps. No
  `Mox`/`:meck`/`Mock(`/`patch`/`monkeypatch` equivalent appears anywhere in
  this file -- there is nothing here to fake, because every collaborator
  (the suite, the fixtures, the graphs) is a real in-process value.

  The central property is *discrimination*, not merely firing: for each of
  the fourteen mandatory falsifiers the positive fixture must trip it and the
  negative fixture must not. A falsifier that only ever fires has not been
  shown to distinguish anything.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.FalsifierFixtures, as: Fixtures
  alias AshA2A.Semantic.FalsifierSuite, as: Suite

  describe "suite definition (RFC S61)" do
    test "defines exactly the fourteen mandatory falsifiers, with unique ids" do
      falsifiers = Suite.falsifiers()

      assert length(falsifiers) == 14
      assert Enum.map(falsifiers, & &1.id) == Suite.ids()
      assert Enum.uniq(Suite.ids()) == Suite.ids()
      assert Enum.all?(falsifiers, & &1.mandatory)
    end

    test "every falsifier carries a normative ASK query and an RFC section" do
      for f <- Suite.falsifiers() do
        assert {:ok, ask} = Suite.ask(f.id)
        assert ask =~ "ASK"
        assert ask =~ "PREFIX sa:"
        assert f.rfc =~ ~r/^S61\.\d+$/
        assert f.title != ""
      end
    end

    test "RFC subsections S61.1 through S61.14 are each covered exactly once" do
      sections = Suite.falsifiers() |> Enum.map(& &1.rfc) |> Enum.sort()
      expected = Enum.sort(for n <- 1..14, do: "S61.#{n}")
      assert sections == expected
    end

    test "report/0 partitions the suite into closed and deferred" do
      report = Suite.report()

      assert length(report) == 14
      assert Enum.all?(report, &(&1.standing in [:closed, :deferred]))

      assert Enum.filter(report, &(&1.standing == :deferred)) |> Enum.map(& &1.id) ==
               Enum.map(Suite.deferred(), & &1.id)

      assert length(Suite.closed()) + length(Suite.deferred()) == 14
    end

    test "unknown falsifier ids are refused, not silently ignored" do
      assert {:error, %{code: :unknown_falsifier, detail: :nope}} = Suite.falsifier(:nope)
      assert {:error, %{code: :unknown_falsifier}} = Suite.ask(:nope)
      assert {:error, %{code: :unknown_falsifier}} = Suite.evaluate([], :nope)
      assert {:error, %{code: :unknown_falsifier}} = Fixtures.positive(:nope)
      assert {:error, %{code: :unknown_falsifier}} = Fixtures.negative(:nope)
    end
  end

  describe "discrimination: every falsifier separates its positive from its negative fixture" do
    for id <- Suite.ids() do
      test "#{id}: positive fixture trips it, negative fixture does not" do
        id = unquote(id)

        assert {:ok, positive} = Fixtures.positive(id)
        assert {:ok, negative} = Fixtures.negative(id)

        assert {:ok, true} = Suite.evaluate(positive, id)
        assert {:ok, false} = Suite.evaluate(negative, id)
      end

      test "#{id}: positive fixture trips EXACTLY this falsifier and no other" do
        id = unquote(id)
        {:ok, positive} = Fixtures.positive(id)

        assert %{tripped: [^id]} = Suite.run(positive)
      end

      test "#{id}: negative fixture trips nothing at all" do
        id = unquote(id)
        {:ok, negative} = Fixtures.negative(id)

        assert %{tripped: []} = Suite.run(negative)
      end
    end

    test "every fixture pair differs -- a pair that was accidentally identical would pass nothing" do
      for {id, positive, negative} <- Fixtures.all() do
        refute Enum.sort(positive) == Enum.sort(negative),
               "fixtures for #{id} are identical; the negative is not a control"
      end
    end
  end

  describe "RFC S18.2: a true mandatory falsifier blocks admission" do
    test "admit/1 refuses every positive fixture and names which falsifier tripped" do
      for {id, positive, _negative} <- Fixtures.all() do
        assert {:error, refusal} = Suite.admit(positive)
        assert refusal.code == :refused_falsifier
        assert refusal.detail.falsifier == id
        assert refusal.detail.falsifiers == [id]

        {:ok, f} = Suite.falsifier(id)
        assert refusal.detail.rfc == [f.rfc]
      end
    end

    test "admit/1 admits every negative fixture" do
      for {id, _positive, negative} <- Fixtures.all() do
        assert Suite.admit(negative) == :ok, "negative fixture for #{id} was refused"
      end
    end

    test "admit/1 names every falsifier that tripped when a graph violates several" do
      {:ok, a} = Fixtures.positive(:consequence_without_authority_requirement)
      {:ok, b} = Fixtures.positive(:canonical_mutation_outside_brce)
      {:ok, c} = Fixtures.positive(:do_without_prepared_receipt)

      assert {:error, refusal} = Suite.admit(a ++ b ++ c)

      assert refusal.detail.falsifiers == [
               :consequence_without_authority_requirement,
               :do_without_prepared_receipt,
               :canonical_mutation_outside_brce
             ]

      # The named single falsifier is the first in RFC S61 order, deterministically.
      assert refusal.detail.falsifier == :consequence_without_authority_requirement
      assert refusal.detail.rfc == ["S61.1", "S61.2", "S61.14"]
    end

    test "an empty graph trips nothing and is admitted" do
      assert Suite.run([]) == %{tripped: [], clear: Suite.ids()}
      assert Suite.admit([]) == :ok
    end
  end

  describe "graph set semantics" do
    test "duplicated triples cannot change a verdict (the aggregating falsifiers)" do
      # F07 counts sub-steps; if multiplicity leaked in, duplicating a
      # sub-step edge in the NEGATIVE fixture would push the count over the
      # bound and trip a falsifier that must stay clear.
      {:ok, negative} = Fixtures.negative(:plan_exceeds_fanout_bound)
      doubled = negative ++ negative

      assert {:ok, false} = Suite.evaluate(doubled, :plan_exceeds_fanout_bound)
      assert %{tripped: []} = Suite.run(doubled)

      # F08 sums resource cost; the same leak would inflate the sum.
      {:ok, envelope} = Fixtures.negative(:plan_exceeds_resource_envelope)
      assert {:ok, false} = Suite.evaluate(envelope ++ envelope, :plan_exceeds_resource_envelope)
    end

    test "triple order cannot change a verdict" do
      for {id, positive, negative} <- Fixtures.all() do
        assert Suite.evaluate(Enum.reverse(positive), id) == {:ok, true}, "order-sensitive: #{id}"

        assert Suite.evaluate(Enum.reverse(negative), id) == {:ok, false},
               "order-sensitive: #{id}"
      end
    end
  end

  describe "boundary behaviour of the aggregating falsifiers" do
    test "fan-out at exactly the bound is admitted; one over trips" do
      plan = "http://example.org/sa2a-fixture#planB"

      at_bound = [
        {plan, Suite.sa("fanOutBound"), {:int, 3}},
        {plan, Suite.sa("hasSubStep"), "http://example.org/s1"},
        {plan, Suite.sa("hasSubStep"), "http://example.org/s2"},
        {plan, Suite.sa("hasSubStep"), "http://example.org/s3"}
      ]

      assert {:ok, false} = Suite.evaluate(at_bound, :plan_exceeds_fanout_bound)

      over = at_bound ++ [{plan, Suite.sa("hasSubStep"), "http://example.org/s4"}]
      assert {:ok, true} = Suite.evaluate(over, :plan_exceeds_fanout_bound)
    end

    test "a plan with a bound but no sub-steps does not trip (empty group, no row)" do
      plan = "http://example.org/sa2a-fixture#planC"

      assert {:ok, false} =
               Suite.evaluate(
                 [{plan, Suite.sa("fanOutBound"), {:int, 0}}],
                 :plan_exceeds_fanout_bound
               )
    end

    test "resource cost exactly at budget is admitted; one over trips" do
      plan = "http://example.org/sa2a-fixture#planD"
      step = "http://example.org/sa2a-fixture#stepD"

      at_budget = [
        {plan, Suite.sa("resourceBudget"), {:int, 5}},
        {plan, Suite.sa("hasSubStep"), step},
        {step, Suite.sa("resourceCost"), {:int, 5}}
      ]

      assert {:ok, false} = Suite.evaluate(at_budget, :plan_exceeds_resource_envelope)

      over =
        List.replace_at(at_budget, 2, {step, Suite.sa("resourceCost"), {:int, 6}})

      assert {:ok, true} = Suite.evaluate(over, :plan_exceeds_resource_envelope)
    end

    test "a budgeted plan whose sub-steps declare no cost does not trip" do
      plan = "http://example.org/sa2a-fixture#planE"

      graph = [
        {plan, Suite.sa("resourceBudget"), {:int, 0}},
        {plan, Suite.sa("hasSubStep"), "http://example.org/sa2a-fixture#stepE"}
      ]

      assert {:ok, false} = Suite.evaluate(graph, :plan_exceeds_resource_envelope)
    end
  end

  describe "RFC S18.3: a CONSTRUCT projection does not automatically acquire standing" do
    test "a bare projection of a canonical graph has no standing" do
      {:ok, projection} = Fixtures.negative(:projection_claiming_canonical_source)

      assert Suite.projection_standing(projection, "http://example.org/sa2a-fixture#projection1") ==
               :none
    end

    test "standing is not inherited from the projected canonical graph" do
      projection = [
        {"http://example.org/sa2a-fixture#projection1", Suite.sa("projectionOf"),
         "http://example.org/sa2a-fixture#canonicalGraph1"},
        {"http://example.org/sa2a-fixture#canonicalGraph1", Suite.rdf_type(),
         Suite.sa("CanonicalGraph")},
        {"http://example.org/sa2a-fixture#canonicalGraph1", Suite.sa("grantedStanding"),
         {:lit, "ADMITTED"}}
      ]

      assert Suite.projection_standing(projection, "http://example.org/sa2a-fixture#projection1") ==
               :none
    end

    test "standing is acquired only by an explicit grant on the projection itself" do
      {:ok, base} = Fixtures.negative(:projection_claiming_canonical_source)

      granted =
        base ++
          [
            {"http://example.org/sa2a-fixture#projection1", Suite.sa("grantedStanding"),
             {:lit, "ADMITTED"}}
          ]

      assert Suite.projection_standing(granted, "http://example.org/sa2a-fixture#projection1") ==
               :admitted
    end

    test "a projection that asserts itself canonical trips F11 (RFC S61.11)" do
      {:ok, overreaching} = Fixtures.positive(:projection_claiming_canonical_source)

      assert {:ok, true} = Suite.evaluate(overreaching, :projection_claiming_canonical_source)
      assert {:error, %{code: :refused_falsifier}} = Suite.admit(overreaching)
    end
  end

  describe "RFC S18.4: direct SPARQL Update against canonical admitted state is prohibited" do
    setup do
      %{graph: Fixtures.update_classification()}
    end

    test "a mutating update against a canonical graph is refused", %{graph: graph} do
      update = """
      PREFIX ex: <http://example.org/>
      INSERT DATA { GRAPH <#{Fixtures.canonical_graph_iri()}> { ex:a ex:p ex:b } }
      """

      assert {:error, refusal} = Suite.check_update(graph, update)
      assert refusal.code == :refused_sparql_update_on_canonical
      assert refusal.detail.rfc == "S18.4"
      assert refusal.detail.form == "INSERT DATA"
      assert refusal.detail.target == Fixtures.canonical_graph_iri()
      assert refusal.detail.reason =~ "canonical"
    end

    test "the same update against a staging graph is permitted", %{graph: graph} do
      update = """
      PREFIX ex: <http://example.org/>
      INSERT DATA { GRAPH <#{Fixtures.staging_graph_iri()}> { ex:a ex:p ex:b } }
      """

      assert Suite.check_update(graph, update) == :ok
    end

    test "every mutating operation form is recognised against canonical", %{graph: graph} do
      canonical = Fixtures.canonical_graph_iri()

      cases = [
        {"INSERT DATA", "INSERT DATA { GRAPH <#{canonical}> { <urn:a> <urn:p> <urn:b> } }"},
        {"DELETE DATA", "DELETE DATA { GRAPH <#{canonical}> { <urn:a> <urn:p> <urn:b> } }"},
        {"DELETE WHERE", "DELETE WHERE { GRAPH <#{canonical}> { ?s ?p ?o } }"},
        {"CLEAR", "CLEAR GRAPH <#{canonical}>"},
        {"DROP", "DROP GRAPH <#{canonical}>"},
        {"LOAD", "LOAD <http://example.org/data.ttl> INTO GRAPH <#{canonical}>"},
        {"COPY", "COPY GRAPH <#{canonical}> TO GRAPH <#{canonical}>"}
      ]

      for {form, update} <- cases do
        assert {:error, refusal} = Suite.check_update(graph, update),
               "#{form} was not refused against a canonical graph"

        assert refusal.code == :refused_sparql_update_on_canonical
        assert refusal.detail.form == form
      end
    end

    test "a mutating update naming no graph is refused (default graph is canonical in Strict)",
         %{graph: graph} do
      assert {:error, refusal} =
               Suite.check_update(graph, "INSERT DATA { <urn:a> <urn:p> <urn:b> }")

      assert refusal.detail.target == :default_graph
      assert refusal.detail.reason =~ "default graph"
    end

    test "a mutating update naming an unclassified graph is refused, not admitted", %{
      graph: graph
    } do
      update =
        "INSERT DATA { GRAPH <http://example.org/unknown-graph> { <urn:a> <urn:p> <urn:b> } }"

      assert {:error, refusal} = Suite.check_update(graph, update)
      assert refusal.detail.target == "http://example.org/unknown-graph"
      assert refusal.detail.reason =~ "not classified"
    end

    test "a read-only query is not an update and is permitted", %{graph: graph} do
      assert Suite.check_update(graph, "SELECT ?s WHERE { ?s ?p ?o }") == :ok
      assert Suite.check_update(graph, "ASK { ?s ?p ?o }") == :ok

      assert Suite.check_update(graph, "CONSTRUCT { ?s ?p ?o } WHERE { ?s ?p ?o }") == :ok
    end

    test "an update touching both a staging and a canonical graph is refused", %{graph: graph} do
      update = """
      DELETE { GRAPH <#{Fixtures.canonical_graph_iri()}> { ?s ?p ?o } }
      INSERT { GRAPH <#{Fixtures.staging_graph_iri()}> { ?s ?p ?o } }
      WHERE  { GRAPH <#{Fixtures.staging_graph_iri()}> { ?s ?p ?o } }
      """

      assert {:error, refusal} = Suite.check_update(graph, update)
      assert refusal.detail.targets == [Fixtures.canonical_graph_iri()]
    end
  end

  describe "N-Triples serialization" do
    test "is deterministic, order-independent and deduplicating" do
      {:ok, graph} = Fixtures.positive(:plan_exceeds_resource_envelope)

      canonical = Suite.to_ntriples(graph)

      assert Suite.to_ntriples(Enum.reverse(graph)) == canonical
      assert Suite.to_ntriples(graph ++ graph) == canonical
      assert Suite.to_ntriples(Enum.shuffle(graph)) == canonical
    end

    test "emits real N-Triples terms for IRIs, plain literals and typed integers" do
      graph = [
        {"http://example.org/s", "http://example.org/p", "http://example.org/o"},
        {"http://example.org/s", "http://example.org/lit", {:lit, "hello"}},
        {"http://example.org/s", "http://example.org/num", {:int, 42}}
      ]

      lines = graph |> Suite.to_ntriples() |> String.split("\n", trim: true)

      assert "<http://example.org/s> <http://example.org/p> <http://example.org/o> ." in lines
      assert "<http://example.org/s> <http://example.org/lit> \"hello\" ." in lines

      assert "<http://example.org/s> <http://example.org/num> \"42\"^^<http://www.w3.org/2001/XMLSchema#integer> ." in lines
    end

    test "escapes literal content that would otherwise break the serialization" do
      graph = [{"http://example.org/s", "http://example.org/p", {:lit, ~s(a "b" c\nd)}}]

      line = graph |> Suite.to_ntriples() |> String.trim()

      assert line == ~S(<http://example.org/s> <http://example.org/p> "a \"b\" c\nd" .)
    end
  end

  describe "integration with the existing semantic vocabulary" do
    test "rdf:type is taken from the real prefix registry, not re-declared" do
      assert Suite.rdf_type() == AshA2A.Semantic.Vocabulary.expand("rdf:type")
      assert Suite.rdf_type() == "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
    end

    test "the provenance predicate matches the one AshA2A.Semantic.Ontology already emits" do
      assert Suite.prov("wasDerivedFrom") ==
               AshA2A.Semantic.Vocabulary.expand("prov:wasDerivedFrom")
    end
  end
end

# --- SECTION 8: Original test/ash_a2a/semantic/interchange_contract_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.InterchangeContractTest do
  use ExUnit.Case, async: true
  alias AshA2A.Semantic.InterchangeContract
  @sha String.duplicate("a", 40)
  @digest "sha256:" <> String.duplicate("b", 64)
  defp attrs,
    do: %{
      source_repository: "example/runtime",
      source_revision: @sha,
      semantic_vocabulary: "https://example.test/interchange/v1",
      interface_digest: @digest,
      projection_rule: "rust-wasm-component",
      target_runtime: "beam/wasmex",
      artifact_digest: @digest
    }

  test "identity is deterministic and evidence only" do
    assert {:ok, a} = InterchangeContract.new(attrs())
    assert {:ok, b} = InterchangeContract.new(attrs())
    assert a.portable_identity == b.portable_identity

    assert {a.technical_standing, a.external_standing, a.runtime_authority} ==
             {"CANDIDATE", "NONE", "NONE"}

    assert :ok = InterchangeContract.verify(a)
  end

  test "requires exact source subject" do
    assert {:error, {:semantic_interchange_exact_subject_required, :source_revision}} =
             InterchangeContract.new(%{attrs() | source_revision: "main"})
  end

  test "cannot manufacture authority" do
    assert {:error, {:semantic_interchange_authority_ceiling, :runtime_authority}} =
             InterchangeContract.new(Map.put(attrs(), :runtime_authority, "ALLOW"))
  end

  test "projects only to existing release candidate boundary" do
    assert {:ok, c} = InterchangeContract.new(attrs())
    cap = InterchangeContract.capability_candidate(c, "graphlaw", "26.9.30")
    assert cap.state == :candidate
    assert cap.subject_revision == @sha
    assert cap.digest == c.portable_identity
    assert cap.standing_binding == nil
  end
end

# --- SECTION 9: Original test/ash_a2a/semantic/llm_boundary_falsifiers_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.LlmBoundaryFalsifiersTest do
  @moduledoc """
  RFC S40's fundamental relation, one named falsifier per prohibited
  effect:

      LLMOutput => Candidate        and NEVER        LLMOutput => Standing

  Each of the seven tests below drives a real model-shaped payload that
  *attempts* one of the seven prohibited effects through the real
  `AshA2A.Semantic.LlmBoundary` and asserts on the real returned refusal
  -- never on "was something called".

  ## Why the paired positive test matters

  A suite of seven refusals could pass vacuously: if `candidate/3`
  refused *everything*, all seven would be green and the boundary would
  be useless rather than correct. The "a clean payload really does become
  a candidate" test is the adversarial-completeness companion (the same
  idiom `request_router_llm_never_called_test.exs` uses for its own
  raise-on-call proof): it proves the boundary admits real work, so the
  seven refusals are discriminating rather than blanket.

  The seventh effect (`:execute_consequential_do`) additionally gets a
  real end-to-end proof through the real `AshA2A.CommandBus` against a
  real `:change`-consequence Ash resource: a command built from an
  LLM-resolved payload carries no `AshA2A.Authority` (because the
  boundary refuses to produce one), and the real bus refuses it with
  `:authority_required` before any dispatch happens.
  """

  use ExUnit.Case, async: true

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Command, CommandBus}
  alias AshA2A.Semantic.Allocator
  alias AshA2A.Semantic.LlmBoundary
  alias AshA2A.Semantic.Unknown
  alias AshA2A.Semantic.Unknown.Resolution
  alias AshA2A.Test.Fixture.Item

  defp unknown(class \\ "falsifier-class") do
    Unknown.declare(class, %{"subject" => "a real semantic subject"})
  end

  # --------------------------------------------------------------------
  # The seven named falsifiers (RFC S40)
  # --------------------------------------------------------------------

  test "falsifier 1/7 :admit_fact -- model output claiming admitted standing is refused" do
    payload = %{"claim" => "the invoice is reconciled", "standing" => "admitted"}

    assert {:error, %{code: :llm_standing_claim_refused, effect: :admit_fact, key: "standing"}} =
             LlmBoundary.candidate(unknown(), :llm, payload)

    # And the direct effect gate, which has no success clause at all.
    assert {:error, %{code: :llm_effect_refused, effect: :admit_fact}} =
             LlmBoundary.attempt(:admit_fact, payload)
  end

  test "falsifier 2/7 :create_canonical_identity -- model output minting a graph digest is refused" do
    payload = %{
      "entities" => [%{"id" => "e1", "graph_digest" => String.duplicate("a", 64)}]
    }

    assert {:error, %{code: :llm_standing_claim_refused, effect: :create_canonical_identity}} =
             LlmBoundary.candidate(unknown(), :llm, payload)

    assert {:error, %{code: :llm_effect_refused, effect: :create_canonical_identity}} =
             LlmBoundary.attempt(:create_canonical_identity)
  end

  test "falsifier 3/7 :grant_authority -- model output granting itself authority is refused" do
    payload = %{"plan" => %{"authority" => %{"subject" => "agent-1", "scope" => "*"}}}

    assert {:error, %{code: :llm_standing_claim_refused, effect: :grant_authority}} =
             LlmBoundary.candidate(unknown(), :llm, payload)

    assert {:error, %{code: :llm_effect_refused, effect: :grant_authority}} =
             LlmBoundary.attempt(:grant_authority)
  end

  test "falsifier 4/7 :alter_canonical_state -- model output committing canonical state is refused" do
    payload = %{"steps" => [%{"commit" => true, "target" => "ledger"}]}

    assert {:error, %{code: :llm_standing_claim_refused, effect: :alter_canonical_state}} =
             LlmBoundary.candidate(unknown(), :llm, payload)

    assert {:error, %{code: :llm_effect_refused, effect: :alter_canonical_state}} =
             LlmBoundary.attempt(:alter_canonical_state)
  end

  test "falsifier 5/7 :promote_own_rule -- model output promoting its own rule is refused" do
    payload = %{"rule_promotion" => %{"rule" => "always reconcile", "into" => "admitted_set"}}

    assert {:error, %{code: :llm_standing_claim_refused, effect: :promote_own_rule}} =
             LlmBoundary.candidate(unknown(), :llm, payload)

    assert {:error, %{code: :llm_effect_refused, effect: :promote_own_rule}} =
             LlmBoundary.attempt(:promote_own_rule)
  end

  test "falsifier 6/7 :modify_root_manifest -- model output editing a Root Manifest is refused" do
    payload = %{"root_manifest" => %{"version" => "26.9.16", "capabilities" => ["*"]}}

    assert {:error, %{code: :llm_standing_claim_refused, effect: :modify_root_manifest}} =
             LlmBoundary.candidate(unknown(), :llm, payload)

    assert {:error, %{code: :llm_effect_refused, effect: :modify_root_manifest}} =
             LlmBoundary.attempt(:modify_root_manifest)
  end

  test "falsifier 7/7 :execute_consequential_do -- model output dispatching a DO is refused" do
    payload = %{"next" => %{"dispatch" => "AshA2A.Test.Fixture.Item.create"}}

    assert {:error, %{code: :llm_standing_claim_refused, effect: :execute_consequential_do}} =
             LlmBoundary.candidate(unknown(), :llm, payload)

    assert {:error, %{code: :llm_effect_refused, effect: :execute_consequential_do}} =
             LlmBoundary.attempt(:execute_consequential_do)
  end

  # --------------------------------------------------------------------
  # Adversarial completeness: the boundary is discriminating, not blanket
  # --------------------------------------------------------------------

  test "adversarial completeness: a clean model payload really does become a candidate" do
    payload = %{
      "goal" => "reconcile the invoice against the ledger",
      "capabilities" => ["AshA2A.Test.Fixture.Item.create"],
      # Deliberately present: `authorities` (plural) is the key a real
      # semantic IR carries and `AshA2A.Semantic.Admission` requires. The
      # claim scan matches EXACT keys, so this must NOT trip the
      # `:grant_authority` refusal -- if it did, this boundary would
      # break the existing compiler payload shape.
      "authorities" => [%{"id" => "a1", "mode" => "described"}]
    }

    assert {:ok, %Resolution{} = resolution} =
             LlmBoundary.candidate(unknown("clean-class"), :llm, payload)

    assert resolution.standing == :candidate
    assert resolution.authority == :none
    assert resolution.resolver == :llm
    assert resolution.class == "clean-class"
    assert resolution.payload == payload
    assert :ok = LlmBoundary.fence(resolution)
  end

  test "every one of the seven prohibited effects is refused; attempt/2 has no success clause" do
    # Exhaustive over the module's own declared list, so adding a new
    # effect without a refusal clause fails here rather than silently.
    assert length(LlmBoundary.prohibited_effects()) == 7

    for effect <- LlmBoundary.prohibited_effects() do
      assert {:error, %{code: :llm_effect_refused, effect: ^effect}} = LlmBoundary.attempt(effect)
    end

    # An effect nobody anticipated also fails closed.
    assert {:error, %{code: :unknown_llm_effect}} = LlmBoundary.attempt(:some_future_effect)
  end

  # --------------------------------------------------------------------
  # DEFECT 5 regression (RFC S40): scan_claim/1 raised on structs.
  #
  # The `is_map(value)` guard is TRUE for a struct, but a struct is not
  # Enumerable, so `Enum.find_value/2` raised Protocol.UndefinedError --
  # despite the docstring claiming the scan "never raises on arbitrary
  # decoded JSON". Worse, the crash PRE-EMPTED a real claim refusal
  # order-dependently: a payload carrying both a struct and a forged
  # `"authority"` key crashed instead of refusing whenever map iteration
  # reached the struct first.
  # --------------------------------------------------------------------

  test "S40 regression: a struct value does not raise, and does not pre-empt a real refusal" do
    # The verifier's exact minimal repro: a DateTime value. `"aaa_..."`
    # sorts before `"authority"`, so the struct is reached FIRST -- which
    # is precisely the ordering that used to crash.
    payload = %{"aaa_observed_at" => ~U[2026-01-01 00:00:00Z], "authority" => "admin"}

    assert {"authority", :grant_authority} = LlmBoundary.scan_claim(payload)

    assert {:error,
            %{code: :llm_standing_claim_refused, effect: :grant_authority, key: "authority"}} =
             LlmBoundary.candidate(unknown(), :llm, payload)

    # The refusal is now order-INdependent: the other key ordering agrees.
    reordered = %{"authority" => "admin", "zzz_observed_at" => ~U[2026-01-01 00:00:00Z]}
    assert {"authority", :grant_authority} = LlmBoundary.scan_claim(reordered)

    # A bare struct, and a struct nested at depth, are leaves -- not
    # containers, and never a raise.
    assert LlmBoundary.scan_claim(~U[2026-01-01 00:00:00Z]) == nil
    assert LlmBoundary.scan_claim(%{"at" => ~U[2026-01-01 00:00:00Z]}) == nil
    assert LlmBoundary.scan_claim(%{"a" => %{"b" => [~U[2026-01-01 00:00:00Z]]}}) == nil
    assert LlmBoundary.scan_claim(%{"a" => [%{"at" => Date.utc_today()}]}) == nil

    # Several other struct shapes the same guard used to crash on.
    for struct_value <- [
          ~U[2026-01-01 00:00:00Z],
          ~D[2026-01-01],
          ~T[10:00:00],
          ~N[2026-01-01 00:00:00],
          MapSet.new([1, 2]),
          %URI{},
          unknown()
        ] do
      assert LlmBoundary.scan_claim(struct_value) == nil
      assert LlmBoundary.scan_claim(%{"v" => struct_value}) == nil

      assert {"root_manifest", :modify_root_manifest} =
               LlmBoundary.scan_claim(%{"aaa" => struct_value, "root_manifest" => "edited"})
    end

    # A struct is not decoded model output at all, so it is not a payload.
    assert {:error, %{code: :llm_output_not_a_map}} =
             LlmBoundary.candidate(unknown(), :llm, ~U[2026-01-01 00:00:00Z])

    # And a clean payload carrying a struct still becomes a real candidate:
    # this is a leaf rule, not a blanket refusal.
    assert {:ok, %Resolution{standing: :candidate, authority: :none} = resolution} =
             LlmBoundary.candidate(unknown("clean-with-struct"), :llm, %{
               "answer" => "42",
               "at" => ~U[2026-01-01 00:00:00Z]
             })

    assert resolution.payload["at"] == ~U[2026-01-01 00:00:00Z]
    assert :ok = LlmBoundary.fence(resolution)
  end

  # --------------------------------------------------------------------
  # Effect 7, end to end, through the REAL CommandBus
  # --------------------------------------------------------------------

  test "effect 7 end-to-end: an LLM-resolved candidate reaches the real CommandBus with no authority and is refused before DO" do
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: name})
    store_opts = [name: name]

    # A real UNKNOWN resolved by a real (injected, non-mock) resolver
    # function through the real allocator and the real boundary.
    budget = Allocator.new!([inference_calls: 1], issued_by: {:host, __MODULE__})

    resolver = fn %Unknown{} ->
      {:ok, %{"capability_id" => "AshA2A.Test.Fixture.Item.create", "input" => %{"label" => "w"}}}
    end

    assert {:ok, :resolved, %Resolution{} = resolution, _budget} =
             Unknown.route("create-an-item", %{"text" => "make a widget"},
               budget: budget,
               resolver: {:llm, resolver}
             )

    assert resolution.authority == :none

    # The ONLY thing the resolution can contribute is content. There is
    # no code path from a Resolution to an %AshA2A.Authority{} -- the
    # command below is built with `authority: nil` because the boundary
    # cannot produce one.
    command =
      Command.new(resolution.payload["capability_id"],
        command_id: "llm-derived-#{System.unique_integer([:positive])}",
        agent_id: "agent-1",
        principal_id: "subject-1",
        input: resolution.payload["input"]
      )

    assert is_nil(command.authority)

    # Real bus, real `:change`-consequence Ash resource, real refusal.
    assert {:error, %{code: :authority_required}} =
             CommandBus.run(command, data_message(%{"label" => "w"}), Item,
               store_opts: store_opts
             )

    # And no receipt was claimed: the refusal happened before DO.
    assert :error = AshA2A.ReceiptStore.Memory.fetch(command.command_id, store_opts)
  end
end

# --- SECTION 10: Original test/ash_a2a/semantic/machine_experience_planning_seam_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.MachineExperiencePlanningSeamTest do
  @moduledoc """
  RFC S39/S65's compile-back, wired into this codebase's **existing**
  evidence-feedback seam rather than a parallel one.

  `ash_a2a` already carries `Receipt -> observation ->
  AshA2A.Semantic.PlanningIR.with_observation/2 -> re-synthesis with a
  `parent_fingerprint``. `AshA2A.Semantic.MachineExperience.record_in_planning_ir/2`
  feeds a compiled-back machinery observation through that same real
  function, so "class X now routes deterministically" enters the same
  observation stream as a runtime receipt does.

  The assertions below are on real state produced by the real
  `PlanningIR`: the real appended observation map and the real
  recomputed content-addressed fingerprint. Real `IR`, real `Ontology`,
  real `PlanningIR` -- no doubles anywhere.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.LlmBoundary
  alias AshA2A.Semantic.MachineExperience
  alias AshA2A.Semantic.{IR, Ontology, PlanningIR, Unknown}

  defp admitted_ir do
    %IR{
      source_id: "src-machine-experience",
      standing: :admitted,
      authority: :none,
      entities: [
        %{
          "id" => "e1",
          "kind" => "entity",
          "type" => "schema:Thing",
          "label" => "Shipment",
          "description" => "the shipment",
          "source_quote" => "the shipment"
        }
      ],
      relations: [],
      events: [],
      goals: [
        %{
          "id" => "g1",
          "kind" => "goal",
          "description" => "estimate the shipment eta",
          "source_quote" => "estimate the shipment eta"
        }
      ],
      constraints: [],
      capabilities: [],
      authorities: [],
      observations: [],
      uncertainties: [],
      exclusions: [],
      temporal_relations: [],
      causal_hypotheses: [],
      unresolved: []
    }
  end

  defp real_planning_ir do
    ir = admitted_ir()
    {:ok, ontology} = Ontology.from_ir(ir)
    {:ok, planning} = PlanningIR.from_ir(ir, ontology)
    planning
  end

  defp compiled_machinery do
    {:ok, resolution} =
      LlmBoundary.candidate(
        Unknown.declare("shipment-eta-estimate", %{"days" => 3}),
        :llm,
        %{"eta_hours" => 72}
      )

    {:ok, machinery} =
      MachineExperience.compile_back(resolution, :rule, fn %{"days" => d} -> {:ok, d * 24} end)

    {resolution, machinery}
  end

  test "a compile-back projects into the same observation shape runtime receipts use" do
    {resolution, machinery} = compiled_machinery()

    observation = MachineExperience.observation(machinery)

    assert observation["kind"] == "compiled_back_machinery"
    assert observation["class"] == "shipment-eta-estimate"
    assert observation["machinery_kind"] == "rule"
    assert observation["resolver"] == "llm"
    assert observation["resolution_fingerprint"] == resolution.fingerprint
    assert observation["machinery_fingerprint"] == machinery.fingerprint

    # Carries no standing and no authority -- it is evidence, not a claim.
    refute Map.has_key?(observation, "standing")
    refute Map.has_key?(observation, "authority")
  end

  test "record_in_planning_ir/2 appends through the real PlanningIR.with_observation/2 and moves its fingerprint" do
    planning = real_planning_ir()
    {_resolution, machinery} = compiled_machinery()

    assert planning.observations == []
    before_fingerprint = planning.fingerprint

    next = MachineExperience.record_in_planning_ir(planning, machinery)

    assert %PlanningIR{} = next
    assert length(next.observations) == 1
    assert hd(next.observations)["kind"] == "compiled_back_machinery"
    assert hd(next.observations)["class"] == "shipment-eta-estimate"

    # Real content-addressed change, recomputed by the real PlanningIR.
    refute next.fingerprint == before_fingerprint
    assert String.length(next.fingerprint) == 64

    # Standing and authority are untouched by feeding in evidence.
    assert next.standing == :admitted
    assert next.authority == :none
  end

  test "recording the same machinery twice is a real second observation, not an idempotent no-op" do
    planning = real_planning_ir()
    {_resolution, machinery} = compiled_machinery()

    once = MachineExperience.record_in_planning_ir(planning, machinery)
    twice = MachineExperience.record_in_planning_ir(once, machinery)

    assert length(twice.observations) == 2
    refute twice.fingerprint == once.fingerprint
  end
end

# --- SECTION 11: Original test/ash_a2a/semantic/machine_experience_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

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

  # --------------------------------------------------------------------
  # A compiled route is not permanent: unregister/3 genuinely retracts it
  # --------------------------------------------------------------------

  test "unregister/3 forces the class back to genuinely UNKNOWN -- resolve/3 misses, Unknown.route/3 spends the resolver again" do
    {:ok, resolution} =
      LlmBoundary.candidate(Unknown.declare("gate-cycle", %{}), :llm, %{"answer" => 1})

    {:ok, machinery} =
      MachineExperience.compile_back(resolution, :rule, fn _ -> {:ok, :machinery_result} end)

    {:ok, store, register_changelog} =
      MachineExperience.register(MachineExperience.new_store(), machinery)

    assert register_changelog.added == ["gate-cycle"]

    # Real state: the class routes deterministically before retraction.
    assert MachineExperience.resolve(store, "gate-cycle", %{}) == {:ok, :machinery_result}

    assert {:ok, :machinery, :machinery_result, _budget} =
             Unknown.route("gate-cycle", %{}, machinery: store)

    assert {:ok, next_store, %Changelog{} = unregister_changelog} =
             MachineExperience.unregister(store, "gate-cycle", reason: "court disproved it")

    assert unregister_changelog.removed == ["gate-cycle"]
    assert unregister_changelog.added == []
    assert MachineExperience.classes(next_store) == []

    # Real state: `resolve/3` genuinely misses after retraction, and a
    # rerun through `Unknown.route/3` spends the resolver again rather
    # than returning a stale machinery hit.
    assert MachineExperience.resolve(next_store, "gate-cycle", %{}) == :no_machinery

    assert {:ok, :resolved, %Resolution{} = re_resolution, _budget} =
             Unknown.route("gate-cycle", %{"days" => 2},
               machinery: next_store,
               budget: budget(1),
               resolver: {:llm, llm_resolver()}
             )

    assert re_resolution.class == "gate-cycle"
  end

  test "unregister/3 is a real no-op for a class nobody registered, not an error" do
    store = MachineExperience.new_store()

    assert {:ok, same_store, %Changelog{} = changelog} =
             MachineExperience.unregister(store, "never-registered")

    assert changelog.removed == []
    assert changelog.added == []
    assert MachineExperience.classes(same_store) == MachineExperience.classes(store)
  end

  test "unregister/3 emits a real telemetry event distinguishing an actual removal from a no-op" do
    handler_id = make_ref()

    :telemetry.attach(
      handler_id,
      [:ash_a2a, :semantic, :machine_experience, :unregister],
      fn _event, _measurements, metadata, _config ->
        send(self(), {:unregister_event, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, resolution} = LlmBoundary.candidate(Unknown.declare("delta", %{}), :llm, %{"a" => 1})
    {:ok, machinery} = MachineExperience.compile_back(resolution, :rule, fn _ -> {:ok, 1} end)
    {:ok, store, _} = MachineExperience.register(MachineExperience.new_store(), machinery)

    {:ok, _next_store, _} = MachineExperience.unregister(store, "delta", reason: "epoch-close")

    assert_received {:unregister_event, %{class: "delta", reason: "epoch-close", removed: true}}

    {:ok, _still_empty, _} = MachineExperience.unregister(store, "never-there")

    assert_received {:unregister_event, %{class: "never-there", reason: nil, removed: false}}
  end
end

# --- SECTION 12: Original test/ash_a2a/semantic/meta_admission_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.MetaAdmissionTest do
  @moduledoc """
  Real tests for RFC S20/S58 meta-admission -- admission applied recursively
  to the machinery.

  The two invariants under test:

      NOT Standing(v)  =>  NOT Validates(v, x)
      NOT Standing(r)  =>  NOT CanonicalDerivation(r)

  Chicago school: the real `praxis-graphlaw` wasm engine is really executed
  as a real subprocess over real corpus files, and every assertion is on a
  real returned value or a real digest. The unpinned "rogue" artifacts are
  real, well-formed files the engine really accepts -- not stubs.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.MetaAdmission
  alias AshA2A.Semantic.RootManifest
  alias AshA2A.Semantic.RootManifest.{ConformanceCorpus, EngineProbe}
  alias AshA2A.Test.Support.Sa2aCorpus

  @engine_available EngineProbe.available?()

  @pinned_machinery [
    profile: "conformance/profile/sa2a_profile.ttl",
    shapes: "conformance/shapes/command_envelope.shacl.ttl",
    schema: "conformance/schema/command_envelope.shexj",
    shape_map: "conformance/schema/command_envelope.shapemap"
  ]

  @valid_data "conformance/data/valid_command.ttl"
  @invalid_data "conformance/data/invalid_command.ttl"

  defp stage do
    staged = Sa2aCorpus.stage!()
    on_exit(fn -> Sa2aCorpus.cleanup(staged.root) end)
    staged
  end

  defp dialect(result, name) do
    Enum.find(result.dialects, &(Map.get(&1, "dialect") == name))
  end

  # Appends a real, spec-legal WebAssembly custom section (section id 0) to
  # an existing wasm module's raw bytes. A custom section is defined by the
  # WebAssembly binary format to be ignorable by any conforming engine and
  # is legal at the very end of a module, so the result really loads and
  # really executes identically to the original -- only its bytes (and
  # therefore its SHA-256) differ. This is a real, functional adversarial
  # artifact, not a mock: `node priv/graphlaw/graphlaw_host_probe.mjs version`
  # against the result reports the identical `graphlaw_version()` string.
  defp append_functional_custom_section(bytes) when is_binary(bytes) do
    name = "ash_a2a_regression_probe"
    payload = :crypto.strong_rand_bytes(32)
    content = leb128(byte_size(name)) <> name <> payload
    section = <<0>> <> leb128(byte_size(content)) <> content
    bytes <> section
  end

  # Unsigned LEB128, the integer encoding the WebAssembly binary format uses
  # for section/name lengths.
  defp leb128(n) when n < 0x80, do: <<n>>

  defp leb128(n) do
    low = rem(n, 0x80)
    rest = div(n, 0x80)
    <<low + 0x80>> <> leb128(rest)
  end

  describe "standing/3 -- what counts as an admitted judge" do
    setup do
      staged = stage()
      {:ok, manifest} = RootManifest.load(staged.path, require_engine: false)
      %{staged: staged, manifest: manifest}
    end

    @tag :graphlaw_engine
    test "a pinned artifact whose bytes match has standing", %{manifest: manifest} do
      assert {:ok, pin} =
               MetaAdmission.standing(
                 manifest,
                 "conformance/shapes/command_envelope.shacl.ttl",
                 "shacl_shapes"
               )

      assert Map.fetch!(pin, "kind") == "shacl_shapes"
      assert String.starts_with?(Map.fetch!(pin, "digest"), "sha256:")
    end

    @tag :graphlaw_engine
    test "a real, well-formed, UNPINNED artifact has no standing", %{manifest: manifest} do
      rogue = ConformanceCorpus.unpinned_falsifiers().shacl_shapes

      # It really exists and is really valid SHACL...
      assert File.exists?(RootManifest.resolve(manifest, rogue))

      # ...and being valid SHACL is not standing.
      assert {:error, %{code: :REFUSED_META_RIGOR, detail: detail}} =
               MetaAdmission.standing(manifest, rogue, "shacl_shapes")

      assert detail.reason == :not_pinned
      assert detail.artifact == rogue
      assert detail.invariant == "NOT Standing(v) => NOT Validates(v, x)"
    end

    @tag :graphlaw_engine
    test "a pinned artifact under the WRONG kind has no standing", %{manifest: manifest} do
      assert {:error, %{code: :REFUSED_META_RIGOR, detail: %{reason: :not_pinned}}} =
               MetaAdmission.standing(
                 manifest,
                 "conformance/shapes/command_envelope.shacl.ttl",
                 "n3_rules"
               )
    end

    @tag :graphlaw_engine
    test "standing is re-checked at USE time, catching a post-load swap", %{
      staged: staged,
      manifest: manifest
    } do
      shapes_relative = "conformance/shapes/command_envelope.shacl.ttl"
      assert {:ok, _} = MetaAdmission.standing(manifest, shapes_relative, "shacl_shapes")

      # Swap the judge AFTER the manifest was loaded and verified. Load-time
      # verification alone would have left this hole wide open.
      File.write!(
        Path.join(staged.root, shapes_relative),
        File.read!(Path.join(staged.root, ConformanceCorpus.unpinned_falsifiers().shacl_shapes))
      )

      assert {:error, %{code: :REFUSED_META_RIGOR, detail: detail}} =
               MetaAdmission.standing(manifest, shapes_relative, "shacl_shapes")

      assert detail.reason == :digest_drift
      refute detail.pinned == detail.actual
    end

    @tag :graphlaw_engine
    test "a pinned artifact that vanished has no standing", %{
      staged: staged,
      manifest: manifest
    } do
      File.rm!(Path.join(staged.root, "conformance/rules/derivation.n3"))

      assert {:error, %{code: :REFUSED_META_RIGOR, detail: %{reason: :artifact_missing}}} =
               MetaAdmission.standing(manifest, "conformance/rules/derivation.n3", "n3_rules")
    end

    @tag :graphlaw_engine
    test "every RFC S20 artifact kind is enumerated" do
      kinds = MetaAdmission.artifact_kinds()

      for required <- ~w(shex_schema shacl_shapes n3_rules datalog_program sparql_falsifier
                         planning_domain generator authority_policy receipt_schema
                         semantic_mapping) do
        assert required in kinds
      end
    end
  end

  describe "the engine is machinery too" do
    @tag :graphlaw_engine
    test "an unverified engine refuses every engine-backed operation" do
      staged = stage()
      {:ok, manifest} = RootManifest.load(staged.path, require_engine: false)
      refute manifest.engine_verified?

      assert {:error, %{code: :REFUSED_META_RIGOR, detail: %{reason: :engine_unverified}}} =
               MetaAdmission.validate(manifest, @valid_data, @pinned_machinery)

      assert {:error, %{code: :REFUSED_META_RIGOR, detail: %{reason: :engine_unverified}}} =
               MetaAdmission.canonical_derivation(
                 manifest,
                 @valid_data,
                 "conformance/rules/derivation.n3"
               )
    end
  end

  if @engine_available do
    describe "INVARIANT 1 -- NOT Standing(v) => NOT Validates(v, x)" do
      setup do
        staged = stage()
        {:ok, manifest} = RootManifest.load(staged.path)
        assert manifest.engine_verified?
        %{staged: staged, manifest: manifest}
      end

      test "admitted machinery over a valid graph really validates", %{manifest: manifest} do
        assert {:ok, result} = MetaAdmission.validate(manifest, @valid_data, @pinned_machinery)

        assert result.admitted?
        assert MetaAdmission.admitted?(result)
        assert dialect(result, "SHACL")["status"] == "ADMITTED"
        assert dialect(result, "SHEX")["status"] == "ADMITTED"
        assert result.graph_hash =~ ~r/\A[0-9a-f]{64}\z/
        assert result.manifest_digest == manifest.digest
        assert length(result.standing) == 4
      end

      test "admitted machinery REFUSES an invalid graph -- a data verdict, not a meta refusal", %{
        manifest: manifest
      } do
        machinery =
          Keyword.put(
            @pinned_machinery,
            :shape_map,
            "conformance/schema/invalid_command.shapemap"
          )

        assert {:ok, result} = MetaAdmission.validate(manifest, @invalid_data, machinery)

        # The machinery ran (hence {:ok, ...}); the DATA was refused.
        refute result.admitted?
        assert dialect(result, "SHACL")["status"] == "REFUSED"
        assert dialect(result, "SHACL")["detail"] =~ "1 violations"
        assert dialect(result, "SHEX")["status"] == "REFUSED"
      end

      test "FALSIFIER: unpinned shapes are refused even over a PERFECTLY VALID data graph", %{
        manifest: manifest
      } do
        rogue = ConformanceCorpus.unpinned_falsifiers().shacl_shapes
        machinery = Keyword.put(@pinned_machinery, :shapes, rogue)

        # Baseline: this exact data graph passes the admitted machinery.
        assert {:ok, baseline} = MetaAdmission.validate(manifest, @valid_data, @pinned_machinery)
        assert baseline.admitted?

        # Swap in an unpinned judge and the SAME valid data is refused --
        # not because the data is bad, but because the judge has no standing.
        assert {:error, %{code: :REFUSED_META_RIGOR, detail: detail}} =
                 MetaAdmission.validate(manifest, @valid_data, machinery)

        assert detail.reason == :not_pinned
        assert detail.artifact == rogue
        assert detail.kind == "shacl_shapes"
      end

      test "FALSIFIER (the attack this closes): unpinned shapes would LAUNDER an invalid graph",
           %{
             manifest: manifest
           } do
        rogue = ConformanceCorpus.unpinned_falsifiers().shacl_shapes
        machinery = Keyword.put(@pinned_machinery, :shapes, rogue)

        # 1. Meta-admission refuses to use the unpinned judge at all.
        assert {:error, %{code: :REFUSED_META_RIGOR}} =
                 MetaAdmission.validate(manifest, @invalid_data, machinery)

        # 2. Prove that refusal was load-bearing rather than merely cautious,
        #    by really running the engine directly with the same rogue shapes
        #    over the same invalid data, bypassing meta-admission.
        resolve = &RootManifest.resolve(manifest, &1)

        assert {:ok, laundered} =
                 EngineProbe.validate_all(
                   data: resolve.(@invalid_data),
                   profile: resolve.(@pinned_machinery[:profile]),
                   shapes: resolve.(rogue),
                   schema: resolve.(@pinned_machinery[:schema]),
                   shape_map: resolve.("conformance/schema/invalid_command.shapemap")
                 )

        laundered_shacl =
          laundered |> Map.fetch!("dialects") |> Enum.find(&(&1["dialect"] == "SHACL"))

        # The unpinned judge really admits the graph the admitted judge refused.
        assert laundered_shacl["status"] == "ADMITTED"
        assert laundered_shacl["detail"] =~ "0 violations"

        # 3. And with the admitted judge, the same graph is really refused.
        assert {:ok, honest} =
                 MetaAdmission.validate(
                   manifest,
                   @invalid_data,
                   Keyword.put(
                     @pinned_machinery,
                     :shape_map,
                     "conformance/schema/invalid_command.shapemap"
                   )
                 )

        refute honest.admitted?
        assert dialect(honest, "SHACL")["status"] == "REFUSED"
      end

      test "an unpinned ShEx schema is refused before the engine is reached", %{
        staged: staged,
        manifest: manifest
      } do
        unpinned_schema = "conformance/schema/rogue.shexj"

        File.write!(
          Path.join(staged.root, unpinned_schema),
          File.read!(Path.join(staged.root, @pinned_machinery[:schema]))
        )

        machinery = Keyword.put(@pinned_machinery, :schema, unpinned_schema)

        assert {:error, %{code: :REFUSED_META_RIGOR, detail: detail}} =
                 MetaAdmission.validate(manifest, @valid_data, machinery)

        assert detail.reason == :not_pinned
        assert detail.kind == "shex_schema"
      end

      test "a missing input data graph is refused without a fabricated verdict", %{
        manifest: manifest
      } do
        assert {:error, %{code: :REFUSED_META_RIGOR, detail: %{reason: :input_graph_missing}}} =
                 MetaAdmission.validate(manifest, "conformance/data/nope.ttl", @pinned_machinery)
      end
    end

    describe "INVARIANT 2 -- NOT Standing(r) => NOT CanonicalDerivation(r)" do
      setup do
        staged = stage()
        {:ok, manifest} = RootManifest.load(staged.path)
        %{staged: staged, manifest: manifest}
      end

      test "an admitted rule set really derives, with a real canonical graph hash", %{
        manifest: manifest
      } do
        assert {:ok, result} =
                 MetaAdmission.canonical_derivation(
                   manifest,
                   @valid_data,
                   "conformance/rules/derivation.n3"
                 )

        assert result.status == "ADMITTED"
        assert result.graph_hash =~ ~r/\A[0-9a-f]{64}\z/
        assert Map.fetch!(result.rules, "kind") == "n3_rules"
        assert result.manifest_digest == manifest.digest
      end

      test "FALSIFIER: an unpinned rule set never reaches the engine", %{manifest: manifest} do
        rogue = ConformanceCorpus.unpinned_falsifiers().n3_rules

        # It is a real, well-formed N3 rule file sitting right there...
        assert File.exists?(RootManifest.resolve(manifest, rogue))

        # ...and it cannot contribute a single derived triple.
        assert {:error, %{code: :REFUSED_META_RIGOR, detail: detail}} =
                 MetaAdmission.canonical_derivation(manifest, @valid_data, rogue)

        assert detail.reason == :not_pinned
        assert detail.kind == "n3_rules"
      end

      test "a rule set swapped after load is caught by the use-time digest check", %{
        staged: staged,
        manifest: manifest
      } do
        rules = "conformance/rules/derivation.n3"

        File.write!(
          Path.join(staged.root, rules),
          File.read!(Path.join(staged.root, ConformanceCorpus.unpinned_falsifiers().n3_rules))
        )

        assert {:error, %{code: :REFUSED_META_RIGOR, detail: %{reason: :digest_drift}}} =
                 MetaAdmission.canonical_derivation(manifest, @valid_data, rules)
      end
    end

    describe "canonical graph identity comes from the engine, never from Elixir" do
      test "the engine's RDFC-1.0 hash is order- and prefix-label-independent" do
        staged = stage()
        {:ok, manifest} = RootManifest.load(staged.path)

        original = RootManifest.resolve(manifest, @valid_data)

        reordered = Path.join(staged.root, "conformance/data/valid_command_reordered.ttl")

        File.write!(reordered, """
        @prefix zz:   <urn:ash-a2a:vocab:> .
        @prefix other: <urn:ash-a2a:conformance:> .

        other:command-001 zz:payloadDigest "sha256:0000000000000000000000000000000000000000000000000000000000000001" .
        other:command-001 zz:principalId   "principal:conformance-operator" .
        other:command-001 zz:capabilityId  "conformance:echo" .
        other:command-001 a                zz:Command .
        """)

        assert {:ok, a} = EngineProbe.graph_hash(original)
        assert {:ok, b} = EngineProbe.graph_hash(reordered)

        # Different prefix labels, different triple order, same canonical graph.
        refute File.read!(original) == File.read!(reordered)
        assert a == b

        # And a genuinely different graph hashes differently.
        assert {:ok, c} = EngineProbe.graph_hash(RootManifest.resolve(manifest, @invalid_data))
        refute a == c
      end
    end

    describe "engine standing is bound to USE time, not just load time" do
      setup do
        wasm_copy =
          Path.join(
            System.tmp_dir!(),
            "graphlaw_engine_copy_#{System.unique_integer([:positive, :monotonic])}.wasm"
          )

        File.cp!(EngineProbe.wasm_path([]), wasm_copy)
        on_exit(fn -> File.rm(wasm_copy) end)

        staged = Sa2aCorpus.stage!(engine_path: wasm_copy)
        on_exit(fn -> Sa2aCorpus.cleanup(staged.root) end)

        {:ok, manifest} = RootManifest.load(staged.path, wasm_path: wasm_copy)
        assert manifest.engine_verified?
        assert {:ok, expected_digest} = RootManifest.artifact_digest(wasm_copy)
        assert manifest.engine_verified_digest == expected_digest

        machinery = Keyword.put(@pinned_machinery, :wasm_path, wasm_copy)

        %{staged: staged, manifest: manifest, wasm_copy: wasm_copy, machinery: machinery}
      end

      test "(b) an unchanged engine artifact continues to authorize every call",
           %{manifest: manifest, machinery: machinery} do
        assert {:ok, first} = MetaAdmission.validate(manifest, @valid_data, machinery)
        assert first.admitted?

        assert {:ok, second} = MetaAdmission.validate(manifest, @valid_data, machinery)
        assert second.admitted?

        assert {:ok, derived} =
                 MetaAdmission.canonical_derivation(
                   manifest,
                   @valid_data,
                   "conformance/rules/derivation.n3",
                   wasm_path: machinery[:wasm_path]
                 )

        assert derived.status == "ADMITTED"
      end

      test "(a) a byte-altered, same-version engine swapped in after load is refused at use time",
           %{manifest: manifest, machinery: machinery, wasm_copy: wasm_copy} do
        # Baseline: the load-time-verified engine authorizes normally before any swap.
        assert {:ok, baseline} = MetaAdmission.validate(manifest, @valid_data, machinery)
        assert baseline.admitted?

        original_bytes = File.read!(wasm_copy)
        altered_bytes = append_functional_custom_section(original_bytes)
        refute altered_bytes == original_bytes

        # Swap the artifact AFTER load-time verification succeeded, BEFORE use.
        # This is the exact TOCTOU repro: load-time verification passed once,
        # against artifact A; execution now re-resolves the SAME path and must
        # not go on trusting it.
        File.write!(wasm_copy, altered_bytes)

        # The altered artifact is real and FUNCTIONAL -- it reports the
        # IDENTICAL version string the manifest expects. A version check
        # alone would not catch this swap; the bare `engine_verified?`
        # boolean this branch used to gate on would not either. Only a
        # real digest re-check at use time catches it.
        assert {:ok, "praxis-graphlaw v26.7.5"} = EngineProbe.version(wasm_path: wasm_copy)
        refute manifest.engine_verified_digest == RootManifest.digest_bytes(altered_bytes)

        assert {:error, %{code: :REFUSED_META_RIGOR, detail: detail}} =
                 MetaAdmission.validate(manifest, @valid_data, machinery)

        assert detail.reason == :engine_digest_drift
        assert detail.expected == manifest.engine_verified_digest
        refute detail.expected == detail.observed

        assert {:error, %{code: :REFUSED_META_RIGOR, detail: derivation_detail}} =
                 MetaAdmission.canonical_derivation(
                   manifest,
                   @valid_data,
                   "conformance/rules/derivation.n3",
                   wasm_path: wasm_copy
                 )

        assert derivation_detail.reason == :engine_digest_drift
      end
    end
  else
    test "SKIPPED: praxis-graphlaw engine not resolvable on this host" do
      # Named, visible skip -- the engine-backed invariant tests require the
      # real wasm. Never substituted with a mock.
      refute EngineProbe.available?()
    end
  end
end

# --- SECTION 13: Original test/ash_a2a/semantic/package_store_bounds_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.PackageStoreBoundsTest do
  @moduledoc """
  SEC-09 court: `AshA2A.Semantic.PackageStore` is bounded (FIFO eviction at
  `:max_entries`, per-entry TTL). Real, uniquely named GenServer per test;
  real `ExecutionPackage` structs.
  """
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{ExecutionPackage, PackageStore}

  defp start_store(opts) do
    name = :"#{__MODULE__}.#{System.unique_integer([:positive])}"
    start_supervised!({PackageStore, Keyword.put(opts, :name, name)})
    [name: name]
  end

  # Only the fingerprint is load-bearing for the store's keying; the other
  # enforced keys are carried as nil (the store never inspects them).
  defp package(fp) do
    %ExecutionPackage{
      fingerprint: fp,
      source: nil,
      semantic_ir: nil,
      ontology: nil,
      planning_ir: nil,
      plan_candidate: nil
    }
  end

  test "evicts the oldest entry once max_entries is exceeded" do
    store = start_store(max_entries: 2, ttl_ms: 60_000)

    for fp <- ["a", "b", "c"], do: :ok = PackageStore.put(package(fp), store)

    assert PackageStore.size(store) == 2
    assert PackageStore.fetch("a", store) == :error
    assert {:ok, %ExecutionPackage{fingerprint: "b"}} = PackageStore.fetch("b", store)
    assert {:ok, %ExecutionPackage{fingerprint: "c"}} = PackageStore.fetch("c", store)
  end

  test "re-putting a fingerprint refreshes its FIFO position" do
    store = start_store(max_entries: 2, ttl_ms: 60_000)

    :ok = PackageStore.put(package("a"), store)
    :ok = PackageStore.put(package("b"), store)
    :ok = PackageStore.put(package("a"), store)
    :ok = PackageStore.put(package("c"), store)

    assert PackageStore.fetch("b", store) == :error
    assert {:ok, _} = PackageStore.fetch("a", store)
    assert PackageStore.size(store) == 2
  end

  test "an entry past its TTL fetches as :error and is removed" do
    store = start_store(max_entries: 10, ttl_ms: 1)

    :ok = PackageStore.put(package("ephemeral"), store)
    Process.sleep(5)

    assert PackageStore.fetch("ephemeral", store) == :error
    assert PackageStore.size(store) == 0
  end

  test "malformed bounds fall back to the bounded defaults instead of disabling eviction" do
    store = start_store(max_entries: "2", ttl_ms: "soon")
    %{max_entries: max, ttl_ms: ttl} = :sys.get_state(store[:name])
    assert max == 10_000
    assert ttl == :timer.hours(1)
    :ok = PackageStore.put(package("x"), store)
    assert {:ok, _} = PackageStore.fetch("x", store)
  end

  test "defaults are bounded" do
    store = start_store([])
    %{max_entries: max, ttl_ms: ttl} = :sys.get_state(store[:name])
    assert max == 10_000
    assert ttl == :timer.hours(1)
  end
end

# --- SECTION 14: Original test/ash_a2a/semantic/peer_capability_reconciliation_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.PeerCapabilityReconciliationTest do
  @moduledoc """
  Chicago-school tests proving the PRD §14 / ARD §14 gap is closed:
  `AshA2A.Semantic.Peer.admit/2`'s own admission decision now reconciles an
  envelope's claimed capability label against this peer's own capability
  identity through the real, already-tested
  `AshA2A.Semantic.MappingRegistry.reconcile/3` (RFC-SA2A-001 S47), instead of
  the two mechanisms sitting side by side, real and tested, but unwired.

  Real collaborators throughout: the real compiled `Ash.Domain`/`Ash.Resource`
  pair `AshA2A.Test.SemanticPeerFixture.{Domain, Ordering}` (already used by
  the cross-peer and agent-card suites), the real
  `AshA2A.Semantic.AgentCard.from_skill/2` derivation, a real
  `AshA2A.Semantic.MappingRegistry`, a real `AshA2A.ReceiptStore.Memory`
  process for the admitted-mapping case (via the real
  `AshA2A.Chicago.Fixtures.CanonicalIdentity` fixture helpers), and real
  `AshA2A.Semantic.Peer`/`Envelope` structs. Nothing here is mocked, stubbed
  or patched -- there is no collaborator infeasible to run for real.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Chicago.Fixtures.CanonicalIdentity
  alias AshA2A.Semantic.{AgentCard, Envelope, MappingRegistry, Peer, PeerCapabilityReconciliation}
  alias AshA2A.Test.SemanticPeerFixture.Domain

  # The real IRI `AshA2A.Semantic.AgentCard.from_skill/2` derives for
  # `Domain`'s named `place_order` skill (`skill :place_order, :create`),
  # resolved through the same real `AshA2A.Info.skill/2` selector lookup
  # `PeerCapabilityReconciliation.reconcile/2` itself uses -- computed once,
  # asserted as real state in the first test below, never hand-typed.
  defp own_place_order_iri do
    {:ok, skill} = AshA2A.Info.skill(Domain, "place_order")
    AgentCard.from_skill(skill).capability_iri
  end

  defp envelope(provenance) do
    Envelope.new!(
      envelope_id: "urn:uuid:pcr-" <> Ash.UUIDv7.generate(),
      kind: "sa2a:Request",
      semantic_basis: ["urn:sa2a:basis:pcr-test:v1"],
      provenance: provenance,
      graph: %{
        media_type: "text/turtle",
        digest: "blake3:pcr-test",
        content: "@prefix ex: <http://example.org/> .\nex:a ex:p ex:o .\n"
      }
    )
  end

  describe "claimed_capability/1" do
    test "nil when provenance names no capability claim at all" do
      refute PeerCapabilityReconciliation.claimed_capability(envelope(%{"agent" => "peer-a"}))
    end

    test "nil when only one half of the claim is present" do
      refute PeerCapabilityReconciliation.claimed_capability(
               envelope(%{"capability_label" => "place_order"})
             )

      refute PeerCapabilityReconciliation.claimed_capability(
               envelope(%{"capability_iri" => "urn:example:x"})
             )
    end

    test "the real {label, iri} claim, string-keyed exactly as the wire carries it" do
      claim =
        PeerCapabilityReconciliation.claimed_capability(
          envelope(%{
            "agent" => "peer-a",
            "capability_label" => "place_order",
            "capability_iri" => "http://example.org/acme#PlaceOrder"
          })
        )

      assert claim == %{label: "place_order", iri: "http://example.org/acme#PlaceOrder"}
    end
  end

  describe "this peer's own capability identity is real, derived state" do
    test "the named place_order skill resolves through the real AshA2A.Info.skill/2 selector, by name" do
      assert {:ok, skill} = AshA2A.Info.skill(Domain, "place_order")
      assert skill.name == :place_order
      assert skill.resource == AshA2A.Test.SemanticPeerFixture.Ordering
      # A real, derived IRI (from the real compiled {resource, action} id) --
      # not asserted as a hand-typed constant anywhere in this test module.
      assert AgentCard.from_skill(skill).capability_iri =~ "urn:sa2a:capability:"
    end

    test "Domain compiles three real skills (read/destroy default, place_order named)" do
      names = Domain |> AshA2A.Info.capability_index() |> Enum.map(& &1.name) |> Enum.sort()
      assert names == [:destroy, :place_order, :read]
    end
  end

  describe "reconcile/2" do
    test "no-op: envelope names no capability claim at all" do
      peer = Peer.new(name: "peer-b", capabilities: Domain)
      env = envelope(%{"agent" => "peer-a"})

      assert PeerCapabilityReconciliation.reconcile(peer, env) == :ok
    end

    test "no-op: this peer has no :capabilities configured" do
      peer = Peer.new(name: "peer-b")

      env =
        envelope(%{
          "capability_label" => "place_order",
          "capability_iri" => "http://example.org/acme#PlaceOrder"
        })

      assert PeerCapabilityReconciliation.reconcile(peer, env) == :ok
    end

    test "no-op: this peer exposes no capability under the claimed label" do
      peer = Peer.new(name: "peer-b", capabilities: Domain)

      env =
        envelope(%{
          "capability_label" => "cancel_order",
          "capability_iri" => "http://example.org/acme#CancelOrder"
        })

      assert PeerCapabilityReconciliation.reconcile(peer, env) == :ok
    end

    test "same label, SAME identity -- reconciles with no refusal" do
      peer = Peer.new(name: "peer-b", capabilities: Domain)

      env =
        envelope(%{
          "capability_label" => "place_order",
          "capability_iri" => own_place_order_iri()
        })

      assert PeerCapabilityReconciliation.reconcile(peer, env) == :ok
    end

    test "the real S47 case: same label, DIFFERENT identity, no admitted mapping -- refused" do
      peer = Peer.new(name: "peer-b", capabilities: Domain)

      env =
        envelope(%{
          "capability_label" => "place_order",
          "capability_iri" => "http://example.org/acme#PlaceOrder"
        })

      assert {:error, refusal} = PeerCapabilityReconciliation.reconcile(peer, env)
      assert refusal.code == :semantic_label_collision_unmapped
      assert refusal.detail =~ "place_order"
      assert refusal.detail =~ own_place_order_iri()
    end

    test "an admitted mapping between the two identities resolves the same collision" do
      CanonicalIdentity.with_store(fn store ->
        remote_iri = "http://example.org/acme#PlaceOrder"

        receipt =
          CanonicalIdentity.held_mapping_receipt(
            store,
            own_place_order_iri(),
            remote_iri,
            :exact_match
          )

        {:ok, registry} =
          MappingRegistry.new(receipt_store: {AshA2A.ReceiptStore.Memory, name: store})
          |> MappingRegistry.register(%{
            source: own_place_order_iri(),
            target: remote_iri,
            kind: :exact_match,
            admission_receipt: receipt
          })

        peer = Peer.new(name: "peer-b", capabilities: Domain, mapping_registry: registry)

        env =
          envelope(%{
            "capability_label" => "place_order",
            "capability_iri" => remote_iri
          })

        assert PeerCapabilityReconciliation.reconcile(peer, env) == :ok
      end)
    end
  end

  describe "wired into Peer.admit/2's real admission pipeline" do
    test "a colliding capability claim refuses the whole envelope before GraphLaw ever runs" do
      peer = Peer.new(name: "peer-b", capabilities: Domain)

      env =
        envelope(%{
          "agent" => "peer-a",
          "capability_label" => "place_order",
          "capability_iri" => "http://example.org/acme#PlaceOrder"
        })

      outcome = Peer.admit(peer, env)

      assert outcome.standing == :refused
      assert outcome.code == :semantic_label_collision_unmapped
      # Refused before the digest step ever ran -- there is no graph_digest
      # in a refusal this early, unlike a GraphLaw-stage refusal.
      refute Map.has_key?(outcome, :graph_digest)
    end

    test "the same envelope with no capability claim is never refused by this check" do
      peer = Peer.new(name: "peer-b", capabilities: Domain)
      env = envelope(%{"agent" => "peer-a"})

      outcome = Peer.admit(peer, env)

      refute outcome.code == :semantic_label_collision_unmapped
    end
  end
end

# --- SECTION 15: Original test/ash_a2a/semantic/policy_phenotype_benchmark_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.PolicyPhenotypeBenchmarkTest do
  @moduledoc """
  Real wall-clock benchmark + regression bound for
  `AshA2A.Semantic.PolicyPhenotype` (ash_a2a#41).

  Measures, with `:timer.tc/1` over a real warm-up and a real sample list
  (nearest-rank percentiles, same method as `bench/ash_a2a_bench.exs`):

    * `new/1` on the full nine-axis default vocabulary with reaction norms
      (the admission fence: option/duplicate/normalized-authority checks);
    * `condition/2` on the same phenotype (re-validation + reaction step);
    * `new/1` refusing a disguised authority axis (the refusal path);
    * `new/1` refusing a root split across interior token boundaries
      (`boldness_gr_ant_level`, the ash_a2a#45 second-court window check);
    * `new/1` admitting a 64-token benign axis name (worst realistic cost of
      the bounded adjacent-token window scan, which must stay linear).

  Each sample is a batch of `@batch` calls so per-call cost is above timer
  resolution. The numbers are printed and written to
  `receipts/v26.9.26/policy_phenotype_bench.json` when
  `POLICY_PHENOTYPE_BENCH_RECEIPT=1` (with `POLICY_PHENOTYPE_BENCH_PARENT` set to
  the commit the measured tree is committed on). The receipt carries the git
  blob id of the measured module; a non-benchmark test refuses a stale receipt.

  Regression bound: the median (p50) per-call cost must stay under
  `@p50_bound_us`. p50 is used, not p99, because this host is shared with
  other concurrent builds and its tails are dominated by scheduler noise
  (observed p99 swinging 250us-3100us run to run with an unchanged subject).
  The bound is set to catch the one regression actually observed while
  hardening: normalizing axis names through runtime-compiled Unicode regexes
  on every call measured p50 new/1 = 261-286us, condition/2 = 136-147us,
  refusal = 139-149us; the ASCII fast path measured p50 new/1 = 45-93us,
  condition/2 = 29-42us, refusal = 20-22us on the same loaded host. The
  `long_name` bound (2500us) catches the second regression observed while
  hardening ash_a2a#45: re-checking every run of up to 15 adjacent tokens
  measured 5198us per `new/1` on the 64-token name; the bounded left/right
  run scan measured 485-650us at load average ~140 (the 67f48618 fence
  without the window/digit checks: 145-180us). The committed receipt records
  the admitted run.

  Tagged `:benchmark` (excluded by default in `test/test_helper.exs`):

      mix test test/ash_a2a/semantic/policy_phenotype_benchmark_test.exs --include benchmark
  """
  use ExUnit.Case, async: false

  alias AshA2A.Semantic.PolicyPhenotype

  @moduletag :benchmark

  @warmup 200
  @samples 400
  @batch 50
  @p50_bound_us %{
    new: 200.0,
    condition: 120.0,
    refuse: 100.0,
    split_refuse: 100.0,
    long_name: 2500.0
  }

  defp full_opts do
    axes = PolicyPhenotype.default_axes()

    [
      capability_iri: "urn:sa2a:capability:Example.Search.read",
      policy_family: "planner:MCTS",
      conditionable_axes: Map.new(axes, &{&1, %{min: 0.0, max: 1.0}}),
      condition: Map.new(axes, &{&1, 0.5}),
      reaction_norms:
        axes
        |> Enum.with_index()
        |> Map.new(fn {a, i} -> {a, %{slope: (i - 4) / 10, reference_cue: 0.5}} end),
      evidence_refs: ["urn:evidence:temperament-engineering"]
    ]
  end

  defp measure(fun) do
    for _ <- 1..@warmup, do: fun.()

    samples =
      for _ <- 1..@samples do
        {us, _} = :timer.tc(fn -> for _ <- 1..@batch, do: fun.() end)
        us / @batch
      end
      |> Enum.sort()

    n = length(samples)
    pct = fn p -> Enum.at(samples, max(ceil(p * n) - 1, 0)) end

    %{
      p50_us: Float.round(pct.(0.50), 3),
      p95_us: Float.round(pct.(0.95), 3),
      p99_us: Float.round(pct.(0.99), 3),
      max_us: Float.round(List.last(samples), 3),
      samples: n,
      batch: @batch
    }
  end

  test "policy phenotype admission/conditioning stays within the regression bound" do
    opts = full_opts()
    {:ok, phenotype} = PolicyPhenotype.new(opts)

    refuse_opts =
      Keyword.update!(
        opts,
        :conditionable_axes,
        &Map.put(&1, "Execution-Grant", %{min: 0.0, max: 1.0})
      )

    assert {:error, %{code: :temperament_cannot_encode_authority}} =
             PolicyPhenotype.new(refuse_opts)

    split_opts =
      Keyword.update!(
        opts,
        :conditionable_axes,
        &Map.put(&1, "boldness_gr_ant_level", %{min: 0.0, max: 1.0})
      )

    assert {:error, %{code: :temperament_cannot_encode_authority}} =
             PolicyPhenotype.new(split_opts)

    long_axis = Enum.map_join(1..64, "_", &"trait#{&1}x")

    long_opts = [
      capability_iri: "urn:sa2a:capability:Example.Search.read",
      policy_family: "planner:MCTS",
      conditionable_axes: %{long_axis => %{min: 0.0, max: 1.0}}
    ]

    assert {:ok, _} = PolicyPhenotype.new(long_opts)

    results = %{
      new: measure(fn -> {:ok, _} = PolicyPhenotype.new(opts) end),
      condition: measure(fn -> {:ok, _} = PolicyPhenotype.condition(phenotype, 0.8) end),
      refuse: measure(fn -> {:error, _} = PolicyPhenotype.new(refuse_opts) end),
      split_refuse: measure(fn -> {:error, _} = PolicyPhenotype.new(split_opts) end),
      long_name: measure(fn -> {:ok, _} = PolicyPhenotype.new(long_opts) end)
    }

    IO.puts("\n[policy_phenotype_bench] " <> inspect(results))

    if System.get_env("POLICY_PHENOTYPE_BENCH_RECEIPT") == "1" do
      subject_path = "lib/ash_a2a/semantic/policy_phenotype.ex"
      content = File.read!(subject_path)

      # git blob id of the measured module, so the receipt names its exact
      # subject; a commit cannot contain its own SHA, so the commit identity is
      # the parent the measured tree is committed on (POLICY_PHENOTYPE_BENCH_PARENT).
      blob_sha1 =
        :crypto.hash(:sha, ["blob ", Integer.to_string(byte_size(content)), 0, content])
        |> Base.encode16(case: :lower)

      receipt = %{
        subject: "ash_a2a AshA2A.Semantic.PolicyPhenotype",
        subject_path: subject_path,
        subject_blob_sha1: blob_sha1,
        measured_on_parent: System.fetch_env!("POLICY_PHENOTYPE_BENCH_PARENT"),
        otp_release: to_string(:erlang.system_info(:otp_release)),
        elixir: System.version(),
        system_architecture: to_string(:erlang.system_info(:system_architecture)),
        method: "timer.tc, nearest-rank percentiles, per-call = batch time / batch",
        warmup: @warmup,
        bound_p50_us: @p50_bound_us,
        results: results
      }

      path = Path.join([File.cwd!(), "receipts", "v26.9.26", "policy_phenotype_bench.json"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, :json.format(receipt) |> IO.iodata_to_binary())
    end

    for {name, bound} <- @p50_bound_us do
      p50 = results[name].p50_us
      assert p50 < bound, "#{name} p50 #{p50}us exceeded regression bound #{bound}us"
    end
  end
end

# --- SECTION 16: Original test/ash_a2a/semantic/root_manifest_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.RootManifestTest do
  @moduledoc """
  Real tests for the SA2A content-addressed trust root (RFC S21).

  Chicago school throughout: real files on disk, real SHA-256 digests, real
  `AshA2A.Authority` structs, and -- where the engine is resolvable -- the
  real `praxis-graphlaw` wasm module executed as a real subprocess. Nothing
  here stubs a collaborator or asserts that a function "was called".
  """

  use ExUnit.Case, async: true

  alias AshA2A.{Authority, Identity}
  alias AshA2A.Semantic.RootManifest
  alias AshA2A.Semantic.RootManifest.{ConformanceCorpus, EngineProbe}
  alias AshA2A.Test.Support.Sa2aCorpus

  @engine_available EngineProbe.available?()

  defp stage(opts \\ []) do
    staged = Sa2aCorpus.stage!(opts)
    on_exit(fn -> Sa2aCorpus.cleanup(staged.root) end)
    staged
  end

  defp custodian(subject_value \\ "root-custodian-1") do
    principal = Identity.principal(subject_value)

    {principal,
     Authority.new(principal, RootManifest.mutation_capability_id(), source: :root_custodian)}
  end

  describe "content address coverage" do
    test "every struct field is either addressed or explicitly unaddressed" do
      struct_fields =
        %RootManifest{} |> Map.from_struct() |> Map.keys() |> Enum.sort()

      declared =
        Enum.sort(RootManifest.addressed_fields() ++ RootManifest.unaddressed_fields())

      # A field added later that is neither addressed nor deliberately
      # excluded would silently fall outside the content address. This is the
      # mechanical check that closes that hole.
      assert struct_fields == declared
    end

    test "machine-local values are excluded from the address" do
      assert :root in RootManifest.unaddressed_fields()
      assert :digest in RootManifest.unaddressed_fields()
      assert :engine_verified? in RootManifest.unaddressed_fields()
      assert :verified_at in RootManifest.unaddressed_fields()
    end
  end

  describe "content addressing" do
    @tag :graphlaw_engine
    test "the committed manifest's recorded digest is reproduced by rebuilding from the real corpus" do
      {:ok, rebuilt} = ConformanceCorpus.build()

      committed =
        ConformanceCorpus.manifest_path()
        |> File.read!()
        |> JSON.decode!()
        |> Map.fetch!("digest")

      assert rebuilt.digest == committed
      assert String.starts_with?(rebuilt.digest, "sha256:")
      assert byte_size(rebuilt.digest) == 7 + 64
    end

    @tag :graphlaw_engine
    test "the content address is INDEPENDENT of where the corpus lives on disk" do
      {:ok, at_priv} = ConformanceCorpus.build()
      staged = stage()

      # Same bytes, different absolute root. Two runtimes never agree on
      # absolute paths, so a path-dependent address could never be shared.
      refute staged.root == ConformanceCorpus.root()
      assert staged.manifest.digest == at_priv.digest
    end

    test "canonical_form sorts keys, so the address survives large non-sorted maps" do
      # >32 keys forces Elixir's hashmap representation, whose iteration order
      # is NOT sorted -- a real test of the sorting rather than a tautology.
      keys = for i <- 1..40, do: "k#{i}"
      forward = keys |> Enum.map(&{&1, &1}) |> Map.new()
      reverse = keys |> Enum.reverse() |> Enum.map(&{&1, &1}) |> Map.new()

      refute Map.keys(forward) == Enum.sort(Map.keys(forward)),
             "expected an unsorted hashmap iteration order for this test to be meaningful"

      a = %RootManifest{version_policy: forward}
      b = %RootManifest{version_policy: reverse}

      assert IO.iodata_to_binary(RootManifest.canonical_form(a)) ==
               IO.iodata_to_binary(RootManifest.canonical_form(b))

      assert RootManifest.content_digest(a) == RootManifest.content_digest(b)
    end

    @tag :graphlaw_engine
    test "changing any addressed field moves the content address" do
      {:ok, manifest} = ConformanceCorpus.build()
      moved = %{manifest | version_policy: Map.put(manifest.version_policy, "extra", "x")}

      refute RootManifest.content_digest(moved) == manifest.digest
    end

    @tag :graphlaw_engine
    test "changing an UNADDRESSED field does not move the content address" do
      {:ok, manifest} = ConformanceCorpus.build()
      relocated = %{manifest | root: "/somewhere/else", verified_at: DateTime.utc_now()}

      assert RootManifest.content_digest(relocated) == manifest.digest
    end
  end

  describe "load/2 fails closed" do
    test "refuses a missing manifest" do
      assert {:error, %{code: :REFUSED_MANIFEST_NOT_FOUND}} =
               RootManifest.load("/nonexistent/sa2a/root_manifest.json", require_engine: false)
    end

    @tag :graphlaw_engine
    test "refuses a manifest whose recorded digest does not match its contents" do
      staged = stage()

      tampered =
        staged.path
        |> File.read!()
        |> JSON.decode!()
        |> put_in(["version_policy", "ordinary_transport_agents_may_mutate"], true)
        |> JSON.encode!()

      File.write!(staged.path, tampered)

      assert {:error, %{code: :REFUSED_MANIFEST_DIGEST_MISMATCH, detail: detail}} =
               RootManifest.load(staged.path, require_engine: false)

      assert detail.recorded != detail.recomputed
    end

    @tag :graphlaw_engine
    test "refuses when a pinned artifact's real bytes drifted" do
      staged = stage()
      shapes = Path.join(staged.root, "conformance/shapes/command_envelope.shacl.ttl")
      File.write!(shapes, File.read!(shapes) <> "\n# silently appended\n")

      assert {:error, %{code: :REFUSED_MANIFEST_DRIFT, detail: detail}} =
               RootManifest.load(staged.path, require_engine: false)

      assert detail.path == "conformance/shapes/command_envelope.shacl.ttl"
      assert detail.kind == "shacl_shapes"
      refute detail.pinned == detail.actual
    end

    @tag :graphlaw_engine
    test "refuses when a pinned artifact is gone" do
      staged = stage()
      File.rm!(Path.join(staged.root, "conformance/rules/derivation.n3"))

      assert {:error, %{code: :REFUSED_MANIFEST_ARTIFACT_MISSING}} =
               RootManifest.load(staged.path, require_engine: false)
    end

    @tag :graphlaw_engine
    test "refuses a malformed (non-JSON-object) manifest" do
      staged = stage()
      File.write!(staged.path, "not json at all")

      assert {:error, %{code: :REFUSED_MANIFEST_MALFORMED}} =
               RootManifest.load(staged.path, require_engine: false)
    end

    @tag :graphlaw_engine
    test "refuses a manifest missing a required field" do
      staged = stage()

      stripped = staged.path |> File.read!() |> JSON.decode!() |> Map.delete("validators")
      File.write!(staged.path, JSON.encode!(stripped))

      assert {:error,
              %{code: :REFUSED_MANIFEST_MALFORMED, detail: %{missing_fields: [:validators]}}} =
               RootManifest.load(staged.path, require_engine: false)
    end

    @tag :graphlaw_engine
    test "require_engine: false yields a manifest explicitly marked unverified" do
      staged = stage()
      assert {:ok, manifest} = RootManifest.load(staged.path, require_engine: false)
      refute manifest.engine_verified?
    end
  end

  if @engine_available do
    describe "engine identity (real praxis-graphlaw wasm executed)" do
      test "the engine really reports the version the manifest pins" do
        assert {:ok, version} = EngineProbe.version()
        assert version == ConformanceCorpus.expected_engine_version()
      end

      test "the pinned engine artifact's real sha256 matches the pin" do
        {:ok, manifest} = ConformanceCorpus.build()
        {:ok, actual} = RootManifest.artifact_digest(EngineProbe.wasm_path())

        assert Map.fetch!(manifest.engine, "artifact_digest") == actual
      end

      test "a fully verified load marks the engine verified" do
        staged = stage()
        assert {:ok, manifest} = RootManifest.load(staged.path)
        assert manifest.engine_verified?
        assert %DateTime{} = manifest.verified_at
      end

      test "refuses when the engine reports a different version than pinned" do
        staged = stage(expected_version: "praxis-graphlaw v0.0.0-not-the-pinned-build")

        assert {:error, %{code: :REFUSED_MANIFEST_ENGINE_DRIFT, detail: detail}} =
                 RootManifest.load(staged.path)

        assert detail.reason == :version_mismatch
        assert detail.expected == "praxis-graphlaw v0.0.0-not-the-pinned-build"
        assert detail.actual == ConformanceCorpus.expected_engine_version()
      end

      test "refuses when the resolved engine artifact is not the pinned one" do
        staged = stage()
        other_real_file = EngineProbe.host_path()

        assert {:error, %{code: :REFUSED_MANIFEST_ENGINE_DRIFT, detail: detail}} =
                 RootManifest.load(staged.path, wasm_path: other_real_file)

        assert detail.reason == :artifact_digest_mismatch
        refute detail.pinned == detail.actual
      end

      test "refuses when the engine artifact cannot be resolved at all" do
        staged = stage()

        assert {:error, %{code: :REFUSED_MANIFEST_ENGINE_DRIFT, detail: %{reason: reason}}} =
                 RootManifest.load(staged.path, wasm_path: "/nonexistent/graphlaw.wasm")

        assert reason == :engine_artifact_missing
      end
    end
  else
    test "SKIPPED: praxis-graphlaw engine not resolvable on this host" do
      # A named, visible skip -- never a silent mock substitution. Set
      # GRAPHLAW_WASM (or config :ash_a2a, :graphlaw_wasm_path) to the real
      # praxis_graphlaw_wasm_bg.wasm to run the engine-backed cases.
      refute EngineProbe.available?()
    end
  end

  describe "mutate/5 -- no ordinary agent may mutate the trust root" do
    setup do
      staged = stage()
      {:ok, manifest} = RootManifest.load(staged.path, require_engine: false)
      %{manifest: manifest}
    end

    @tag :graphlaw_engine
    test "an ordinary transport-verified agent is refused even with the right capability and subject",
         %{manifest: manifest} do
      # This is the exact authority an ordinary authenticated A2A caller gets.
      ordinary =
        Authority.from_verified_identity("agent-7", RootManifest.mutation_capability_id())

      # It genuinely admits for the capability -- the capability check passes.
      assert Authority.admits?(ordinary, %{
               principal_id: ordinary.subject,
               capability_id: RootManifest.mutation_capability_id()
             })

      # And it is still structurally refused, on custody source.
      assert {:error, %{code: :REFUSED_ROOT_CUSTODY, detail: detail}} =
               RootManifest.mutate(
                 manifest,
                 %{version_policy: %{"ordinary_transport_agents_may_mutate" => true}},
                 ordinary,
                 ordinary.subject,
                 require_engine: false
               )

      assert detail.actual_source == :transport_verified
      assert detail.required_source == RootManifest.custody_source()
    end

    @tag :graphlaw_engine
    test "an authority whose subject does not match the independently supplied principal is refused",
         %{manifest: manifest} do
      {_alice, authority} = custodian("alice")
      bob = Identity.principal("bob")

      # The tautological version of this check (comparing authority.subject
      # against itself) would have passed here. It must not.
      assert {:error, %{code: :authority_mismatch}} =
               RootManifest.mutate(manifest, %{manufacturers: []}, authority, bob,
                 require_engine: false
               )
    end

    @tag :graphlaw_engine
    test "an expired custodian authority is refused", %{manifest: manifest} do
      principal = Identity.principal("root-custodian-expired")

      expired =
        Authority.new(principal, RootManifest.mutation_capability_id(),
          source: :root_custodian,
          expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
        )

      assert {:error, %{code: :authority_mismatch}} =
               RootManifest.mutate(manifest, %{manufacturers: []}, expired, principal,
                 require_engine: false
               )
    end

    @tag :graphlaw_engine
    test "a custodian authority for the wrong capability is refused", %{manifest: manifest} do
      principal = Identity.principal("root-custodian-1")
      wrong = Authority.new(principal, "some:other:capability", source: :root_custodian)

      assert {:error, %{code: :authority_mismatch}} =
               RootManifest.mutate(manifest, %{manufacturers: []}, wrong, principal,
                 require_engine: false
               )
    end

    @tag :graphlaw_engine
    test "a nil authority is refused", %{manifest: manifest} do
      assert {:error, %{code: :authority_mismatch}} =
               RootManifest.mutate(
                 manifest,
                 %{manufacturers: []},
                 nil,
                 Identity.principal("whoever"),
                 require_engine: false
               )
    end

    @tag :graphlaw_engine
    test "a non-principal identity is refused", %{manifest: manifest} do
      {_p, authority} = custodian()

      assert {:error, %{code: :authority_mismatch}} =
               RootManifest.mutate(
                 manifest,
                 %{manufacturers: []},
                 authority,
                 Identity.agent("not-a-principal"),
                 require_engine: false
               )
    end

    @tag :graphlaw_engine
    test "an unknown field is refused and no new atom is created", %{manifest: manifest} do
      {principal, authority} = custodian()
      # A global atom_count comparison races with every other async test that
      # interns atoms; assert on the exact key instead.
      unknown =
        "totally_made_up_field_qwerty_" <> Integer.to_string(System.unique_integer([:positive]))

      assert {:error, %{code: :REFUSED_MANIFEST_MALFORMED, detail: detail}} =
               RootManifest.mutate(
                 manifest,
                 %{unknown => 1},
                 authority,
                 principal,
                 require_engine: false
               )

      assert :"$unknown" in detail.unmutable_or_unknown_fields
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
    end

    @tag :graphlaw_engine
    test "a real custodian mutation succeeds and MOVES the content address", %{manifest: manifest} do
      {principal, authority} = custodian()
      original_digest = manifest.digest

      assert {:ok, mutated} =
               RootManifest.mutate(
                 manifest,
                 %{manufacturers: manifest.manufacturers ++ [%{"id" => "new-manufacturer"}]},
                 authority,
                 principal,
                 require_engine: false
               )

      refute mutated.digest == original_digest
      assert mutated.digest == RootManifest.content_digest(mutated)
      assert length(mutated.manufacturers) == length(manifest.manufacturers) + 1

      # The input manifest is untouched -- there is no partial mutation.
      assert manifest.digest == original_digest
    end

    @tag :graphlaw_engine
    test "mutation re-verifies pins against disk and refuses if the corpus drifted" do
      staged = stage()
      {:ok, manifest} = RootManifest.load(staged.path, require_engine: false)
      {principal, authority} = custodian()

      rules = Path.join(staged.root, "conformance/rules/derivation.n3")
      File.write!(rules, File.read!(rules) <> "\n# drift\n")

      assert {:error, %{code: :REFUSED_MANIFEST_DRIFT}} =
               RootManifest.mutate(manifest, %{manufacturers: []}, authority, principal,
                 require_engine: false
               )
    end
  end

  describe "pin metadata" do
    @tag :graphlaw_engine
    test "the corpus pins exactly the machinery, and deliberately not the data or the falsifiers" do
      {:ok, manifest} = ConformanceCorpus.build()
      paths = manifest |> RootManifest.all_pins() |> Enum.map(&Map.fetch!(&1, "path"))
      falsifiers = ConformanceCorpus.unpinned_falsifiers()

      assert "conformance/shapes/command_envelope.shacl.ttl" in paths
      assert "conformance/schema/command_envelope.shexj" in paths
      assert "conformance/rules/derivation.n3" in paths
      assert "conformance/queries/falsifier_unauthorized_actuation.rq" in paths

      refute falsifiers.shacl_shapes in paths
      refute falsifiers.n3_rules in paths
      refute "conformance/data/valid_command.ttl" in paths
      refute "conformance/data/invalid_command.ttl" in paths

      # ...and the unpinned falsifiers are nonetheless real files on disk.
      assert File.exists?(Path.join(ConformanceCorpus.root(), falsifiers.shacl_shapes))
      assert File.exists?(Path.join(ConformanceCorpus.root(), falsifiers.n3_rules))
    end

    @tag :graphlaw_engine
    test "every pin carries a real sha256 of the real file" do
      {:ok, manifest} = ConformanceCorpus.build()

      for pin <- RootManifest.all_pins(manifest) do
        absolute = RootManifest.resolve(manifest, Map.fetch!(pin, "path"))
        assert {:ok, actual} = RootManifest.artifact_digest(absolute)
        assert Map.fetch!(pin, "digest") == actual
        assert Map.fetch!(pin, "kind") in AshA2A.Semantic.MetaAdmission.artifact_kinds()
      end
    end
  end
end

# --- SECTION 17: Original test/ash_a2a/semantic/sa_namespace_test.exs ---
defmodule AshA2A.Semantic.SaNamespaceTest do
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{FalsifierSuite, Vocabulary}

  test "falsifier suite uses the single Vocabulary sa: namespace" do
    assert FalsifierSuite.namespace() == Vocabulary.sa_namespace()
    assert FalsifierSuite.sa("X") == Vocabulary.sa_namespace() <> "X"
    {:ok, ask} = FalsifierSuite.ask(:do_without_prepared_receipt)
    assert ask =~ "PREFIX sa: <#{Vocabulary.sa_namespace()}>"
  end

  test "to_ntriples escapes IRIs and literals via Serialize" do
    graph = [
      {"http://e/a b>", "http://e/p", {:lit, "line\n\"q\"\\"}},
      {"http://e/s", "http://e/p", "http://e/o"}
    ]

    nt = FalsifierSuite.to_ntriples(graph)
    assert nt =~ "<http://e/a\\u0020b\\u003E> <http://e/p> \"line\\n\\\"q\\\"\\\\\" ."
    assert nt =~ "<http://e/s> <http://e/p> <http://e/o> ."
    refute nt =~ "a b"
  end
end

# --- SECTION 18: Original test/ash_a2a/semantic/standing_ledger_key_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.StandingLedgerKeyTest do
  @moduledoc """
  DEP-04: the standing-ledger sealing key must be configurable so a chain
  sealed on one node verifies on every other node and after a restart.

  Chicago style: the real `AshA2A.Semantic.Standing.transition/3`, a real
  second BEAM node started with OTP's `:peer`, and the real `:persistent_term`
  slot the per-runtime fallback key lives in. `async: false` because the
  tests mutate `:ash_a2a` application env and the node-wide persistent term.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Semantic.{Envelope, Refusal, Standing}

  @ledger_key_term {Standing, :ledger_key}
  @received %{transport: "a2a/https", received_at: "2026-09-27T00:00:00Z"}
  @parsed %{media_type: "text/turtle", triple_count: 3}

  setup do
    previous_config = Application.get_env(:ash_a2a, :standing_ledger_key)
    previous_term = :persistent_term.get(@ledger_key_term, nil)

    on_exit(fn ->
      restore_env(previous_config)

      if previous_term,
        do: :persistent_term.put(@ledger_key_term, previous_term),
        else: :persistent_term.erase(@ledger_key_term)
    end)

    :ok
  end

  defp restore_env(nil), do: Application.delete_env(:ash_a2a, :standing_ledger_key)
  defp restore_env(value), do: Application.put_env(:ash_a2a, :standing_ledger_key, value)

  defp candidate(id) do
    {:ok, envelope} = Envelope.new(%{envelope_id: id, kind: "sa2a:Request"})
    envelope
  end

  # Simulates a node restart / a different node: the per-runtime random key is
  # replaced by a fresh, unrelated one, exactly what a new BEAM would generate.
  defp rotate_runtime_key! do
    :persistent_term.put(@ledger_key_term, :crypto.strong_rand_bytes(32))
  end

  test "a configured key survives a runtime-key rotation (restart / rolling update)" do
    Application.put_env(:ash_a2a, :standing_ledger_key, :crypto.strong_rand_bytes(32))

    {:ok, received} =
      Standing.transition(candidate("urn:uuid:dep04-restart"), :received, @received)

    rotate_runtime_key!()

    assert {:ok, %Envelope{standing: :parsed}} = Standing.transition(received, :parsed, @parsed)
  end

  test "without a configured key the chain is node-local: a rotated runtime key refuses it" do
    Application.delete_env(:ash_a2a, :standing_ledger_key)

    {:ok, received} = Standing.transition(candidate("urn:uuid:dep04-local"), :received, @received)
    rotate_runtime_key!()

    assert {:error, %Refusal{code: :standing_ledger_unsealed}} =
             Standing.transition(received, :parsed, @parsed)
  end

  test "a malformed configured key fails closed at boot and on transition" do
    for bad <- [:crypto.strong_rand_bytes(16), :crypto.strong_rand_bytes(33), "", :not_a_key] do
      Application.put_env(:ash_a2a, :standing_ledger_key, bad)

      assert_raise ArgumentError, ~r/standing_ledger_key must be exactly 32 raw bytes/, fn ->
        Standing.ensure_ledger_key()
      end

      assert_raise ArgumentError, fn ->
        Standing.transition(candidate("urn:uuid:dep04-bad"), :received, @received)
      end
    end
  end

  describe "across two real BEAM nodes" do
    setup do
      System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)

      unless Node.alive?() do
        {:ok, _} =
          Node.start(:"standing_key_primary_#{System.unique_integer([:positive])}", :shortnames)
      end

      host = Node.self() |> Atom.to_string() |> String.split("@") |> List.last()

      {:ok, peer_pid, peer_node} =
        :peer.start_link(%{
          name: :"standing_key_peer_#{System.unique_integer([:positive])}",
          host: String.to_charlist(host),
          args: [~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
        })

      :ok = :rpc.call(peer_node, :code, :add_pathsz, [:code.get_path()])

      on_exit(fn ->
        try do
          :peer.stop(peer_pid)
        catch
          _, _ -> :ok
        end
      end)

      %{peer: peer_node}
    end

    test "a chain sealed on a peer under the shared configured key verifies locally", %{
      peer: peer
    } do
      key = :crypto.strong_rand_bytes(32)
      Application.put_env(:ash_a2a, :standing_ledger_key, key)
      :ok = :erpc.call(peer, Application, :put_env, [:ash_a2a, :standing_ledger_key, key])

      {:ok, received} =
        :erpc.call(peer, Standing, :transition, [
          candidate("urn:uuid:dep04-peer"),
          :received,
          @received
        ])

      assert {:ok, %Envelope{standing: :parsed}} = Standing.transition(received, :parsed, @parsed)
    end

    test "without a shared key the peer's chain is refused locally", %{peer: peer} do
      Application.delete_env(:ash_a2a, :standing_ledger_key)

      {:ok, received} =
        :erpc.call(peer, Standing, :transition, [
          candidate("urn:uuid:dep04-peer-local"),
          :received,
          @received
        ])

      assert {:error, %Refusal{code: :standing_ledger_unsealed}} =
               Standing.transition(received, :parsed, @parsed)
    end
  end
end

# --- SECTION 19: Original test/ash_a2a/semantic/unknown_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

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
