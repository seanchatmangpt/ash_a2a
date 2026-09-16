defmodule AshA2A.Semantic.Allocator.Budget do
  @moduledoc """
  A real, bounded resource budget issued *before* expensive UNKNOWN
  resolution runs (RFC S38's CMCA allocation boundary).

  A budget is a closed, immutable set of per-dimension ceilings plus the
  amount consumed against each. It carries no function that raises a
  ceiling: `AshA2A.Semantic.Allocator.allocate/3` can only ever move
  consumption *up*, never a limit, and the only way to obtain larger
  limits is `AshA2A.Semantic.Allocator.reissue/3`, which structurally
  requires a non-model issuer. RFC S73 ("NeedMoreResources does not imply
  GrantMoreResources") is therefore enforced by the absence of a code
  path, not by a runtime policy check that could be argued around.

  `:wall_time_ms` is a *measured* dimension, not an added one: its
  consumption is `System.monotonic_time(:millisecond)` minus
  `started_at_ms`, recomputed on every allocation attempt. A caller
  cannot under-report elapsed time by declining to allocate against it.
  """

  @enforce_keys [:limits, :consumed, :started_at_ms, :issued_by, :fingerprint]
  defstruct [:limits, :consumed, :started_at_ms, :issued_by, :fingerprint]

  @type dimension ::
          :inference_calls
          | :tokens
          | :compute_units
          | :retries
          | :external_requests
          | :money_micros
          | :agents
          | :tools
          | :wall_time_ms

  @type issuer :: {:host, term()} | AshA2A.Authority.t()

  @type t :: %__MODULE__{
          limits: %{optional(dimension()) => non_neg_integer()},
          consumed: %{optional(dimension()) => non_neg_integer()},
          started_at_ms: integer(),
          issued_by: issuer(),
          fingerprint: String.t()
        }
end

defmodule AshA2A.Semantic.Allocator do
  @moduledoc """
  RFC S38 (CMCA allocation boundary) and RFC S73 (no self-granted budget).

  An explicit resource allocator that sits *before* expensive UNKNOWN
  resolution, operating over the admitted candidate frontier. Every
  resolver call that `AshA2A.Semantic.Unknown.route/3` can make has to
  pass through `allocate/3` first; when the relevant dimension is
  exhausted the UNKNOWN stays UNKNOWN rather than being resolved anyway.

  ## The nine budgeted dimensions

  `:inference_calls`, `:tokens`, `:compute_units`, `:retries`,
  `:external_requests`, `:money_micros`, `:agents`, `:tools`,
  `:wall_time_ms`.

  ## Authority is deliberately NOT a dimension

  RFC S73 enumerates tokens, compute, money, calls, agents, tools **and
  authority**. The first eight are budgeted quantities; authority is not
  a quantity at all, so it is not representable as a budget dimension.
  `allocate(budget, :authority, _)` returns
  `{:error, %{code: :authority_not_allocatable}}` rather than silently
  treating `:authority` as an unbudgeted-but-otherwise-ordinary
  dimension. There is no amount of budget that buys authority; authority
  comes from `AshA2A.Authority` bound to a real principal, and
  `AshA2A.Semantic.LlmBoundary.attempt/2` refuses to let model output
  produce one.

  ## The three refusals that make S73 real

    1. `request_increase/2` **always** refuses, with
       `:self_grant_refused`. It exists solely so that "the model asked
       for more budget" is a named, receipted, refused event rather than
       an unrepresentable one. It returns no success clause at all.
    2. `reissue/3` requires a `{:host, _}` tuple or a real
       `%AshA2A.Authority{}` whose `source` is not `:model`. A model
       cannot construct either (see `LlmBoundary`), and a budget whose
       `issued_by` is `{:model, _}` is refused at `new/2`.
    3. `reissue/3` carries `consumed` forward unchanged. Re-issuing a
       larger budget never launders past spend into fresh headroom.

  ## Usage

      {:ok, budget} =
        Allocator.new([inference_calls: 1, wall_time_ms: 5_000], issued_by: {:host, :test})

      {:ok, budget} = Allocator.allocate(budget, :inference_calls, 1)
      {:error, %{code: :budget_exhausted}} = Allocator.allocate(budget, :inference_calls, 1)
      {:error, %{code: :self_grant_refused}} = Allocator.request_increase(budget, %{})
  """

  alias AshA2A.Authority
  alias AshA2A.Semantic.Allocator.Budget

  @dimensions ~w(
    inference_calls
    tokens
    compute_units
    retries
    external_requests
    money_micros
    agents
    tools
    wall_time_ms
  )a

  @doc "The nine real budget dimensions. `:authority` is deliberately absent."
  @spec dimensions() :: [Budget.dimension()]
  def dimensions, do: @dimensions

  @doc """
  Builds a bounded budget. Every limit key must be one of `dimensions/0`
  and every limit value a non-negative integer -- an unbounded budget is
  not representable.

  `:issued_by` (default `{:host, :unspecified}`) must be a `{:host, _}`
  tuple or a real `%AshA2A.Authority{}` whose `source` is not `:model`.
  """
  @spec new(keyword() | map(), keyword()) :: {:ok, Budget.t()} | {:error, map()}
  def new(limits, opts \\ []) do
    limits = Map.new(limits)
    issued_by = Keyword.get(opts, :issued_by, {:host, :unspecified})

    with :ok <- validate_limits(limits),
         :ok <- validate_issuer(issued_by) do
      budget = %Budget{
        limits: limits,
        consumed: Map.new(limits, fn {dimension, _limit} -> {dimension, 0} end),
        started_at_ms: Keyword.get(opts, :started_at_ms, System.monotonic_time(:millisecond)),
        issued_by: issued_by,
        fingerprint: ""
      }

      {:ok, %{budget | fingerprint: fingerprint(budget)}}
    end
  end

  @doc "`new/2` that raises on an invalid budget. Convenience for callers with static limits."
  @spec new!(keyword() | map(), keyword()) :: Budget.t()
  def new!(limits, opts \\ []) do
    case new(limits, opts) do
      {:ok, budget} -> budget
      {:error, reason} -> raise ArgumentError, "invalid budget: #{inspect(reason)}"
    end
  end

  @doc """
  Spends `amount` of `dimension` against `budget`.

  Fails closed in four distinct, separately-typed ways:

    * `:authority_not_allocatable` -- `dimension` is `:authority`.
      Authority is not a budgeted quantity (RFC S73).
    * `:dimension_not_budgeted` -- a real dimension the issuer never
      budgeted. You cannot spend what was never granted; an unbudgeted
      dimension is a zero ceiling, not an unlimited one.
    * `:invalid_allocation_amount` -- a negative or non-integer amount
      (a negative allocation would be a budget increase in disguise).
    * `:budget_exhausted` -- the request would exceed the ceiling, or
      the measured wall clock already has.

  Wall time is re-measured on *every* call, so a long-running resolver
  cannot outlive its `:wall_time_ms` ceiling simply by not allocating.
  """
  @spec allocate(Budget.t(), Budget.dimension() | :authority, integer()) ::
          {:ok, Budget.t()} | {:error, map()}
  def allocate(%Budget{}, :authority, _amount) do
    {:error,
     %{
       code: :authority_not_allocatable,
       detail:
         "authority is not a budgeted quantity; no amount of budget grants authority (RFC S73)"
     }}
  end

  def allocate(%Budget{} = budget, dimension, amount)
      when dimension in @dimensions and is_integer(amount) and amount >= 0 do
    with :ok <- check_wall_time(budget),
         {:ok, limit} <- fetch_limit(budget, dimension) do
      consumed = Map.get(budget.consumed, dimension, 0)

      if consumed + amount > limit do
        {:error,
         %{
           code: :budget_exhausted,
           dimension: dimension,
           limit: limit,
           consumed: consumed,
           requested: amount
         }}
      else
        next = %{budget | consumed: Map.put(budget.consumed, dimension, consumed + amount)}
        {:ok, %{next | fingerprint: fingerprint(next)}}
      end
    end
  end

  def allocate(%Budget{}, dimension, amount) when dimension in @dimensions do
    {:error, %{code: :invalid_allocation_amount, dimension: dimension, requested: amount}}
  end

  def allocate(%Budget{}, dimension, _amount) do
    {:error, %{code: :unknown_dimension, dimension: dimension}}
  end

  @doc """
  Real measured wall-clock check: `:ok` while inside the `:wall_time_ms`
  ceiling, `{:error, %{code: :budget_exhausted, dimension: :wall_time_ms}}`
  once past it. A budget with no `:wall_time_ms` limit is not
  wall-time-bounded and this returns `:ok`.
  """
  @spec check_wall_time(Budget.t()) :: :ok | {:error, map()}
  def check_wall_time(%Budget{} = budget) do
    case Map.fetch(budget.limits, :wall_time_ms) do
      :error ->
        :ok

      {:ok, limit} ->
        elapsed = System.monotonic_time(:millisecond) - budget.started_at_ms

        if elapsed > limit do
          {:error,
           %{
             code: :budget_exhausted,
             dimension: :wall_time_ms,
             limit: limit,
             consumed: elapsed,
             requested: 0
           }}
        else
          :ok
        end
    end
  end

  @doc """
  RFC S73, enforced as a total function with no success clause: a model
  (or anything else) asking for more budget because its previous
  allocation was insufficient is **always** refused.

  NeedMoreResources does not imply GrantMoreResources -- for tokens,
  compute, money, calls, agents, tools, and authority alike. This
  function exists so that the request is a real, typed, receiptable
  event instead of an unrepresentable one; it is not a policy hook and
  has no configuration that makes it succeed.
  """
  @spec request_increase(Budget.t(), term()) :: {:error, map()}
  def request_increase(%Budget{} = budget, request) do
    {:error,
     %{
       code: :self_grant_refused,
       detail:
         "NeedMoreResources does not imply GrantMoreResources (RFC S73): " <>
           "a budget increase requires a non-model issuer via reissue/3",
       requested: request,
       current_limits: budget.limits,
       current_consumed: budget.consumed
     }}
  end

  @doc """
  The only way to obtain larger limits: a *new* budget issued by a real
  non-model issuer.

  `consumed` is carried forward unchanged, so reissue can never launder
  already-spent resources back into headroom, and `new_limits` must be
  at least the already-consumed amount in every dimension (a reissue
  that would retroactively put the budget over its own ceiling is
  refused with `:reissue_below_consumed`).
  """
  @spec reissue(Budget.t(), Budget.issuer(), keyword() | map()) ::
          {:ok, Budget.t()} | {:error, map()}
  def reissue(%Budget{} = budget, issuer, new_limits) do
    new_limits = Map.new(new_limits)

    with :ok <- validate_limits(new_limits),
         :ok <- validate_issuer(issuer),
         :ok <- validate_reissue_covers_consumed(budget, new_limits) do
      next = %{
        budget
        | limits: new_limits,
          consumed: Map.merge(Map.new(new_limits, fn {d, _} -> {d, 0} end), budget.consumed),
          issued_by: issuer
      }

      {:ok, %{next | fingerprint: fingerprint(next)}}
    end
  end

  @doc "Remaining headroom per dimension (`:wall_time_ms` is measured, not accumulated)."
  @spec remaining(Budget.t()) :: %{optional(Budget.dimension()) => integer()}
  def remaining(%Budget{} = budget) do
    Map.new(budget.limits, fn
      {:wall_time_ms, limit} ->
        {:wall_time_ms, limit - (System.monotonic_time(:millisecond) - budget.started_at_ms)}

      {dimension, limit} ->
        {dimension, limit - Map.get(budget.consumed, dimension, 0)}
    end)
  end

  defp validate_limits(limits) when map_size(limits) == 0 do
    {:error, %{code: :empty_budget, detail: "a budget with no bounded dimension is not a bound"}}
  end

  defp validate_limits(limits) do
    invalid =
      Enum.reject(limits, fn {dimension, limit} ->
        dimension in @dimensions and is_integer(limit) and limit >= 0
      end)

    case invalid do
      [] -> :ok
      _ -> {:error, %{code: :invalid_budget_limits, invalid: Map.new(invalid)}}
    end
  end

  defp validate_issuer({:host, _}), do: :ok

  defp validate_issuer(%Authority{source: :model}) do
    {:error,
     %{code: :model_issued_budget_refused, detail: "a model may not issue its own budget"}}
  end

  defp validate_issuer(%Authority{}), do: :ok

  defp validate_issuer({:model, _}) do
    {:error,
     %{code: :model_issued_budget_refused, detail: "a model may not issue its own budget"}}
  end

  defp validate_issuer(other), do: {:error, %{code: :invalid_budget_issuer, issuer: other}}

  defp validate_reissue_covers_consumed(%Budget{consumed: consumed}, new_limits) do
    under =
      Enum.filter(consumed, fn {dimension, spent} ->
        case Map.fetch(new_limits, dimension) do
          {:ok, limit} -> spent > limit
          :error -> spent > 0
        end
      end)

    case under do
      [] -> :ok
      _ -> {:error, %{code: :reissue_below_consumed, dimensions: Map.new(under)}}
    end
  end

  defp fetch_limit(%Budget{limits: limits}, dimension) do
    case Map.fetch(limits, dimension) do
      {:ok, limit} ->
        {:ok, limit}

      :error ->
        {:error,
         %{
           code: :dimension_not_budgeted,
           dimension: dimension,
           detail: "an unbudgeted dimension is a zero ceiling, never an unlimited one"
         }}
    end
  end

  defp fingerprint(%Budget{} = budget) do
    {budget.limits, budget.consumed, budget.issued_by}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
