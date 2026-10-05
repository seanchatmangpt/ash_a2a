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

  Memory is bounded: a finalized task's log is swept `retention_ms` after its
  final event, and each task keeps at most `max_events` events (oldest
  dropped).
  """

  use GenServer

  alias AshA2A.A2ATransport
  alias AshA2A.A2ATransport.{PushConfigStore, PushDelivery}

  @type kind :: String.t()
  @type event :: {non_neg_integer(), kind(), map(), boolean()}

  @doc false
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  @doc "Appends an event to `task_id`'s log and fans it out. Returns its seq."
  @spec publish(atom(), String.t(), kind(), map(), boolean()) :: non_neg_integer()
  def publish(transport, task_id, kind, payload, final? \\ false) do
    GenServer.call(
      A2ATransport.events_name(transport),
      {:publish, task_id, kind, payload, final?}
    )
  end

  @doc """
  Registers the caller for `task_id` and returns the logged backlog, ordered
  by seq.
  """
  @spec subscribe(atom(), String.t()) :: [event()]
  def subscribe(transport, task_id) do
    {:ok, _} = Registry.register(A2ATransport.registry_name(transport), task_id, nil)
    backlog(transport, task_id)
  end

  @doc "Unregisters the caller for `task_id` and drains queued events."
  @spec unsubscribe(atom(), String.t()) :: :ok
  def unsubscribe(transport, task_id) do
    Registry.unregister(A2ATransport.registry_name(transport), task_id)
    drain(task_id)
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
    after
      0 -> :ok
    end
  end

  # -- server -------------------------------------------------------------------

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    :ets.new(name, [:ordered_set, :protected, :named_table, read_concurrency: true])

    {:ok,
     %{
       table: name,
       transport: Keyword.fetch!(opts, :transport),
       retention_ms: Keyword.fetch!(opts, :retention_ms),
       max_events: Keyword.fetch!(opts, :max_events),
       push: Keyword.fetch!(opts, :push),
       seqs: %{},
       counts: %{},
       attempts: %{}
     }}
  end

  @impl true
  def handle_call({:publish, task_id, kind, payload, final?}, _from, state) do
    seq = Map.get(state.seqs, task_id, 0) + 1
    true = :ets.insert(state.table, {{task_id, seq}, kind, payload, final?})
    state = %{state | seqs: Map.put(state.seqs, task_id, seq)} |> trim(task_id, seq)

    Registry.dispatch(A2ATransport.registry_name(state.transport), task_id, fn entries ->
      for {pid, _} <- entries,
          do: send(pid, {:a2a_task_event, task_id, seq, kind, payload, final?})
    end)

    if kind in ["task", "status-update"], do: push(state, task_id, seq, payload)
    if final?, do: Process.send_after(self(), {:sweep, task_id, seq}, state.retention_ms)
    {:reply, seq, state}
  end

  def handle_call(:push_opts, _from, state), do: {:reply, state.push, state}

  def handle_call({:attempts, task_id}, _from, state),
    do: {:reply, state.attempts |> Map.get(task_id, []) |> Enum.reverse(), state}

  @impl true
  def handle_cast({:attempt, task_id, attempt}, state) do
    attempts = Map.update(state.attempts, task_id, [attempt], &Enum.take([attempt | &1], 100))
    {:noreply, %{state | attempts: attempts}}
  end

  @impl true
  def handle_info({:sweep, task_id, seq}, state) do
    # Only sweep when nothing was published after the final event we scheduled for.
    if Map.get(state.seqs, task_id) == seq do
      :ets.match_delete(state.table, {{task_id, :_}, :_, :_, :_})

      {:noreply,
       %{
         state
         | seqs: Map.delete(state.seqs, task_id),
           counts: Map.delete(state.counts, task_id),
           attempts: Map.delete(state.attempts, task_id)
       }}
    else
      {:noreply, state}
    end
  end

  defp trim(state, task_id, seq) do
    count = Map.get(state.counts, task_id, 0) + 1

    if count > state.max_events do
      :ets.delete(state.table, {task_id, seq - state.max_events})
      state
    else
      %{state | counts: Map.put(state.counts, task_id, count)}
    end
  end

  defp push(state, task_id, seq, payload) do
    case PushConfigStore.list(A2ATransport.push_store_name(state.transport), task_id) do
      [] ->
        :ok

      configs ->
        for config <- configs do
          PushDelivery.start(state.transport, config, payload, seq, state.push)
        end

        :ok
    end
  end
end
