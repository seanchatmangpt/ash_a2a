defmodule AshA2A.Telemetry.AllocationCounters do
  @moduledoc """
  Real per-semantic-class allocation counter, answering the one question
  RFC S39/S65's machine-experience claim actually turns on:

      Is Allocation_LLM(class, t+1) <= Allocation_LLM(class, t)?

  `AshA2A.Telemetry.RouterCounters` already measures the *global* tier
  split (deterministic / phrase / llm) over
  `AshA2A.Planning.RequestRouter.route/3`. That instrument is
  deliberately unchanged here: its three fixed `:counters` slots are the
  right primitive for three fixed tiers, and widening it to a dynamic,
  unbounded key space (one slot per semantic class) is not something
  `:counters` can express -- a `:counters` reference has a fixed arity
  chosen at `new/1` time.

  So this is a genuinely separate instrument over a genuinely different
  event (`[:ash_a2a, :semantic, :allocation]`, emitted by
  `AshA2A.Semantic.Unknown.route/3`), backed by a public `:ets` table with
  `:ets.update_counter/4`'s atomic read-modify-write. Same design
  discipline as `RouterCounters`: per-instance state threaded through
  `:telemetry.attach/4`'s own `config` argument, no `:persistent_term`,
  no global, so concurrent `async: true` tests never interfere.

  ## Usage

      tid = AllocationCounters.new()
      handler = AllocationCounters.attach!(tid)
      # ... real AshA2A.Semantic.Unknown.route/3 calls ...
      AllocationCounters.allocation(tid, "invoice-reconciliation", :llm)     #=> 1
      AllocationCounters.allocation(tid, "invoice-reconciliation", :machinery) #=> 3
      AllocationCounters.counts(tid)
      #=> %{"invoice-reconciliation" => %{llm: 1, machinery: 3}}
      AllocationCounters.detach(handler)

  The table is `:public` so the emitting process (telemetry handlers run
  in the caller) can write to it regardless of which process created it.
  """

  @event [:ash_a2a, :semantic, :allocation]

  @typedoc "An `:ets` table id returned by `new/0`."
  @type tid :: :ets.tid()

  @doc "A fresh, empty counter table. Not yet attached -- pair with `attach!/2`."
  @spec new() :: tid()
  def new, do: :ets.new(__MODULE__, [:public, :set])

  @doc """
  Attaches `tid` to `[:ash_a2a, :semantic, :allocation]`. Each event
  increments the `{class, resolver}` cell by one. Returns the real
  `:telemetry` handler id for a later `detach/1`.

  `handler_id_suffix` defaults to a fresh `make_ref/0` so two independent
  attaches never collide -- same convention as
  `AshA2A.Telemetry.RouterCounters.attach!/2`.
  """
  @spec attach!(tid(), term()) :: term()
  def attach!(tid, handler_id_suffix \\ make_ref()) do
    handler_id = {__MODULE__, handler_id_suffix}

    :ok =
      case :telemetry.attach(handler_id, @event, &__MODULE__.handle_event/4, tid) do
        :ok -> :ok
        {:error, :already_exists} -> :ok
      end

    handler_id
  end

  @doc "Detaches a handler id previously returned by `attach!/2`."
  @spec detach(term()) :: :ok | {:error, :not_found}
  def detach(handler_id), do: :telemetry.detach(handler_id)

  @doc false
  @spec handle_event(:telemetry.event_name(), :telemetry.event_measurements(), map(), tid()) ::
          :ok
  def handle_event(@event, _measurements, %{class: class, resolver: resolver}, tid)
      when is_binary(class) and is_atom(resolver) do
    :ets.update_counter(tid, {class, resolver}, {2, 1}, {{class, resolver}, 0})
    :ok
  end

  # Fails closed rather than crashing the emitting process, same as
  # `RouterCounters.handle_event/4`'s documented catch-all clause.
  def handle_event(@event, _measurements, _metadata, _tid), do: :ok

  @doc """
  Real count for one `{class, resolver}` pair. `0` for a pair never
  observed -- an unobserved allocation is genuinely zero spend, not
  missing data.
  """
  @spec allocation(tid(), String.t(), atom()) :: non_neg_integer()
  def allocation(tid, class, resolver) do
    case :ets.lookup(tid, {class, resolver}) do
      [{{^class, ^resolver}, count}] -> count
      [] -> 0
    end
  end

  @doc """
  Every observed allocation, grouped by class:
  `%{class => %{resolver => count}}`.
  """
  @spec counts(tid()) :: %{optional(String.t()) => %{optional(atom()) => non_neg_integer()}}
  def counts(tid) do
    tid
    |> :ets.tab2list()
    |> Enum.reduce(%{}, fn {{class, resolver}, count}, acc ->
      Map.update(acc, class, %{resolver => count}, &Map.put(&1, resolver, count))
    end)
  end

  @doc """
  The RFC S65 monotonicity check, over two real observations of the same
  class taken at two different times.

  `true` when `later <= earlier` -- i.e. the class did not get *more*
  expensive in the named resolver dimension. Returns a real boolean over
  two real measured integers; it does not read any state of its own, so
  it cannot be satisfied by anything but genuinely declining spend.
  """
  @spec non_increasing?(non_neg_integer(), non_neg_integer()) :: boolean()
  def non_increasing?(earlier, later)
      when is_integer(earlier) and is_integer(later),
      do: later <= earlier
end
