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

  ## `minimums`: the spender does not set the price of its own calls

  Every budgeted dimension carries an **issuer-set** minimum charge
  (default 1, never below 1). `AshA2A.Semantic.Allocator.allocate/3`
  charges `max(amount, minimum)`, so a caller cannot request `0` and be
  admitted against a budget with zero headroom. Minimums are supplied at
  `new/2`/`reissue/4` time by the same non-model issuer that set the
  limits; there is no path by which the spender changes them, exactly as
  there is no path by which the spender raises a ceiling.
  """

  @enforce_keys [:limits, :minimums, :consumed, :started_at_ms, :issued_by, :fingerprint]
  defstruct [:limits, :minimums, :consumed, :started_at_ms, :issued_by, :fingerprint]

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
          minimums: %{optional(dimension()) => pos_integer()},
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

  ## A zero-cost call is not a call the spender may price

  Every dimension carries an issuer-set minimum charge (`:minimums`,
  default 1). `allocate/3` charges `max(amount, minimum)`, never the
  raw `amount`. Without that, `allocate(exhausted_budget, dim, 0)`
  passes a `consumed + 0 > limit` test forever, and RFC S73 is nullified
  through an unguarded door: the spender sets the price of its own
  calls and an exhausted budget admits unlimited further calls. The
  minimum is set by the same non-model issuer that sets the limits, so
  there is no self-pricing path any more than there is a self-granting
  one.

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
      # a zero-amount call is charged the issuer's minimum, so it is
      # refused too -- the exhausted budget has no unguarded door:
      {:error, %{code: :budget_exhausted}} = Allocator.allocate(budget, :inference_calls, 0)
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

  @default_minimum 1

  @doc "The nine real budget dimensions. `:authority` is deliberately absent."
  @spec dimensions() :: [Budget.dimension()]
  def dimensions, do: @dimensions

  @doc """
  The floor every issuer-set minimum charge is clamped to. A minimum of
  zero would reopen the self-pricing door this module exists to shut, so
  it is not representable.
  """
  @spec default_minimum() :: pos_integer()
  def default_minimum, do: @default_minimum

  @doc """
  Builds a bounded budget. Every limit key must be one of `dimensions/0`
  and every limit value a non-negative integer -- an unbounded budget is
  not representable.

  `:issued_by` (default `{:host, :unspecified}`) must be a `{:host, _}`
  tuple or a real `%AshA2A.Authority{}` whose `source` is not `:model`.

  `:minimums` (default `%{}`) is the issuer's per-dimension minimum
  charge. Any budgeted dimension the issuer does not name gets
  `default_minimum/0`; a named minimum must be a positive integer, so a
  zero-cost dimension is not representable.
  """
  @spec new(keyword() | map(), keyword()) :: {:ok, Budget.t()} | {:error, map()}
  def new(limits, opts \\ []) do
    limits
    |> do_new(opts)
    |> emit_decision(:new, %{
      issuer: issuer_kind(Keyword.get(opts, :issued_by, {:host, :unspecified}))
    })
  end

  defp do_new(limits, opts) do
    limits = Map.new(limits)
    issued_by = Keyword.get(opts, :issued_by, {:host, :unspecified})
    given_minimums = Map.new(Keyword.get(opts, :minimums, %{}))

    with :ok <- validate_limits(limits),
         :ok <- validate_issuer(issued_by),
         :ok <- validate_minimums(given_minimums) do
      budget = %Budget{
        limits: limits,
        minimums: materialize_minimums(limits, given_minimums),
        consumed: Map.new(limits, fn {dimension, _limit} -> {dimension, 0} end),
        started_at_ms: Keyword.get(opts, :started_at_ms, System.monotonic_time(:millisecond)),
        issued_by: issued_by,
        fingerprint: ""
      }

      {:ok, %{budget | fingerprint: fingerprint(budget)}}
    end
  end

  @doc """
  The issuer-set minimum charge for `dimension` on `budget`. Never below
  `default_minimum/0`, including for a dimension the budget does not
  carry at all (which `allocate/3` refuses anyway).
  """
  @spec minimum(Budget.t(), Budget.dimension()) :: pos_integer()
  def minimum(%Budget{minimums: minimums}, dimension) do
    case Map.get(minimums, dimension) do
      value when is_integer(value) and value >= @default_minimum -> value
      _ -> @default_minimum
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
    * `:budget_exhausted` -- the charge would exceed the ceiling, or
      the measured wall clock already has.

  Wall time is re-measured on *every* call, so a long-running resolver
  cannot outlive its `:wall_time_ms` ceiling simply by not allocating.

  The amount actually charged is `max(amount, minimum(budget, dimension))`
  and is reported as `:charged` on both success (via the returned
  budget's `consumed`) and refusal. `amount` is a floor the caller may
  raise, never a price the caller may set: `allocate(budget, dim, 0)`
  against a budget with zero headroom is `:budget_exhausted`, not `:ok`.
  """
  @spec allocate(Budget.t(), Budget.dimension() | :authority, integer()) ::
          {:ok, Budget.t()} | {:error, map()}
  def allocate(%Budget{} = budget, dimension, amount) do
    budget
    |> do_allocate(dimension, amount)
    |> emit_decision(:allocate, %{
      dimension: dimension,
      requested: amount,
      budget: budget.fingerprint,
      issuer: issuer_kind(budget.issued_by)
    })
  end

  defp do_allocate(%Budget{}, :authority, _amount) do
    {:error,
     %{
       code: :authority_not_allocatable,
       detail:
         "authority is not a budgeted quantity; no amount of budget grants authority (RFC S73)"
     }}
  end

  defp do_allocate(%Budget{} = budget, dimension, amount)
       when dimension in @dimensions and is_integer(amount) and amount >= 0 do
    with :ok <- check_wall_time(budget),
         {:ok, limit} <- fetch_limit(budget, dimension) do
      consumed = Map.get(budget.consumed, dimension, 0)
      charged = max(amount, minimum(budget, dimension))

      if consumed + charged > limit do
        {:error,
         %{
           code: :budget_exhausted,
           dimension: dimension,
           limit: limit,
           consumed: consumed,
           requested: amount,
           charged: charged
         }}
      else
        next = %{budget | consumed: Map.put(budget.consumed, dimension, consumed + charged)}
        {:ok, %{next | fingerprint: fingerprint(next)}}
      end
    end
  end

  defp do_allocate(%Budget{}, dimension, amount) when dimension in @dimensions do
    {:error, %{code: :invalid_allocation_amount, dimension: dimension, requested: amount}}
  end

  defp do_allocate(%Budget{}, dimension, _amount) do
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
    {:error, request_increase_refusal(budget, request)}
    |> emit_decision(:request_increase, %{
      budget: budget.fingerprint,
      issuer: issuer_kind(budget.issued_by)
    })
  end

  defp request_increase_refusal(budget, request) do
    %{
      code: :self_grant_refused,
      detail:
        "NeedMoreResources does not imply GrantMoreResources (RFC S73): " <>
          "a budget increase requires a non-model issuer via reissue/3",
      requested: request,
      current_limits: budget.limits,
      current_consumed: budget.consumed
    }
  end

  @doc """
  The only way to obtain larger limits: a *new* budget issued by a real
  non-model issuer.

  `consumed` is carried forward unchanged, so reissue can never launder
  already-spent resources back into headroom, and `new_limits` must be
  at least the already-consumed amount in every dimension (a reissue
  that would retroactively put the budget over its own ceiling is
  refused with `:reissue_below_consumed`).

  Minimum charges carry forward too, unless the new issuer sets its own
  via `reissue/4`'s `:minimums` option. A reissue cannot lower a
  dimension's minimum below `default_minimum/0` any more than `new/2`
  can.
  """
  @spec reissue(Budget.t(), Budget.issuer(), keyword() | map()) ::
          {:ok, Budget.t()} | {:error, map()}
  def reissue(budget, issuer, new_limits), do: reissue(budget, issuer, new_limits, [])

  @doc "`reissue/3` with issuer options (`:minimums`)."
  @spec reissue(Budget.t(), Budget.issuer(), keyword() | map(), keyword()) ::
          {:ok, Budget.t()} | {:error, map()}
  def reissue(%Budget{} = budget, issuer, new_limits, opts) do
    budget
    |> do_reissue(issuer, new_limits, opts)
    |> emit_decision(:reissue, %{budget: budget.fingerprint, issuer: issuer_kind(issuer)})
  end

  defp do_reissue(budget, issuer, new_limits, opts) do
    new_limits = Map.new(new_limits)

    given_minimums =
      case Keyword.fetch(opts, :minimums) do
        {:ok, minimums} -> Map.new(minimums)
        :error -> Map.take(budget.minimums, Map.keys(new_limits))
      end

    with :ok <- validate_limits(new_limits),
         :ok <- validate_issuer(issuer),
         :ok <- validate_minimums(given_minimums),
         :ok <- validate_reissue_covers_consumed(budget, new_limits) do
      next = %{
        budget
        | limits: new_limits,
          minimums: materialize_minimums(new_limits, given_minimums),
          consumed: Map.merge(Map.new(new_limits, fn {d, _} -> {d, 0} end), budget.consumed),
          issued_by: issuer
      }

      {:ok, %{next | fingerprint: fingerprint(next)}}
    end
  end

  # `[:ash_a2a, :semantic, :allocator, :decision]`: every allocation-boundary
  # decision (`op` = :new | :allocate | :request_increase | :reissue) and its
  # outcome, so "the request reached the allocator" is observable whatever
  # the allocator decided (RFC-SA2A-002 §80). Observational only.
  defp emit_decision(result, op, meta) do
    outcome_meta =
      case result do
        {:ok, %Budget{} = next} ->
          %{outcome: :granted, next_budget: next.fingerprint}

        {:error, reason} ->
          Map.merge(
            %{outcome: :refused, code: Map.get(reason, :code)},
            Map.take(reason, [:limit, :consumed, :charged])
          )
      end

    :telemetry.execute(
      [:ash_a2a, :semantic, :allocator, :decision],
      %{count: 1},
      meta |> Map.merge(outcome_meta) |> Map.put(:op, op)
    )

    result
  end

  defp issuer_kind({kind, _}) when is_atom(kind), do: kind
  defp issuer_kind(%Authority{source: source}), do: {:authority, source}
  defp issuer_kind(_other), do: :unspecified

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

  defp validate_minimums(minimums) do
    invalid =
      Enum.reject(minimums, fn {dimension, minimum} ->
        dimension in @dimensions and is_integer(minimum) and minimum >= @default_minimum
      end)

    case invalid do
      [] ->
        :ok

      _ ->
        {:error,
         %{
           code: :invalid_budget_minimums,
           invalid: Map.new(invalid),
           detail:
             "a minimum charge below #{@default_minimum} would let the spender price its own calls"
         }}
    end
  end

  defp materialize_minimums(limits, given) do
    Map.new(limits, fn {dimension, _limit} ->
      {dimension, Map.get(given, dimension, @default_minimum)}
    end)
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
    {budget.limits, budget.minimums, budget.consumed, budget.issued_by}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
