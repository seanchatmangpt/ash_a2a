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
