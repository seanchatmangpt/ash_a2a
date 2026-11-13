# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.A2ATransport.TaskEvents do
  @moduledoc """
  Per-task, sequence-numbered A2A event log with multi-subscriber fan-out.

  `publish/4` is serialized through this process: it assigns the next
  monotonic `seq` for the task, appends `{seq, kind, payload, final?}` to an
  `:ordered_set` ETS log, then sends

      {:a2a_task_event, task_id, seq, kind, payload, final?}

  to every process registered under `task_id` in the transport's duplicate-key
  `Registry`. `subscribe/2` registers the caller *before* reading the backlog,
  so an event is either in the returned backlog or delivered as a message
  (possibly both -- callers drop `seq <= last_seq`). No event can fall between
  the two.

  Status-bearing events (`kind` `"task"` or `"status-update"`) are also handed
  to `AshA2A.A2ATransport.PushDelivery` for every push config of the task.
  `"artifact-update"` events are intentionally NOT pushed: the pinned v1.0
  proto (`priv/a2a_v1_spec_corpus/a2a.proto`) defines push configs as
  "push notifications for task updates" and the delivered payload is the task
  / status snapshot, and receivers fetch artifacts with `tasks/get`.

  A terminal task's push configs are deleted together with its swept event
  log (`retention_ms` after its final event), so configs do not accumulate
  for tasks that can never transition again.

  Memory is bounded: a finalized task's log is swept `retention_ms` after its
  final event, and each task keeps at most `max_events` events (oldest
  dropped).
  """

  use GenServer

  alias AshA2A.A2ATransport
  alias AshA2A.A2ATransport.{EventLog, PushConfigStore, PushDelivery, PushQueue}

  @type kind :: String.t()
  @type event :: {non_neg_integer(), kind(), map(), boolean()}

  @doc false
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  @doc """
  Appends an event to `task_id`'s log and fans it out. Returns its seq.

  Generation-bearing kinds (`"status-update"`, `"artifact-update"`,
  `"message-update"`) carry the task's `generation` after the mutation:
  `opts[:generation]`, else the generation already in the payload, else the
  next value after the task's last logged generation. A supplied generation
  that is not strictly greater than the last one logged for the task (a
  duplicate) is replaced by `last + 1`, so no two events of one task ever
  share a generation. The resolved value is written into the logged payload.
  `"task"` snapshots never consume a generation; they only raise the floor.
  """
  @spec publish(atom(), String.t(), kind(), map(), boolean(), keyword()) :: non_neg_integer()
  def publish(transport, task_id, kind, payload, final? \\ false, opts \\ []) do
    GenServer.call(
      A2ATransport.events_name(transport),
      {:publish, task_id, kind, payload, final?, opts}
    )
  end

  @doc """
  Registers the caller for `task_id` and returns the logged backlog, ordered
  by seq. `opts[:version]` is the subscriber's negotiated A2A version
  (default `"1.0"`): `"message-update"` events are only delivered (live and in
  the returned backlog) to subscribers at `>= 1.1`.
  """
  @spec subscribe(atom(), String.t(), keyword()) :: [event()]
  def subscribe(transport, task_id, opts \\ []) do
    version = Keyword.get(opts, :version) || "1.0"
    {:ok, _} = Registry.register(A2ATransport.registry_name(transport), task_id, version)
    transport |> backlog(task_id) |> visible(version)
  end

  @doc "Unregisters the caller for `task_id` and drains queued events."
  @spec unsubscribe(atom(), String.t()) :: :ok
  def unsubscribe(transport, task_id) do
    Registry.unregister(A2ATransport.registry_name(transport), task_id)
    drain(task_id)
  end

  @gated_kinds ["message-update", "error"]
  @generation_keys ["statusUpdate", "artifactUpdate", "messageUpdate"]

  @doc "Whether an event of `kind` is deliverable to a subscriber at `version`."
  @spec deliverable?(kind(), String.t() | nil) :: boolean()
  def deliverable?(kind, version) when kind in @gated_kinds,
    do: AshA2A.Protocol.Version.at_least?(version, "1.1")

  def deliverable?(_kind, _version), do: true

  @doc "Drops the events a subscriber at `version` must not see."
  @spec visible([event()], String.t() | nil) :: [event()]
  def visible(events, version),
    do: Enum.filter(events, fn {_, kind, _, _} -> deliverable?(kind, version) end)

  @doc "The `generation` carried by a logged `StreamResponse` payload, or `nil`."
  @spec generation_of(term()) :: pos_integer() | nil
  def generation_of(%{} = payload) do
    inner =
      Enum.find_value(@generation_keys ++ ["task"], fn key ->
        case payload[key] do
          %{} = m -> m
          _ -> nil
        end
      end)

    case inner && inner["generation"] do
      g when is_integer(g) and g > 0 ->
        g

      g when is_binary(g) ->
        case Integer.parse(g) do
          {n, ""} when n > 0 -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def generation_of(_), do: nil

  @doc """
  Computes the `lastSeenGeneration` resume plan from a task's raw (unfiltered)
  log.

  Returns `{:ok, replay, cursor_seq}` (events with `generation > last_gen`,
  in seq order, and the seq cursor below which live duplicates are dropped) or
  `:unavailable` when the log no longer retains what followed `last_gen`, in
  which case callers open with a Task snapshot instead.
  """
  @spec replay_from_generation([event()], non_neg_integer(), non_neg_integer() | nil) ::
          {:ok, [event()], non_neg_integer()} | :unavailable
  def replay_from_generation(log, last_gen, current_gen) do
    events = Enum.reject(log, fn {_, kind, _, _} -> kind == "task" end)
    gens = for {_, _, p, _} <- events, g = generation_of(p), do: g
    max_log = Enum.max(gens, fn -> 0 end)
    current = max(current_gen || 0, max_log)
    max_seq = log |> Enum.map(&elem(&1, 0)) |> Enum.max(fn -> 0 end)

    cond do
      # Ahead of the server (e.g. after a restart): cannot resume, resync.
      last_gen > current ->
        :unavailable

      last_gen == current ->
        {:ok, [], max_seq}

      gens != [] and Enum.min(gens) <= last_gen + 1 and max_log >= current ->
        replay =
          Enum.filter(events, fn {_, _, p, _} ->
            g = generation_of(p)
            is_integer(g) and g > last_gen
          end)

        case replay do
          [] -> {:ok, [], max_seq}
          [{first_seq, _, _, _} | _] -> {:ok, replay, first_seq - 1}
        end

      true ->
        :unavailable
    end
  end

  @doc "The state string of a status-bearing payload (`task` or `statusUpdate`), or `nil`."
  @spec payload_state(term()) :: String.t() | nil
  def payload_state(payload) do
    state =
      get_in(payload, ["statusUpdate", "status", "state"]) ||
        get_in(payload, ["task", "status", "state"])

    if is_binary(state),
      do: state |> String.downcase() |> String.replace_prefix("task_state_", ""),
      else: nil
  end

  @terminal_states ~w(completed canceled cancelled failed rejected)
  @interrupted_states ~w(input_required input-required auth_required auth-required)

  @doc "Whether the payload's state is terminal (the only state that closes a stream)."
  @spec terminal_payload?(term()) :: boolean()
  def terminal_payload?(payload), do: payload_state(payload) in @terminal_states

  @doc "Whether the payload's state is terminal or interrupted (the pump has finished)."
  @spec closing_payload?(term()) :: boolean()
  def closing_payload?(payload),
    do: payload_state(payload) in (@terminal_states ++ @interrupted_states)

  @doc """
  Sends a `StreamError` to ONE subscriber process (default: the caller) as
  `{:a2a_stream_error, task_id, wrapped}`. It is not logged, has no seq, is not
  broadcast and does not close the stream; the SSE follow loop writes it as a
  frame and keeps following.
  """
  @spec send_stream_error(String.t(), AshA2A.Protocol.StreamError.t(), pid()) ::
          :ok | {:error, term()}
  def send_stream_error(task_id, %AshA2A.Protocol.StreamError{} = error, to \\ self()) do
    case AshA2A.Protocol.JSON.encode_stream_response(error) do
      {:ok, wrapped} ->
        send(to, {:a2a_stream_error, task_id, wrapped})
        :ok

      {:error, _} = err ->
        err
    end
  end

  @doc "The logged events of `task_id`, ordered by seq."
  @spec backlog(atom(), String.t()) :: [event()]
  def backlog(transport, task_id) do
    transport
    |> A2ATransport.events_name()
    |> :ets.select([
      {{{task_id, :"$1"}, :"$2", :"$3", :"$4"}, [], [{{:"$1", :"$2", :"$3", :"$4"}}]}
    ])
  end

  @doc "Webhook delivery attempts recorded for `task_id` (newest last)."
  @spec attempts(atom(), String.t()) :: [map()]
  def attempts(transport, task_id),
    do: GenServer.call(A2ATransport.events_name(transport), {:attempts, task_id})

  @doc "The `push:` delivery/policy options this transport instance was started with."
  @spec push_opts(atom()) :: keyword()
  def push_opts(transport),
    do: GenServer.call(A2ATransport.events_name(transport), :push_opts)

  @doc false
  def record_attempt(transport, task_id, attempt),
    do: GenServer.cast(A2ATransport.events_name(transport), {:attempt, task_id, attempt})

  defp drain(task_id) do
    receive do
      {:a2a_task_event, ^task_id, _, _, _, _} -> drain(task_id)
      {:a2a_stream_error, ^task_id, _} -> drain(task_id)
    after
      0 -> :ok
    end
  end

  # -- server -------------------------------------------------------------------

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    :ets.new(name, [:ordered_set, :protected, :named_table, read_concurrency: true])
    {log_mod, log_opts} = EventLog.normalize(Keyword.get(opts, :event_log))
    {:ok, log_handle} = log_mod.open(log_opts)

    state = %{
      table: name,
      transport: Keyword.fetch!(opts, :transport),
      retention_ms: Keyword.fetch!(opts, :retention_ms),
      max_events: Keyword.fetch!(opts, :max_events),
      push: Keyword.fetch!(opts, :push),
      log: {log_mod, log_handle},
      seqs: %{},
      gens: %{},
      counts: %{},
      attempts: %{},
      pq: PushQueue.new()
    }

    {:ok, restore(state)}
  end

  @impl true
  def terminate(_reason, %{log: {mod, handle}}), do: mod.close(handle)

  # Replays the backend journal into the ETS log and rebuilds seq/generation/count
  # bookkeeping; finalized or interrupted tasks get their retention sweep re-armed.
  defp restore(%{log: {mod, handle}} = state) do
    rows = mod.load_all(handle)

    state =
      Enum.reduce(rows, state, fn {task_id, seq, kind, payload, final?}, st ->
        true = :ets.insert(st.table, {{task_id, seq}, kind, payload, final?})
        gen = generation_of(payload)

        %{
          st
          | seqs: Map.update(st.seqs, task_id, seq, &max(&1, seq)),
            gens: if(gen, do: Map.update(st.gens, task_id, gen, &max(&1, gen)), else: st.gens),
            counts: Map.put(st.counts, task_id, Map.get(st.counts, task_id, 0) + 1)
        }
      end)

    for {task_id, seq} <- state.seqs do
      case :ets.lookup(state.table, {task_id, seq}) do
        [{_, kind, payload, final?}] ->
          if final? or (kind == "status-update" and closing_payload?(payload)),
            do: Process.send_after(self(), {:sweep, task_id, seq}, state.retention_ms)

        _ ->
          :ok
      end
    end

    state
  end

  @impl true
  def handle_call({:publish, task_id, kind, payload, final?, opts}, _from, state) do
    seq = Map.get(state.seqs, task_id, 0) + 1
    {payload, gens} = assign_generation(state.gens, task_id, kind, payload, opts)
    true = :ets.insert(state.table, {{task_id, seq}, kind, payload, final?})
    {log_mod, log_handle} = state.log
    :ok = log_mod.append(log_handle, task_id, seq, kind, payload, final?)

    state =
      %{state | seqs: Map.put(state.seqs, task_id, seq), gens: gens} |> trim(task_id, seq)

    Registry.dispatch(A2ATransport.registry_name(state.transport), task_id, fn entries ->
      for {pid, version} <- entries,
          deliverable?(kind, version),
          do: send(pid, {:a2a_task_event, task_id, seq, kind, payload, final?})
    end)

    state =
      if kind in ["task", "status-update", "message-update"],
        do: push(state, task_id, seq, kind, payload),
        else: state

    # An interrupted (input/auth-required) event does not close the stream but
    # its log must still age out if the task never moves again; the sweep is
    # cancelled implicitly by any later publish (seq check).
    if final? or (kind == "status-update" and closing_payload?(payload)),
      do: Process.send_after(self(), {:sweep, task_id, seq}, state.retention_ms)

    {:reply, seq, state}
  end

  def handle_call(:push_opts, _from, state), do: {:reply, state.push, state}

  def handle_call({:attempts, task_id}, _from, state),
    do: {:reply, state.attempts |> Map.get(task_id, []) |> Enum.reverse(), state}

  @impl true
  def handle_cast({:attempt, task_id, attempt}, state) do
    # dual-safe Map.update (absent key stores default unmodified)
    attempts =
      case Map.fetch(state.attempts, task_id) do
        :error -> Map.put(state.attempts, task_id, [attempt])
        {:ok, prior} -> Map.put(state.attempts, task_id, Enum.take([attempt | prior], 100))
      end

    {:noreply, %{state | attempts: attempts}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, %{state | pq: PushQueue.down(state.pq, ref, start_fun(state))}}

  def handle_info({:sweep, task_id, seq}, state) do
    # Only sweep when nothing was published after the final event we scheduled for.
    if Map.get(state.seqs, task_id) == seq do
      # Push configs die with their task, but only a TERMINAL task: an
      # input-required/auth-required event is also "final" for a stream yet
      # the task can still continue and must keep its webhooks.
      if terminal_event?(state.table, task_id, seq) do
        PushConfigStore.delete_task(A2ATransport.push_store_name(state.transport), task_id)
      end

      :ets.match_delete(state.table, {{task_id, :_}, :_, :_, :_})
      {log_mod, log_handle} = state.log
      :ok = log_mod.delete_task(log_handle, task_id)

      {:noreply,
       %{
         state
         | seqs: Map.delete(state.seqs, task_id),
           gens: Map.delete(state.gens, task_id),
           counts: Map.delete(state.counts, task_id),
           attempts: Map.delete(state.attempts, task_id)
       }}
    else
      {:noreply, state}
    end
  end

  defp terminal_event?(table, task_id, seq) do
    case :ets.lookup(table, {task_id, seq}) do
      [{_, _kind, payload, _final?}] -> terminal_payload?(payload)
      _ -> false
    end
  end

  # Generation bookkeeping (see publish/6). Returns {payload, gens}.
  defp assign_generation(gens, task_id, "task", payload, opts) do
    floor = Keyword.get(opts, :generation) || generation_of(payload) || 0
    {payload, Map.put(gens, task_id, max(Map.get(gens, task_id, 0), floor))}
  end

  defp assign_generation(gens, task_id, kind, payload, opts)
       when kind in ["status-update", "artifact-update", "message-update"] do
    last = Map.get(gens, task_id, 0)
    explicit = Keyword.get(opts, :generation) || generation_of(payload)
    gen = if is_integer(explicit) and explicit > last, do: explicit, else: last + 1
    {put_generation(payload, gen), Map.put(gens, task_id, gen)}
  end

  defp assign_generation(gens, _task_id, _kind, payload, _opts), do: {payload, gens}

  defp put_generation(%{} = payload, gen) do
    case Enum.find(@generation_keys, &is_map(payload[&1])) do
      nil -> payload
      key -> Map.update!(payload, key, &Map.put(&1, "generation", gen))
    end
  end

  defp put_generation(payload, _gen), do: payload

  defp trim(state, task_id, seq) do
    count = Map.get(state.counts, task_id, 0) + 1

    if count > state.max_events do
      :ets.delete(state.table, {task_id, seq - state.max_events})
      {log_mod, log_handle} = state.log
      :ok = log_mod.delete(log_handle, task_id, seq - state.max_events)
      state
    else
      %{state | counts: Map.put(state.counts, task_id, count)}
    end
  end

  # Deliveries are serialized per {task_id, config_id} (PushQueue) so event N+1
  # can never overtake event N while N is in retry backoff. A head delivery that
  # exhausts its attempts is recorded by PushDelivery, then the next proceeds.
  @max_queued_per_key 1_000

  defp push(state, task_id, seq, kind, payload) do
    case PushConfigStore.list(A2ATransport.push_store_name(state.transport), task_id) do
      [] ->
        state

      configs ->
        start = start_fun(state)

        Enum.reduce(configs, state, fn config, st ->
          # Per-config payload shape by the config's protocol_version; the
          # per-{task, config} FIFO queue keeps delivery in generation order.
          case PushDelivery.payload_for(config, kind, payload) do
            :skip ->
              st

            {:ok, body} ->
              cap = Keyword.get(st.push, :max_queued_per_key, @max_queued_per_key)

              {pq, res} =
                PushQueue.enqueue(st.pq, {task_id, config.id}, {config, body, seq}, start, cap)

              st = %{st | pq: pq}

              if res == :dropped do
                {:noreply, st} = handle_cast({:attempt, task_id, drop_attempt(config)}, st)
                st
              else
                st
              end
          end
        end)
    end
  end

  defp drop_attempt(config),
    do: %{
      config_id: config.id,
      attempt: 0,
      outcome: {:dropped, :queue_full},
      at: DateTime.utc_now()
    }

  defp start_fun(state) do
    fn {config, payload, seq} ->
      case PushDelivery.start(state.transport, config, payload, seq, state.push) do
        {:ok, pid} -> {:ok, Process.monitor(pid)}
        _ -> :error
      end
    end
  end
end
