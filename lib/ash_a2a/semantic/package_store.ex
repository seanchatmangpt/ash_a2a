defmodule AshA2A.Semantic.PackageStore do
  @moduledoc """
  In-memory registry correlating an `AshA2A.Semantic.ExecutionPackage`'s own
  content-addressed `fingerprint` back to the real, full package struct that
  produced it (GAP B: receipt -> feedback -> replan closure).

  A caller only ever receives the `fingerprint` on the wire (`ExecutionPackage
  .to_reply/1`'s `"execution_package_fingerprint"` body field) -- the
  fingerprint is a SHA-256 digest of `{source.id, ontology.fingerprint,
  planning.fingerprint, candidate.fingerprint}`
  (`AshA2A.Semantic.ExecutionPackage.fingerprint/1`), a one-way hash, so it
  cannot be inverted back into the real `source`/`semantic_ir`/`ontology`/
  `planning_ir`/`plan_candidate` structs `AshA2A.Semantic.Compiler.replan/4`
  needs as its second argument. Something real has to keep the full struct
  addressable by that same fingerprint, or a continuation request naming only
  the fingerprint could never resolve to a real package to replan from.

  Deliberately a SEPARATE store from `AshA2A.ReceiptStore`, not a field bolted
  onto it: a `AshA2A.Receipt` records what a real DO attempt observed
  (`standing: :observed`), while an `ExecutionPackage` is candidate-only,
  `authority: :none` semantic-compiler output (`standing: :candidate`) --
  conflating the two stores would let a candidate be retrieved as if it were
  receipted evidence. `AshA2A.Agent.dispatch_semantic/2` is the only production
  writer (every real compile and every real replan stores its own resulting
  package here, keyed by that package's own `fingerprint`); `AshA2A.Agent`'s
  continuation-replan path is the only production reader.

  In-memory and best-effort, matching this codebase's own `AshA2A.
  ReceiptStore.Memory` default: losing pending candidate packages on a process
  restart is an acceptable real trade-off for a `standing: :candidate,
  authority: :none` value that was never receipted evidence and never granted
  any authority -- unlike a committed `AshA2A.Receipt`, nothing of consequence
  was ever true because a package merely existed here.

  ## Bounds (SEC-09)

  The store is bounded so an opted-in semantic surface cannot grow memory
  without limit: at most `:max_entries` packages (option, else
  `config :ash_a2a, :semantic_package_store_max_entries`, default 10_000),
  evicted oldest-first (FIFO by insertion), and each entry expires
  `:ttl_ms` after insertion (option, else
  `config :ash_a2a, :semantic_package_store_ttl_ms`, default 1 hour). An
  expired or evicted fingerprint fetches as `:error`, exactly like an
  unknown one -- a continuation naming it is refused by the caller, never
  resolved to a stale package. Re-putting an existing fingerprint refreshes
  its TTL and FIFO position.
  """
  use GenServer

  alias AshA2A.Semantic.ExecutionPackage

  @default_max_entries 10_000
  @default_ttl_ms :timer.hours(1)

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       entries: %{},
       order: :queue.new(),
       max_entries:
         opts
         |> Keyword.get_lazy(:max_entries, fn ->
           Application.get_env(:ash_a2a, :semantic_package_store_max_entries)
         end)
         |> bound_or_default(@default_max_entries),
       ttl_ms:
         opts
         |> Keyword.get_lazy(:ttl_ms, fn ->
           Application.get_env(:ash_a2a, :semantic_package_store_ttl_ms)
         end)
         |> bound_or_default(@default_ttl_ms)
     }}
  end

  # Fail closed on a malformed bound: a non-integer max_entries (e.g. an
  # unparsed env string) compares larger than every integer and would disable
  # eviction; a non-integer ttl_ms would crash every put.
  defp bound_or_default(value, _default) when is_integer(value) and value > 0, do: value
  defp bound_or_default(_value, default), do: default

  @doc "Stores `package`, keyed by its own real `fingerprint`."
  @spec put(ExecutionPackage.t(), keyword()) :: :ok
  def put(%ExecutionPackage{} = package, opts \\ []) do
    GenServer.call(server(opts), {:put, package})
  end

  @doc "Fetches the real `ExecutionPackage` previously stored under `fingerprint`."
  @spec fetch(String.t(), keyword()) :: {:ok, ExecutionPackage.t()} | :error
  def fetch(fingerprint, opts \\ []) when is_binary(fingerprint) do
    GenServer.call(server(opts), {:fetch, fingerprint})
  end

  @doc """
  Number of stored entries. Bounded by `:max_entries`; an expired entry is
  removed lazily (on its next fetch, or by FIFO eviction), so it may still be
  counted here until then.
  """
  @spec size(keyword()) :: non_neg_integer()
  def size(opts \\ []), do: GenServer.call(server(opts), :size)

  @impl true
  def handle_call({:put, %ExecutionPackage{fingerprint: fp} = package}, _from, state) do
    now = now_ms()
    # Drop any older position for this key so FIFO order stays exact.
    order = :queue.filter(&(&1 != fp), state.order)
    entries = Map.put(state.entries, fp, {package, now + state.ttl_ms})

    state =
      %{state | entries: entries, order: :queue.in(fp, order)}
      |> evict_over_capacity()

    {:reply, :ok, state}
  end

  def handle_call({:fetch, fingerprint}, _from, state) do
    now = now_ms()

    case Map.get(state.entries, fingerprint) do
      {%ExecutionPackage{} = package, expires_at} when expires_at > now ->
        {:reply, {:ok, package}, state}

      {_package, _expired} ->
        {:reply, :error,
         %{
           state
           | entries: Map.delete(state.entries, fingerprint),
             order: :queue.filter(&(&1 != fingerprint), state.order)
         }}

      nil ->
        {:reply, :error, state}
    end
  end

  def handle_call(:size, _from, state), do: {:reply, map_size(state.entries), state}

  defp evict_over_capacity(state) do
    if map_size(state.entries) > state.max_entries do
      {{:value, oldest}, order} = :queue.out(state.order)
      evict_over_capacity(%{state | entries: Map.delete(state.entries, oldest), order: order})
    else
      state
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp server(opts), do: Keyword.get(opts, :name, __MODULE__)
end
