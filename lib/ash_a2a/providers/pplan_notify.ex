defmodule AshA2A.Providers.PPlanNotify do
  @moduledoc """
  Durable-run completion -> A2A push notification bridge.

  When a durable ash_pplan run completes on a node that never saw the
  original HTTP request, the A2A client learns nothing: push delivery rides
  the in-memory, node-local `AshA2A.A2ATransport.TaskEvents` log, which only
  fires when the response was published through *this* node's transport. This
  module closes that gap from the durable side: it watches run records in the
  durable store and, when a watched run reaches a terminal status
  (`:completed` / `:failed` / `:cancelled`), delivers the SAME wrapped v1.0
  webhook body the in-process path delivers
  (`{"task" => %{"id" => ..., "status" => %{"state" => "TASK_STATE_*"}}}`, no
  `"final"` key) to every registered push config of the task — with the same
  signature headers (`X-A2A-Notification-Token`,
  `X-A2A-Timestamp`, `X-A2A-Signature: v1=<hex hmac>`) — through the default
  deliverer, the real `AshA2A.A2ATransport.PushDelivery.deliver/5`.

  ## Observation mechanism (honest 80/20)

  ash_pplan's durable engine has NO monitor/watch/pubsub/notify surface
  (grep of `AshPPlan.Reactor.Durable.{Engine,Store,Store.Dets}`: no
  GenServer-level lifecycle observation of any kind; the store's mailbox is
  the only serialization point and `Engine.fetch/3` the only read). So the
  bridge polls `Engine.fetch/2` on a timer — the named 80/20, not a silent
  simplification.

  ## Exactly-once scope (pinned)

  Dedup is per `{task_id, config_id, record.status}` in this process's local
  state, marked ONLY on a successful (`:ok`) delivery: a failed delivery is
  retried on the next tick (at-least-once toward the receiver until success,
  exactly-once per terminal status on success). The dedup key is the terminal
  STATUS, not `record.version`: the durable record's `version` is a write
  counter in ash_pplan (bumped on every `put_run` write, including
  post-terminal bookkeeping), so keying on it re-delivered the same completed
  transition when a post-completion write advanced the version under a
  `completed` status. The dedup set lives in
  the notifier process, so it survives store restarts (re-open the store at
  the same registered name and the poll loop re-binds transparently) but NOT
  a restart of the notifier itself: a notifier started fresh against an
  already-terminal record will deliver once more — at-least-once across
  notifier restarts, never zero and never more than once per tick-success.

  ## Options (`start_link/1`)

    * `:store` (required) — durable store (pid or registered name).
    * `:store_module` — optional, forwarded to the engine as a store opt
      (same convention as `AshA2A.Providers.PPlan`).
    * `:push_store` (required) — `AshA2A.A2ATransport.PushConfigStore`
      server (pid or registered name) holding the task push configs.
    * `:transport` — transport name for the default deliverer (recorded
      attempts land in that transport's `TaskEvents`). Required unless a
      custom `:deliver` fun is given.
    * `:push_opts` — keyword passed to `PushDelivery.deliver/5`
      (`:signing_secret`, `:allow_http`, `:allow_cidrs`,
      `:max_attempts`, `:base_backoff_ms`, ...).
    * `:deliver` — deliverer fun override with the `PushDelivery.deliver/5`
      signature `(transport, config, payload, seq, push_opts) ->
      :ok | {:error, term}`.
    * `:interval` — poll interval in ms (default 1000).

  ## API

    * `watch/2` — add a task id to the watch set (idempotent).
    * `unwatch/2` — remove it.
    * `watched/1` — the current watch set.
    * `deliveries/1` — the delivery log (newest last):
      `%{task_id, config_id, seq, outcome, at}`.

  ## Configuration seam

  Like `AshA2A.Providers.PPlan`, this module is off the production DO path
  (providers are named in config, never called by the transport core); every
  ash_pplan module is held as an atom and invoked through `apply/3`, so it
  compiles and loads where ash_pplan is absent. `available?/0` is the gate;
  entry points fail closed with `{:error, {:unsupported, :ash_pplan}}`.

  ## Falsifiers

    1. A parked run plus registered push config, resumed to completion, does
       not deliver a signed wrapped body to a real receiver — or the receiver
       verifies the HMAC and it fails.
    2. A completed run delivers twice across a store restart (dedup scope
       violated).
    3. A receiver-down delivery does not record a typed
       `{:error, {:transport_error, _}}` outcome.
  """

  use GenServer

  # ash_pplan is an optional (test-only) dependency: atoms + apply/3, exactly
  # like AshA2A.Providers.PPlan, so this file loads without it.
  @engine AshPPlan.Reactor.Durable.Engine
  @status AshPPlan.Reactor.Durable.Status
  @pplan AshA2A.Providers.PPlan

  @default_interval 1_000

  @doc "Whether the ash_pplan durability backend is loaded."
  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(@engine)

  @doc false
  def child_spec(opts) do
    %{id: {__MODULE__, opts[:name] || make_ref()}, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Starts the bridge. See the moduledoc for options. Fails closed at start
  with `{:error, {:missing_opt, key}}` for a missing `:store`/`:push_store`,
  and `{:error, {:transport_required, :deliver}}` when neither `:transport`
  nor `:deliver` is given (the default deliverer needs a transport).
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    with {:ok, _} <- fetch_opt(opts, :store),
         {:ok, _} <- fetch_opt(opts, :push_store),
         :ok <-
           if(opts[:transport] || opts[:deliver], do: :ok, else: {:error, {:transport_required, :deliver}}) do
      GenServer.start_link(__MODULE__, opts, name: opts[:name])
    end
  end

  defp fetch_opt(opts, key),
    do: if(opts[key], do: {:ok, opts[key]}, else: {:error, {:missing_opt, key}})

  @doc "Adds `task_id` to the watch set (idempotent)."
  @spec watch(GenServer.server(), String.t()) :: :ok
  def watch(server, task_id), do: GenServer.call(server, {:watch, task_id})

  @doc "Removes `task_id` from the watch set."
  @spec unwatch(GenServer.server(), String.t()) :: :ok
  def unwatch(server, task_id), do: GenServer.call(server, {:unwatch, task_id})

  @doc "The current watch set."
  @spec watched(GenServer.server()) :: MapSet.t(String.t())
  def watched(server), do: GenServer.call(server, :watched)

  @doc """
  The delivery log (newest last): `%{task_id, config_id, seq, outcome, at}`.
  `outcome` is the deliverer's return: `:ok` or `{:error, term}`.
  """
  @spec deliveries(GenServer.server()) :: [map()]
  def deliveries(server), do: GenServer.call(server, :deliveries)

  # -- server -------------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      store: opts[:store],
      store_opts: Keyword.take(opts, [:store_module]),
      push_store: opts[:push_store],
      transport: opts[:transport],
      push_opts: Keyword.get(opts, :push_opts, []),
      deliver: opts[:deliver],
      interval: Keyword.get(opts, :interval, @default_interval),
      watched: MapSet.new(),
      notified: MapSet.new(),
      deliveries: []
    }

    Process.send_after(self(), :tick, state.interval)
    {:ok, state}
  end

  @impl true
  def handle_call({:watch, task_id}, _from, state),
    do: {:reply, :ok, %{state | watched: MapSet.put(state.watched, task_id)}}

  def handle_call({:unwatch, task_id}, _from, state),
    do: {:reply, :ok, %{state | watched: MapSet.delete(state.watched, task_id)}}

  def handle_call(:watched, _from, state), do: {:reply, state.watched, state}

  def handle_call(:deliveries, _from, state),
    do: {:reply, Enum.reverse(state.deliveries), state}

  @impl true
  def handle_info(:tick, %{interval: interval} = state) do
    state = poll(state)
    Process.send_after(self(), :tick, interval)
    {:noreply, state}
  end

  # One poll: for every watched task, read the durable record; on a terminal
  # status, deliver to each not-yet-notified push config of the task.
  defp poll(state) do
    Enum.reduce(state.watched, state, fn task_id, state ->
      case fetch_record(state, task_id) do
        {:ok, record} -> maybe_deliver(state, task_id, record)
        _skipped -> state
      end
    end)
  end

  # The store may be restarting (killed owner, name briefly unbound): a
  # fetch exit is an observation gap, not a crash — skip the tick.
  defp fetch_record(state, task_id) do
    try do
      case apply(@engine, :fetch, [state.store, task_id, state.store_opts]) do
        nil -> {:error, :no_such_run}
        record -> {:ok, record}
      end
    rescue
      e -> {:error, e}
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
  end

  defp maybe_deliver(state, task_id, record) do
    if apply(@status, :terminal?, [record.status]) do
      {payload, seq} = wrapped_body(task_id, record)
      configs = AshA2A.A2ATransport.PushConfigStore.list(state.push_store, task_id)
      deliver_all(state, task_id, payload, seq, record.status, configs)
    else
      state
    end
  end

  # The SAME v1.0 StreamResponse wrapper the in-process path publishes
  # (lib/ash_a2a/a2a_transport/plug.ex publish_result/4): `{"task" => ...}`
  # with the terminal wire state and no "final" boolean anywhere.
  defp wrapped_body(task_id, record) do
    state =
      case apply(@pplan, :to_state, [record.status]) do
        {:ok, state} -> state
        {:error, reason} -> raise ArgumentError, "unmapped ash_pplan run status: #{inspect(reason)}"
      end

    {%{"task" => %{"id" => task_id, "status" => %{"state" => wire_state(state)}}},
     record.version}
  end

  defp wire_state(:completed), do: "TASK_STATE_COMPLETED"
  defp wire_state(:failed), do: "TASK_STATE_FAILED"
  defp wire_state(:canceled), do: "TASK_STATE_CANCELED"

  # Exactly-once scope: dedup key {task_id, config_id, terminal status},
  # marked only on a successful delivery; failures retry next tick. The
  # record's `version` is a write counter in ash_pplan (bumped on every
  # put_run write, including post-terminal bookkeeping), NOT a terminal
  # transition identity — keying on it re-delivered completed runs.
  defp deliver_all(state, task_id, payload, seq, status, configs) do
    Enum.reduce(configs, state, fn config, state ->
      key = {task_id, config.id, status}

      if MapSet.member?(state.notified, key) do
        state
      else
        outcome = deliver(state, config, payload, seq)

        %{
          state
          | notified:
              if(outcome == :ok, do: MapSet.put(state.notified, key), else: state.notified),
            deliveries: [
              %{
                task_id: task_id,
                config_id: config.id,
                seq: seq,
                outcome: outcome,
                at: DateTime.utc_now()
              }
              | state.deliveries
            ]
        }
      end
    end)
  end

  defp deliver(%{deliver: fun} = state, config, payload, seq) when is_function(fun, 5),
    do: fun.(state.transport, config, payload, seq, state.push_opts)

  defp deliver(state, config, payload, seq),
    do:
      AshA2A.A2ATransport.PushDelivery.deliver(
        state.transport,
        config,
        payload,
        seq,
        state.push_opts
      )
  end
