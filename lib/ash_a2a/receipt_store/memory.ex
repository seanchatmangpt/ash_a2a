defmodule AshA2A.ReceiptStore.Memory do
  @moduledoc """
  In-memory reference receipt store for local/runtime composition.

  Also implements the optional RFC-SA2A-001 S55 actuation-claim callbacks
  (`claim_actuation/3`, `commit_actuation/3`, `release_actuation/2`). The
  actuation index lives in the same `GenServer` state under `{:actuation, id}`
  keys, so it inherits the same free serialization the command claim already
  gets from the process mailbox -- two concurrent claimants on one effect are
  ordered by the mailbox, not by a racy read-then-write.

  A claimed-but-not-yet-committed command is `:in_flight` unless
  `AshA2A.ReceiptStore.ClaimLease` judges it abandoned (its configured lease
  has elapsed AND no `AshA2A.ReceiptOutbox` anchor exists for it), in which
  case it is reclaimed as a fresh claim -- see that module for why this can
  never reclaim a claim that reached receipt preparation.

  An in-flight actuation (effect) claim is reclaimed the same way: see
  `AshA2A.ReceiptStore.ActuationClaimLease` for why deferring to the
  claimant's own primary command claim's `ClaimLease.abandoned?/2` verdict is
  a sound liveness guarantee one layer down from the primary claim.

  ## Fencing (finding R4)

  `commit/2` accepts a receipt only when its `execution_id` equals the
  execution id of the claim currently recorded for that command id. A stale
  executor whose claim was reclaimed gets `{:error, :stale_execution}` and
  can never overwrite the new executor's receipt. `confirm_claim/3` lets
  `AshA2A.CommandBus` re-check ownership after preparing its receipt anchor
  and before DO.

  ## Bounded state and call timeouts (findings R12, PERF-09)

  This store is volatile by construction: a restart of this process or node
  drops every claim, so it is refused as a production store by
  `AshA2A.ReceiptStore.boot_check/1`. For long-running non-production hosts:

    * `:receipt_ttl_ms` (opt or `config :ash_a2a, :receipt_ttl_ms`; default
      `nil` = keep forever) -- a periodic sweep deletes entries whose receipt
      is committed and older than the TTL. In-flight entries (`receipt: nil`)
      are never swept, and a committed primary claim still referenced by an
      in-flight actuation entry is kept.
    * `:max_entries` (opt or `config :ash_a2a,
      :receipt_store_memory_max_entries`; default `nil` = unbounded) --
      when exceeded, the oldest committed entries are evicted first; in-flight
      entries are never evicted, so the bound is soft under an all-in-flight
      load.
    * `:call_timeout` (per-call opt or `config :ash_a2a,
      :receipt_store_call_timeout_ms`; default 5_000) -- bounds every
      `GenServer.call/3`; a timeout exits and `AshA2A.CommandBus` maps it to
      `:receipt_store_unavailable`.

  Evicting a committed receipt forgets its idempotency key: a resubmission of
  the same command id after the TTL executes again. Size the TTL above every
  client's retry horizon.
  """
  use GenServer

  @behaviour AshA2A.ReceiptStore

  alias AshA2A.{Actuation, Command, Identity, Receipt}
  alias AshA2A.ReceiptStore.{ActuationClaimLease, ClaimLease}

  @default_call_timeout 5_000
  @default_sweep_interval_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) when is_list(opts) do
    ttl_ms = Keyword.get(opts, :receipt_ttl_ms, Application.get_env(:ash_a2a, :receipt_ttl_ms))

    max_entries =
      Keyword.get(
        opts,
        :max_entries,
        Application.get_env(:ash_a2a, :receipt_store_memory_max_entries)
      )

    sweep_interval_ms =
      Keyword.get(
        opts,
        :sweep_interval_ms,
        if(is_integer(ttl_ms), do: min(ttl_ms, @default_sweep_interval_ms))
      )

    state = %{
      entries: %{},
      ttl_ms: ttl_ms,
      max_entries: max_entries,
      sweep_interval_ms: sweep_interval_ms
    }

    {:ok, schedule_sweep(state)}
  end

  # Backwards-compatible: the pre-R12 store was started with a bare map state.
  def init(%{} = _legacy_state), do: init([])

  @impl true
  def claim(%Command{} = command, opts \\ []) do
    call(opts, {:claim, command, Keyword.take(opts, [:claim_lease_ms, :execution_id])})
  end

  @impl true
  def commit(%Receipt{} = receipt, opts \\ []) do
    call(opts, {:commit, receipt})
  end

  @impl true
  def fetch(%Identity{kind: :command} = command_id, opts \\ []) do
    call(opts, {:fetch, Identity.external(command_id)})
  end

  @doc """
  Confirms `execution_id` still owns the claim for `command_id` (finding R4).
  `:ok` when it does, `{:error, :stale_execution}` when the claim was
  reclaimed by (or never belonged to) another execution.
  """
  @impl true
  @spec confirm_claim(Identity.t(), Identity.t(), keyword()) :: :ok | {:error, :stale_execution}
  def confirm_claim(
        %Identity{kind: :command} = command_id,
        %Identity{} = execution_id,
        opts \\ []
      ) do
    call(opts, {:confirm_claim, Identity.external(command_id), execution_id})
  end

  @impl true
  def claim_actuation(%Actuation{} = actuation, %Command{} = command, opts \\ []) do
    call(opts, {:claim_actuation, actuation, command.command_id, lease_opts(opts)})
  end

  @impl true
  def commit_actuation(%Actuation{} = actuation, %Receipt{} = receipt, opts \\ []) do
    call(opts, {:commit_actuation, actuation, receipt})
  end

  @impl true
  def release_actuation(%Actuation{} = actuation, opts \\ []) do
    call(opts, {:release_actuation, actuation})
  end

  @doc "Number of entries currently held (primary claims plus actuation entries)."
  @spec size(keyword()) :: non_neg_integer()
  def size(opts \\ []), do: call(opts, :size)

  @doc "Runs one retention sweep synchronously (see moduledoc). Returns the evicted count."
  @spec sweep(keyword()) :: non_neg_integer()
  def sweep(opts \\ []), do: call(opts, :sweep)

  @impl true
  def handle_call({:claim, command, claim_opts}, _from, state) do
    key = Identity.external(command.command_id)

    case Map.get(state.entries, key) do
      nil ->
        {execution_id, entry} = fresh_claim_entry(command, claim_opts)
        {:reply, {:execute, execution_id}, put_entry(state, key, entry)}

      %{fingerprint: fingerprint, receipt: %Receipt{} = receipt}
      when fingerprint == command.fingerprint ->
        {:reply, {:replay, Receipt.replay(receipt)}, state}

      %{fingerprint: fingerprint} = entry when fingerprint == command.fingerprint ->
        # Bounded claim lease + reconciliation (closes the SA2A-CHAOS
        # liveness gap): a crash after this claim recorded `receipt: nil`
        # but before a receipt anchor was ever prepared leaves no live
        # executor to ever clear it. The GenServer mailbox already
        # serializes this decision the same way it serializes a fresh
        # claim, so reclaiming here needs no separate CAS -- see
        # `AshA2A.ReceiptStore.ClaimLease` for the abandonment test (lease
        # elapsed AND no outbox anchor) and why a claim that DID reach the
        # outbox is never reclaimed.
        if ClaimLease.abandoned?(Map.get(entry, :claimed_at), command.command_id, claim_opts) do
          {execution_id, fresh} = fresh_claim_entry(command, claim_opts)
          {:reply, {:execute, execution_id}, put_entry(state, key, fresh)}
        else
          {:reply, {:error, :in_flight}, state}
        end

      _ ->
        {:reply, {:error, :command_conflict}, state}
    end
  end

  def handle_call({:commit, %Receipt{} = receipt}, _from, state) do
    key = Identity.external(receipt.command_id)

    case Map.get(state.entries, key) do
      %{fingerprint: fingerprint} = entry when fingerprint == receipt.fingerprint ->
        # Execution-id fencing (finding R4): only the execution that holds
        # the claim may commit. A stale executor whose claim was reclaimed
        # must never overwrite the new executor's receipt.
        if Map.get(entry, :execution_id) == receipt.execution_id do
          committed = %{entry | receipt: receipt} |> Map.put(:committed_at, now_ms())
          {:reply, :ok, state |> put_entry(key, committed) |> enforce_max_entries()}
        else
          {:reply, {:error, :stale_execution}, state}
        end

      _ ->
        {:reply, {:error, :unclaimed_command}, state}
    end
  end

  def handle_call({:fetch, key}, _from, state) do
    case Map.get(state.entries, key) do
      %{receipt: %Receipt{} = receipt} -> {:reply, {:ok, receipt}, state}
      _ -> {:reply, :error, state}
    end
  end

  def handle_call({:confirm_claim, key, execution_id}, _from, state) do
    case Map.get(state.entries, key) do
      %{execution_id: ^execution_id} -> {:reply, :ok, state}
      _ -> {:reply, {:error, :stale_execution}, state}
    end
  end

  def handle_call(
        {:claim_actuation, %Actuation{} = actuation, command_id, lease_opts},
        _from,
        state
      ) do
    key = actuation_key(actuation)
    idempotency = Identity.external(actuation.idempotency_key)

    case Map.get(state.entries, key) do
      nil ->
        entry = %{
          idempotency_key: idempotency,
          command_id: command_id,
          receipt: nil
        }

        {:reply, :proceed, put_entry(state, key, entry)}

      %{idempotency_key: ^idempotency, receipt: %Receipt{} = receipt} ->
        {:reply, {:duplicate, Receipt.replay(receipt)}, state}

      %{idempotency_key: ^idempotency, command_id: claimant_command_id} = entry ->
        # Bounded actuation-claim lease + reconciliation (RFC-SA2A-001 S55,
        # ARD S40's idempotency-store liveness requirement, one index below
        # the primary command claim). See
        # `AshA2A.ReceiptStore.ActuationClaimLease.decide/3`: a claimant
        # whose primary claim already carries a finalized receipt is a
        # completed effect (duplicate, never re-run -- finding R1); one that
        # never crossed the pre-DO boundary is reclaimable.
        primary_claim = Map.get(state.entries, Identity.external(claimant_command_id))

        case ActuationClaimLease.decide(primary_claim, claimant_command_id, lease_opts) do
          :reclaim ->
            fresh = %{entry | command_id: command_id, receipt: nil}
            {:reply, :proceed, put_entry(state, key, fresh)}

          {:duplicate, %Receipt{} = receipt} ->
            healed = %{entry | receipt: receipt} |> Map.put(:committed_at, now_ms())
            {:reply, {:duplicate, Receipt.replay(receipt)}, put_entry(state, key, healed)}

          :in_flight ->
            {:reply, {:error, :actuation_in_flight}, state}
        end

      _ ->
        {:reply, {:error, :actuation_conflict}, state}
    end
  end

  def handle_call(
        {:commit_actuation, %Actuation{} = actuation, %Receipt{} = receipt},
        _from,
        state
      ) do
    key = actuation_key(actuation)

    case Map.get(state.entries, key) do
      nil ->
        {:reply, {:error, :unclaimed_actuation}, state}

      entry ->
        committed = %{entry | receipt: receipt} |> Map.put(:committed_at, now_ms())
        {:reply, :ok, put_entry(state, key, committed)}
    end
  end

  def handle_call({:release_actuation, %Actuation{} = actuation}, _from, state) do
    key = actuation_key(actuation)

    case Map.get(state.entries, key) do
      # Only an unexecuted claim is releasable. Dropping a claim that already
      # carries a receipt would re-open a completed effect for re-actuation,
      # which is the exact thing S55 exists to prevent.
      %{receipt: nil} -> {:reply, :ok, %{state | entries: Map.delete(state.entries, key)}}
      _ -> {:reply, :ok, state}
    end
  end

  def handle_call(:size, _from, state), do: {:reply, map_size(state.entries), state}

  def handle_call(:sweep, _from, state) do
    {evicted, state} = sweep_expired(state)
    {:reply, evicted, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    {_evicted, state} = sweep_expired(state)
    {:noreply, schedule_sweep(state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- retention (R12 / PERF-09) --------------------------------------------

  defp schedule_sweep(%{ttl_ms: ttl_ms, sweep_interval_ms: interval} = state)
       when is_integer(ttl_ms) and is_integer(interval) and interval > 0 do
    Process.send_after(self(), :sweep, interval)
    state
  end

  defp schedule_sweep(state), do: state

  defp sweep_expired(%{ttl_ms: ttl_ms} = state) when is_integer(ttl_ms) do
    cutoff = now_ms() - ttl_ms
    pinned = pinned_primary_keys(state.entries)

    expired =
      for {key, %{receipt: %Receipt{}, committed_at: at}} <- state.entries,
          is_integer(at) and at <= cutoff,
          not MapSet.member?(pinned, key),
          do: key

    {length(expired), %{state | entries: Map.drop(state.entries, expired)}}
  end

  defp sweep_expired(state), do: {0, state}

  defp enforce_max_entries(%{max_entries: max} = state)
       when is_integer(max) and max > 0 and map_size(state.entries) > max do
    pinned = pinned_primary_keys(state.entries)
    overflow = map_size(state.entries) - max

    victims =
      state.entries
      |> Enum.filter(fn {key, entry} ->
        match?(%{receipt: %Receipt{}, committed_at: at} when is_integer(at), entry) and
          not MapSet.member?(pinned, key)
      end)
      |> Enum.sort_by(fn {_key, entry} -> entry.committed_at end)
      |> Enum.take(overflow)
      |> Enum.map(&elem(&1, 0))

    %{state | entries: Map.drop(state.entries, victims)}
  end

  defp enforce_max_entries(state), do: state

  # A committed primary claim still referenced by an in-flight actuation
  # entry is the evidence `ActuationClaimLease.decide/3` needs to answer
  # `{:duplicate, _}` instead of refusing forever -- never evict it.
  defp pinned_primary_keys(entries) do
    for {{:actuation, _}, %{receipt: nil, command_id: %Identity{} = command_id}} <- entries,
        into: MapSet.new(),
        do: Identity.external(command_id)
  end

  defp put_entry(state, key, entry), do: %{state | entries: Map.put(state.entries, key, entry)}

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp actuation_key(%Actuation{actuation_id: actuation_id}),
    do: {:actuation, Identity.external(actuation_id)}

  defp call(opts, message) do
    timeout =
      Keyword.get(opts, :call_timeout) ||
        Application.get_env(:ash_a2a, :receipt_store_call_timeout_ms, @default_call_timeout)

    GenServer.call(server(opts), message, timeout)
  end

  defp server(opts), do: Keyword.get(opts, :name, __MODULE__)

  defp lease_opts(opts), do: Keyword.take(opts, [:claim_lease_ms])

  # `opts[:execution_id]` lets `AshA2A.ReceiptOutbox` re-create a lost claim
  # under an outboxed receipt's own execution id (so the fenced commit and the
  # receipt's binding both hold); every other caller gets a fresh id.
  defp fresh_claim_entry(%Command{} = command, opts) do
    execution_id =
      case Keyword.get(opts, :execution_id) do
        %Identity{kind: :execution} = given -> given
        _ -> Identity.execution(Ash.UUIDv7.generate())
      end

    entry = %{
      fingerprint: command.fingerprint,
      execution_id: execution_id,
      receipt: nil,
      claimed_at: ClaimLease.now()
    }

    {execution_id, entry}
  end
end
