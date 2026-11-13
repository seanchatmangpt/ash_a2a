defmodule AshA2A.Protocol.Telemetry do
  @moduledoc """
  Telemetry events emitted by the A2A library.

  A2A uses `:telemetry` to emit events at key lifecycle points. Library
  users attach handlers in their application to observe agent behaviour
  in production.

  ## Spans

  Spans are emitted via `:telemetry.span/3` and automatically produce
  `:start`, `:stop`, and `:exception` suffixed events.

  ### `[:a2a, :agent, :call]`

  Wraps the full `AshA2A.Protocol.call/3` and `AshA2A.Protocol.stream/3` lifecycle.

  **Start measurements:** `%{system_time: integer()}`

  **Start metadata:**

      %{agent: GenServer.server(), streaming: boolean()}

  **Stop measurements:** `%{duration: integer()}`

  **Stop metadata** (adds to start):

      %{task_id: String.t(), status: atom(), context_id: String.t() | nil}

  When the agent replies `{:message, parts}` there is no task, so stop
  metadata is instead:

      %{message_id: String.t(), context_id: String.t() | nil}

  On error, stop metadata instead contains `%{error: term()}`.

  ### `[:a2a, :agent, :message]`

  Wraps the `handle_message/2` callback execution inside the agent
  GenServer.

  **Start measurements:** `%{system_time: integer()}`

  **Start metadata:**

      %{agent: module(), task_id: String.t(), context_id: String.t() | nil}

  **Stop measurements:** `%{duration: integer()}`

  **Stop metadata** (adds to start):

      %{reply_type: :reply | :message | :stream | :input_required | :error}

  A `:message` reply type means the agent answered out-of-band: the
  `task_id` in this span's metadata is the transient task the runtime built
  for the callback, which was then discarded and never persisted.

  ### `[:a2a, :agent, :cancel]`

  Wraps the `handle_cancel/1` callback execution.

  **Start measurements:** `%{system_time: integer()}`

  **Start metadata:**

      %{agent: module(), task_id: String.t(), context_id: String.t() | nil}

  **Stop measurements:** `%{duration: integer()}`

  ### `[:ash_a2a, :transport, :request]`

  Per-binding request span; `binding` metadata is `:jsonrpc | :http_json |
  :grpc`. Emitted via `request_span/3`. Failed requests additionally emit the
  discrete `[:ash_a2a, :transport, :request, :error]` event
  (`%{count: 1}`, same metadata). Feeds the `ash_a2a.transport.request.*`
  metrics in `AshA2A.Telemetry.Metrics`.

  ## Discrete Events

  ### `[:a2a, :task, :transition]`

  Emitted on every task state change.

  **Measurements:**

      %{system_time: integer()}

  **Metadata:**

      %{
        task_id: String.t(),
        context_id: String.t() | nil,
        from: atom() | nil,
        to: atom()
      }

  ### `[:a2a, :push_notification, :delivery]`

  Emitted once per registered webhook per task state change, after the
  `AshA2A.Protocol.PushNotificationSender` callback returns. Delivery is best-effort and
  runs off the agent process, so this event is the only report of whether a
  webhook was actually reached.

  **Measurements:**

      %{duration: integer()}

  **Metadata:**

      %{
        task_id: String.t(),
        context_id: String.t() | nil,
        config_id: String.t() | nil,
        url: String.t(),
        result: :ok | {:error, term()}
      }
  """

  @bindings [:jsonrpc, :http_json, :grpc]

  @doc """
  Runs `fun` inside a `[:ash_a2a, :transport, :request]` span tagged with
  `binding`. `fun` returns `{result, ok?}`; when `ok?` is `false` the error
  event is also emitted. Exceptions propagate (the span emits `:exception`).
  """
  @spec request_span(:jsonrpc | :http_json | :grpc, map(), (-> {term(), boolean()})) :: term()
  def request_span(binding, meta \\ %{}, fun) when binding in @bindings and is_function(fun, 0) do
    meta = Map.put(meta, :binding, binding)

    :telemetry.span([:ash_a2a, :transport, :request], meta, fn ->
      {result, ok?} = fun.()

      unless ok? do
        :telemetry.execute([:ash_a2a, :transport, :request, :error], %{count: 1}, meta)
      end

      {result, meta}
    end)
  end
end
