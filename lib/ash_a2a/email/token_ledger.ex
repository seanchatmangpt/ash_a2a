defmodule AshA2A.Email.TokenLedger do
  @moduledoc """
  Single-use ledger for email reply tokens plus a bounded per-sender rate limiter.

  State is owned by one GenServer, so `reserve/4` is atomic: all `(brief_id, n, token)` keys
  of one reply are consumed together or not at all.

    * First use of every key -> `:ok` (keys are consumed, tied to the inbound `message_id`).
    * Any key already consumed -> `{:error, :already_consumed}`, except an exact replay: a
      non-nil `message_id` identical to the one that consumed every key returns
      `{:replay, cached_body | nil}` so the caller can answer idempotently without
      re-dispatching.
    * Capacity: past `:max_entries` consumed keys, new reservations are refused
      (`{:error, :ledger_full}`); eviction would silently re-open replay.

  Rate limit: `rate_check/4` allows at most `max` hits per sender per `window_ms` (sliding,
  timestamps pruned on every call, so memory is bounded by `max` per active sender).

  Authentication and this ledger confer no authority; dispatch stays behind the kernel/grant.

  Options: `:name`, `:max_entries` (default 100_000), `:now` (zero-arity ms clock, default
  monotonic).
  """

  use GenServer

  @type ledger :: GenServer.server()

  def start_link(opts \\ []) do
    gen_opts = if opts[:name], do: [name: opts[:name]], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Atomically consume `[{n, token}]` for `brief_id`."
  @spec reserve(ledger(), String.t(), [{integer(), term()}], String.t() | nil) ::
          :ok | {:replay, map() | nil} | {:error, :already_consumed | :ledger_full}
  def reserve(ledger, brief_id, pairs, message_id),
    do: GenServer.call(ledger, {:reserve, brief_id, pairs, message_id})

  @doc "Cache the response body for an idempotent replay of `message_id`."
  @spec record_result(ledger(), String.t(), String.t() | nil, map()) :: :ok
  def record_result(_ledger, _brief_id, nil, _body), do: :ok

  def record_result(ledger, brief_id, message_id, body),
    do: GenServer.call(ledger, {:record, brief_id, message_id, body})

  @doc "Sliding-window rate check for `sender`."
  @spec rate_check(ledger(), String.t(), pos_integer(), pos_integer()) ::
          :ok | {:error, :rate_limited}
  def rate_check(ledger, sender, max, window_ms),
    do: GenServer.call(ledger, {:rate, sender, max, window_ms})

  # -- server ------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       consumed: %{},
       results: %{},
       hits: %{},
       max: Keyword.get(opts, :max_entries, 100_000),
       now: Keyword.get(opts, :now, fn -> System.monotonic_time(:millisecond) end)
     }}
  end

  @impl GenServer
  def handle_call({:reserve, brief_id, pairs, mid}, _from, st) do
    keys = Enum.map(pairs, fn {n, token} -> {brief_id, n, token} end)
    used = Enum.filter(keys, &Map.has_key?(st.consumed, &1))

    cond do
      used == [] ->
        if map_size(st.consumed) + length(keys) > st.max do
          {:reply, {:error, :ledger_full}, st}
        else
          consumed = Enum.reduce(keys, st.consumed, &Map.put(&2, &1, mid))
          {:reply, :ok, %{st | consumed: consumed}}
        end

      is_binary(mid) and length(used) == length(keys) and
          Enum.all?(used, &(Map.fetch!(st.consumed, &1) == mid)) ->
        {:reply, {:replay, Map.get(st.results, {brief_id, mid})}, st}

      true ->
        {:reply, {:error, :already_consumed}, st}
    end
  end

  def handle_call({:record, brief_id, mid, body}, _from, st),
    do: {:reply, :ok, %{st | results: Map.put(st.results, {brief_id, mid}, body)}}

  def handle_call({:rate, sender, max, window_ms}, _from, st) do
    now = st.now.()
    recent = st.hits |> Map.get(sender, []) |> Enum.filter(&(now - &1 < window_ms))

    if length(recent) >= max do
      {:reply, {:error, :rate_limited}, %{st | hits: Map.put(st.hits, sender, recent)}}
    else
      {:reply, :ok, %{st | hits: Map.put(st.hits, sender, [now | recent])}}
    end
  end
end
