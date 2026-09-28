defmodule AshA2A.A2ATransport do
  @moduledoc """
  Supervision root for the ash_a2a-owned A2A transport runtime used by
  `AshA2A.A2ATransport.Plug`.

  The vendored `:a2a` dependency hard-codes three A2A method families to typed
  refusals inside private dispatch clauses (`tasks/resubscribe` -> -32004,
  `tasks/pushNotificationConfig/*` -> -32003,
  `agent/getAuthenticatedExtendedCard` -> -32004), and its `message/stream`
  consumes each task's stream inline on the first SSE connection, so there is
  nothing a second subscriber could attach to. This subtree supplies the
  missing runtime:

    * `AshA2A.A2ATransport.TaskEvents` -- a per-task, sequence-numbered event
      log plus a duplicate-key `Registry` fan-out. Every SSE connection
      (`message/stream` or `tasks/resubscribe`) is a *subscriber*; the stream
      itself is consumed by a supervised pump process, so a client disconnect
      never truncates the task.
    * `AshA2A.A2ATransport.PushConfigStore` -- push-notification configs.
    * two bounded `Task.Supervisor`s: one for stream pumps, one for webhook
      deliveries (`AshA2A.A2ATransport.PushDelivery`).

  ## Starting

      children = [
        {AshA2A.A2ATransport,
         push: [signing_secret: System.fetch_env!("A2A_PUSH_SECRET")]}
      ]

  Several independent instances may run side by side under distinct `:name`s
  (the plug selects one with its `:transport` option).

  ## Options

    * `:name` -- instance name (atom), default `AshA2A.A2ATransport`.
    * `:max_children` -- ceiling on concurrent stream pumps (default 1024).
    * `:max_deliveries` -- ceiling on concurrent webhook deliveries (default
      256). Deliveries run under their own supervisor so slow or blackholed
      webhook receivers (which a caller chooses) can never exhaust the pump
      slots `message/stream` needs; a delivery refused for capacity is
      recorded as an attempt with outcome `{:dropped, :max_deliveries}`.
    * `:retention_ms` -- how long a finalized task's event log is kept for
      late resubscribers (default 300_000).
    * `:max_events` -- per-task event-log ceiling; oldest events are dropped
      beyond it (default 10_000).
    * `:max_per_task` -- push configs per task (default 16).
    * `:push` -- delivery options, see `AshA2A.A2ATransport.PushDelivery`.

  ## Durability

  All state is node-local and in-memory. A task started on node A cannot be
  resubscribed on node B, and nothing survives a restart. See
  `docs/reference/a2a-spec-version-mapping.md`.
  """

  use Supervisor

  @default_name __MODULE__

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, @default_name),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc "Starts a transport instance."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)
    Supervisor.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc "The default instance name."
  @spec default_name() :: atom()
  def default_name, do: @default_name

  @doc "True when the named transport instance is running."
  @spec running?(atom()) :: boolean()
  def running?(name), do: is_pid(Process.whereis(events_name(name)))

  @doc false
  def registry_name(name), do: Module.concat(name, Registry)
  @doc false
  def events_name(name), do: Module.concat(name, Events)
  @doc false
  def push_store_name(name), do: Module.concat(name, PushConfigs)
  @doc false
  def task_sup_name(name), do: Module.concat(name, Tasks)
  @doc false
  def push_sup_name(name), do: Module.concat(name, PushDeliveries)

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    children = [
      {Registry, keys: :duplicate, name: registry_name(name)},
      {Task.Supervisor,
       name: task_sup_name(name), max_children: Keyword.get(opts, :max_children, 1024)},
      {Task.Supervisor,
       name: push_sup_name(name), max_children: Keyword.get(opts, :max_deliveries, 256)},
      {AshA2A.A2ATransport.PushConfigStore,
       name: push_store_name(name), max_per_task: Keyword.get(opts, :max_per_task, 16)},
      {AshA2A.A2ATransport.TaskEvents,
       name: events_name(name),
       transport: name,
       retention_ms: Keyword.get(opts, :retention_ms, 300_000),
       max_events: Keyword.get(opts, :max_events, 10_000),
       push: Keyword.get(opts, :push, [])}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
