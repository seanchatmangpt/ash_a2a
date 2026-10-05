# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.FinOps.BudgetStore do
  @moduledoc """
  ETS-backed hard budget ceilings for `ash_a2a` FinOps (ARD v26.10.4 §3.5,
  PRD FR-05.2).

  Tracks real-time token/compute consumption partitioned by
  `budget_account_id` inside fixed billing windows, against a configured
  hard ceiling per account. Storage is a public `:ets` set owned by a
  minimal GenServer; **reservations are serialized through that owner**
  so a check-and-reserve is one atomic transition: the cumulative
  consumption recorded for a window never exceeds the ceiling, and every
  `record/3` verdict (admit/refuse) is exact -- no request is admitted
  past the hard ceiling, and a refused request leaves consumption
  untouched (chargeback data is never inflated by a refusal).

  Why not a lock-free `:ets.update_counter` threshold increment: on OTP
  26+ the `{pos, incr, threshold, set_value}` op *saturates silently*
  (returns the ceiling and overwrites the counter) instead of raising,
  so a breach is indistinguishable from an exact fit at 100% quota
  without a racy pre-read. Exact verdicts need check-and-reserve to be
  atomic, and atomic check-and-reserve needs a serializer. The table
  stays `:public` so chargeback readers (`usage/2`, `total/2`, telemetry
  subscribers) never serialize behind the writer.

  Billing windows are fixed buckets: usage is keyed
  `{:usage, account_id, bucket}` with `bucket = div(now_ms, window_ms)`,
  so a window rotation is implicit in the clock -- no timer process, no
  reset storm. Lifetime consumption across all windows is readable via
  `total/2`.

  ## Usage

      {:ok, store} = AshA2A.FinOps.BudgetStore.start_link(
        budgets: [{"cc-prod-invoice", ceiling: 1_000_000}]
      )

      AshA2A.FinOps.BudgetStore.record(store, "cc-prod-invoice", 900)
      #=> {:ok, %{consumed: 900, ceiling: 1_000_000, ...}}

      AshA2A.FinOps.BudgetStore.record(store, "cc-prod-invoice", 900)
      #=> {:error, %{code: :budget_exceeded, detail: %{...}}}

  The refusal shape is the CommandBus `%{code: ..., detail: ...}` shape,
  liftable into the S42 taxonomy via `AshA2A.Semantic.Refusal.from_error/2`
  (`:budget_exceeded` -> `:refused_bounds` -- the PRD's
  `:REFUSED_BUDGET_EXCEEDED`; `:missing_evidence` -> `:refused_provenance`).
  """

  use GenServer

  @default_window_ms 3_600_000

  @enforce_keys [:table]
  defstruct [:table]

  @typedoc "The store handle: a registered name or the owner pid."
  @type store :: GenServer.server()
  @type account_id :: String.t() | atom()
  @type record_ok :: %{
          required(:consumed) => non_neg_integer(),
          required(:ceiling) => pos_integer(),
          required(:window_started_at) => integer(),
          required(:window_ms) => pos_integer()
        }
  @type record_error :: %{
          required(:code) => :budget_exceeded | :missing_evidence,
          required(:detail) => map()
        }

  # -- supervision --

  @doc """
  Starts a store owning a public ETS table. Opts:

    * `:name` -- GenServer registration name (default `__MODULE__`).
    * `:budgets` -- initial budgets, `[{account_id, [ceiling: n, window_ms: n]}]`.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Supervisor child spec. The child id includes the `:name` so several
  stores (one per billing domain) can share a supervision tree.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.get(opts, :name, __MODULE__)},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @doc """
  A standalone store for tests and embedded use: starts an unregistered
  owner process linked to the caller and returns the pid as the handle.
  """
  @spec new(keyword()) :: pid()
  def new(opts \\ []) do
    {:ok, pid} = GenServer.start_link(__MODULE__, opts)
    pid
  end

  # -- budget configuration --

  @doc """
  Configures (or reconfigures) the hard `ceiling` for `account_id`.

  Reconfiguration takes effect on the next reservation; consumption
  already recorded is kept. Raises `ArgumentError` on a non-positive or
  non-integer ceiling/window -- programmer error, not a runtime refusal.
  """
  @spec set_budget(store(), account_id(), pos_integer(), keyword()) :: :ok
  def set_budget(store, account_id, ceiling, opts \\ []) do
    unless is_integer(ceiling) and ceiling > 0 do
      raise ArgumentError, "ceiling must be a positive integer, got: #{inspect(ceiling)}"
    end

    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)

    unless is_integer(window_ms) and window_ms > 0 do
      raise ArgumentError, "window_ms must be a positive integer, got: #{inspect(window_ms)}"
    end

    GenServer.call(store, {:set_budget, account_id, ceiling, window_ms})
  end

  @doc "The configured hard ceiling for `account_id`, if any."
  @spec ceiling(store(), account_id()) :: {:ok, pos_integer()} | :error
  def ceiling(store, account_id) do
    case :ets.lookup(table(store), {:budget, account_id}) do
      [{{:budget, ^account_id}, {ceiling, _window_ms}}] -> {:ok, ceiling}
      [] -> :error
    end
  end

  @doc """
  Current-window consumption for `account_id` (`0` for an unconfigured
  account -- reads never refuse).
  """
  @spec usage(store(), account_id()) :: non_neg_integer()
  def usage(store, account_id) do
    table = table(store)

    case :ets.lookup(table, {:budget, account_id}) do
      [{{:budget, ^account_id}, {_ceiling, window_ms}}] ->
        bucket_usage(table, account_id, current_bucket(System.system_time(:millisecond), window_ms))

      [] ->
        0
    end
  end

  @doc "Lifetime consumption for `account_id` across all billing windows."
  @spec total(store(), account_id()) :: non_neg_integer()
  def total(store, account_id) do
    table(store)
    |> :ets.match_object({{:usage, account_id, :_}, :_})
    |> Enum.reduce(0, fn {_, n}, acc -> acc + n end)
  end

  # -- reservation --

  @doc """
  Atomically checks `amount` against the account's hard ceiling and, when
  the window's cumulative consumption would stay within it, records the
  reservation. Verdicts are exact and ordering is total (all reservations
  serialize through the owner).

  Returns `{:ok, record_ok()}` on admission, `{:error, record_error()}`
  on breach (code `:budget_exceeded`) or an unconfigured account
  (code `:missing_evidence` -- fail-closed: no ceiling is not unlimited).
  """
  @spec record(store(), account_id(), non_neg_integer()) :: {:ok, record_ok()} | {:error, record_error()}
  def record(store, account_id, amount) when is_integer(amount) and amount >= 0 do
    GenServer.call(store, {:record, account_id, amount})
  end

  # -- GenServer --

  @impl true
  def init(opts) do
    table = :ets.new(:finops_budget_store, [:public, :set, read_concurrency: true, write_concurrency: true])

    Enum.each(Keyword.get(opts, :budgets, []), fn {account_id, conf} ->
      do_set_budget(table, account_id, conf[:ceiling], Keyword.get(conf, :window_ms, @default_window_ms))
    end)

    {:ok, %__MODULE__{table: table}}
  end

  @impl true
  def handle_call({:set_budget, account_id, ceiling, window_ms}, _from, %__MODULE__{table: table} = state) do
    do_set_budget(table, account_id, ceiling, window_ms)
    {:reply, :ok, state}
  end

  def handle_call({:record, account_id, amount}, _from, %__MODULE__{table: table} = state) do
    {:reply, do_record(table, account_id, amount, System.system_time(:millisecond)), state}
  end

  def handle_call(:table, _from, %__MODULE__{table: table} = state), do: {:reply, table, state}

  # -- internals --

  defp do_set_budget(table, account_id, ceiling, window_ms) do
    :ets.insert(table, {{:budget, account_id}, {ceiling, window_ms}})
    :ok
  end

  defp do_record(table, account_id, amount, now) do
    case :ets.lookup(table, {:budget, account_id}) do
      [{{:budget, ^account_id}, {ceiling, window_ms}}] ->
        bucket = current_bucket(now, window_ms)
        key = {:usage, account_id, bucket}
        current = current_window_usage(table, key)

        if current + amount > ceiling do
          {:error,
           %{
             code: :budget_exceeded,
             detail: %{
               budget_account_id: account_id,
               requested: amount,
               consumed: current,
               ceiling: ceiling,
               window_started_at: bucket * window_ms
             }
           }}
        else
          consumed = :ets.update_counter(table, key, amount, {key, 0})

          {:ok,
           %{
             consumed: consumed,
             ceiling: ceiling,
             window_started_at: bucket * window_ms,
             window_ms: window_ms
           }}
        end

      [] ->
        {:error,
         %{
           code: :missing_evidence,
           detail: %{budget_account_id: account_id, reason: "no hard ceiling configured"}
         }}
    end
  end

  defp current_window_usage(table, key) do
    case :ets.lookup(table, key) do
      [{^key, n}] when is_integer(n) -> n
      [] -> 0
    end
  end

  defp bucket_usage(table, account_id, bucket) do
    case :ets.lookup(table, {:usage, account_id, bucket}) do
      [{{:usage, ^account_id, ^bucket}, n}] -> n
      [] -> 0
    end
  end

  defp current_bucket(now, window_ms), do: div(now, window_ms)

  defp table(store) when is_pid(store), do: table_of(store)
  defp table(store) when is_atom(store), do: table_of(store)

  defp table_of(server) do
    GenServer.call(server, :table)
  end
end
