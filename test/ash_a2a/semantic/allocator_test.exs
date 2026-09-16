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

  test "the budget fingerprint moves with real spend and is stable for identical state" do
    a = Allocator.new!([tokens: 10], issued_by: {:host, :same})
    b = Allocator.new!([tokens: 10], issued_by: {:host, :same})

    assert a.fingerprint == b.fingerprint

    {:ok, spent} = Allocator.allocate(a, :tokens, 3)
    refute spent.fingerprint == a.fingerprint

    assert %Budget{} = spent
  end
end
