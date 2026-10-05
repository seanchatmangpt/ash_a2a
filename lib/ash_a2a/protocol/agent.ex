defmodule AshA2A.Protocol.Agent do
  @moduledoc """
  Behaviour for defining A2A agents.

  Agents are the primary abstraction in the A2A library. Each agent declares
  its identity and capabilities via `agent_card/0` and implements message
  handling via `handle_message/2`.

  ## Usage

      defmodule MyApp.GreeterAgent do
        use AshA2A.Protocol.Agent,
          name: "greeter",
          description: "Greets users",
          skills: [
            %{id: "greet", name: "Greet", description: "Says hello", tags: []}
          ]

        @impl AshA2A.Protocol.Agent
        def handle_message(message, _context) do
          text = AshA2A.Protocol.Message.text(message)
          {:reply, [AshA2A.Protocol.Part.Text.new("Hello, \#{text}!")]}
        end
      end

  The `use` macro accepts shorthand options for `agent_card/0`:

  - `:name` — agent name (required unless `agent_card/0` is defined manually)
  - `:description` — agent description (default: `""`)
  - `:version` — agent version (default: `"0.1.0"`)
  - `:skills` — list of skill maps (default: `[]`)
  - `:opts` — additional keyword options (default: `[]`)

  ## Architecture

  `use AshA2A.Protocol.Agent` generates a full GenServer. The agent author only implements
  the behaviour callbacks — the runtime manages task lifecycle, state
  transitions, history accumulation, and persistence.

  Internally, three modules collaborate:

  - **`AshA2A.Protocol.Agent`** (this module) — the behaviour definition and the `use`
    macro that generates GenServer client API and callbacks.
  - **Agent.Runtime** (internal) — pure functions for message processing.
    Creates tasks, calls `handle_message/2`, maps reply tuples to state
    transitions. Also handles task continuation (multi-turn) and stream
    wrapping.
  - **Agent.State** (internal) — the internal GenServer state struct. Holds
    the task map, context index, and optional task store reference. Provides
    helpers for task storage, retrieval, and state transitions.

  ## Task Lifecycle

  The runtime manages a task state machine so agent implementations don't
  have to. Each message creates (or continues) a task — except
  `{:message, parts}`, which answers without one — that progresses through:

      :submitted → :working → :completed
                            → :failed
                            → :input_required → (new message) → :working → ...
                            → :canceled

  The reply from `handle_message/2` determines the transition:

  - `{:reply, parts}` — creates an artifact, transitions to `:completed`
  - `{:message, parts}` — answers with a bare `AshA2A.Protocol.Message` and **no task**
    (see below)
  - `{:input_required, parts}` — transitions to `:input_required`, caller
    can continue the same task by passing `task_id:` to the next call
  - `{:stream, enumerable}` — stays `:working`, transitions to `:completed`
    when the caller fully consumes the stream
  - `{:error, reason}` — transitions to `:failed`

  ## Bare Message Replies

  `{:message, parts}` is the other half of the A2A spec's
  `SendMessageResponse` oneof: the agent answers out-of-band and no task is
  created. The task the runtime built for the turn is discarded — nothing is
  persisted, `tasks/get` will not find it, and `AshA2A.Protocol.call/3` returns
  `{:ok, %AshA2A.Protocol.Message{}}` instead of a task. On the wire the JSON-RPC result
  is `{"message": …}` rather than `{"task": …}`.

  The message inherits the request's `context_id` and carries no `task_id`,
  since there is no task for it to reference.

  Prefer it over `{:reply, parts}` for answers with nothing to track — a
  lookup, an acknowledgement, a rejected request. Anything a caller might
  later poll, cancel, or continue needs a task.

  Returning it while continuing an existing task is rejected with
  `{:error, :message_on_task}` (`-32006` on the wire): the caller is holding a
  task id, so a bare Message would strand that task and drop the turn from its
  history.

  ## Reply Parts and Status

  The parts returned from `handle_message/2` serve double duty: they are
  appended to the task's `history` (as an agent message) **and**, for
  `{:input_required, parts}`, set as the task's `status.message`.

  These two fields have different audiences:

  - **`history`** — the full conversation transcript, used by agent logic
    for context on subsequent turns.
  - **`status.message`** — a short prompt surfaced to the client UI,
    explaining why the task is paused and what input is needed.

  Because both are populated from the same parts, keep
  `{:input_required, parts}` **concise and actionable**:

      # Good — short prompt that works as both history entry and status
      {:input_required, [Part.Text.new("What size pizza?")]}

      # Avoid — long explanation duplicated into status.message
      {:input_required, [Part.Text.new("Here's our full menu... What size?")]}

  For `{:reply, parts}` and `{:stream, enumerable}`, the parts only go
  into `history` and `artifacts` — `status.message` is left empty.
  `{:message, parts}` populates neither, since it produces no task.

  ## Multi-Turn Conversations

  When an agent returns `{:input_required, parts}`, the task pauses. The
  caller continues it by passing `task_id:` with the next message:

      {:ok, task} = AshA2A.Protocol.call(agent, "order pizza")
      # task.status.state == :input_required
      {:ok, task} = AshA2A.Protocol.call(agent, "large", task_id: task.id)
      # task.status.state may be :completed or :input_required again

  The runtime appends each message to the task's history, so the agent
  receives the full conversation in `context.history`.

  ## Streaming

  When an agent returns `{:stream, enumerable}`, the runtime wraps the
  stream so that consuming it automatically finalizes the task:

      {:ok, task, stream} = AshA2A.Protocol.stream(agent, "count to 5")
      Enum.each(stream, &IO.inspect/1)
      # task is now :completed with an artifact containing all streamed parts

  ## Persistence

  By default, tasks live in the GenServer's process state (in-memory map).
  For external persistence, pass a task store at startup:

      MyAgent.start_link(task_store: {AshA2A.Protocol.TaskStore.ETS, :my_table})

  The runtime writes every task update to both the internal map and the
  external store. See `AshA2A.Protocol.TaskStore` for the behaviour interface.

  ## Starting an Agent

      {:ok, pid} = MyAgent.start_link()
      {:ok, task} = AshA2A.Protocol.call(MyAgent, "hello")

  Or with options:

      MyAgent.start_link(name: :my_agent, task_store: {AshA2A.Protocol.TaskStore.ETS, :tasks})
  """

  @type card :: %{
          name: String.t(),
          description: String.t(),
          version: String.t(),
          skills: [skill()],
          opts: keyword()
        }

  @type skill :: %{
          id: String.t(),
          name: String.t(),
          description: String.t(),
          tags: [String.t()]
        }

  @type context :: %{
          task_id: String.t(),
          context_id: String.t() | nil,
          history: [AshA2A.Protocol.Message.t()],
          metadata: map(),
          extensions: %{optional(String.t()) => AshA2A.Protocol.Extension.activation()}
        }

  @type reply ::
          {:reply, [AshA2A.Protocol.Part.t()]}
          | {:message, [AshA2A.Protocol.Part.t()]}
          | {:stream, Enumerable.t()}
          | {:input_required, [AshA2A.Protocol.Part.t()]}
          | {:error, term()}

  @doc """
  Returns the agent's identity and capabilities.
  """
  @callback agent_card() :: card()

  @doc """
  Handles an incoming message. This is the core agent logic.
  """
  @callback handle_message(AshA2A.Protocol.Message.t(), context()) :: reply()

  @doc """
  Called when a task is canceled by the caller. Optional.
  """
  @callback handle_cancel(context()) :: :ok | {:error, String.t()}

  @doc false
  defmacro __using__(opts) do
    card_ast = build_card_ast(opts)

    quote location: :keep do
      use GenServer

      @behaviour AshA2A.Protocol.Agent

      # Per-agent in-flight table for default-path task workers, held in the
      # agent process dictionary under the same scheme
      # `AshA2A.Transport.Runtime` uses for its own workers.
      @task_workers_key :ash_a2a_protocol_task_workers

      unquote(card_ast)

      @impl AshA2A.Protocol.Agent
      def handle_cancel(_context), do: :ok

      defoverridable handle_cancel: 1

      # --- GenServer client API ---

      @doc """
      Starts the agent process.

      ## Options

      - `:name` — process registration name (default: module name)
      - `:task_store` — `{module, opts}` tuple for external task persistence
      - `:push_sender` — `{module, opts}` implementing
        `AshA2A.Protocol.PushNotificationSender`, used to POST task updates to registered
        webhooks. Defaults to `AshA2A.Protocol.PushNotificationSender.HTTP` when `:req`
        is available; pass `nil` to disable delivery.
      """
      @spec start_link(keyword()) :: GenServer.on_start()
      def start_link(opts \\ []) do
        {name, opts} = Keyword.pop(opts, :name, __MODULE__)
        GenServer.start_link(__MODULE__, opts, name: name)
      end

      @doc """
      Sends a message to the agent and returns the resulting task.

      ## Options

      - `:timeout` — GenServer call timeout in ms (default: `60_000`)
      """
      @spec call(GenServer.server(), AshA2A.Protocol.Message.t(), keyword()) ::
              {:ok, AshA2A.Protocol.Task.t() | AshA2A.Protocol.Message.t()} | {:error, term()}
      def call(server \\ __MODULE__, message, opts \\ []) do
        {timeout, opts} = Keyword.pop(opts, :timeout, 60_000)
        GenServer.call(server, {:message, message, opts}, timeout)
      end

      @doc """
      Cancels a running task.

      Idempotent per A2A v1.0 §3.3.1: canceling an already-canceled task
      returns `:ok` (the same effect as the first cancel); canceling a task
      in another terminal state returns `{:error, :not_cancelable}`.

      ## Options

      - `:timeout` — GenServer call timeout in ms (default: `60_000`)
      """
      @spec cancel(GenServer.server(), String.t(), keyword()) ::
              :ok | {:error, term()}
      def cancel(server \\ __MODULE__, task_id, opts \\ []) do
        {timeout, _opts} = Keyword.pop(opts, :timeout, 60_000)
        GenServer.call(server, {:cancel, task_id}, timeout)
      end

      @doc """
      Retrieves a task by ID.

      ## Options

      - `:timeout` — GenServer call timeout in ms (default: `5_000`)
      """
      @spec get_task(GenServer.server(), String.t(), keyword()) ::
              {:ok, AshA2A.Protocol.Task.t()} | {:error, :not_found}
      def get_task(server \\ __MODULE__, task_id, opts \\ []) do
        {timeout, _opts} = Keyword.pop(opts, :timeout, 5_000)
        GenServer.call(server, {:get_task, task_id}, timeout)
      end

      # --- GenServer callbacks ---

      @impl GenServer
      def init(opts) do
        task_store = Keyword.get(opts, :task_store)
        push_sender = Keyword.get(opts, :push_sender, AshA2A.Protocol.PushNotification.default_sender())

        {:ok,
         %AshA2A.Protocol.Agent.State{
           module: __MODULE__,
           task_store: task_store,
           push_sender: push_sender
         }}
      end

      # SEC-02/SEC-08: the handler never runs in this process. The default
      # path offloads `Runtime.process_message/6` / `Runtime.continue_task/5`
      # — the same task-lifecycle entry points as before — to a monitored
      # worker, so a raise/kill in `handle_message/2` kills only the worker:
      # its DOWN is converted to a typed, redacted internal error
      # (`AshA2A.Transport.SafeError`) and this GenServer keeps serving every
      # other caller. The success path replays exactly the reply contract this
      # clause always had.
      @impl GenServer
      def handle_call({:message, message, opts}, from, state) do
        task_id = Keyword.get(opts, :task_id)
        context_id = Keyword.get(opts, :context_id)
        metadata = Keyword.get(opts, :metadata, %{})
        extensions = Keyword.get(opts, :extensions, %{})

        if task_id do
          case AshA2A.Protocol.Agent.State.get_task(state, task_id) do
            {:ok, task} ->
              spawn_task_worker({:continue, message, task, extensions}, from, task.id, state)

            {:error, :not_found} ->
              {:reply, {:error, :not_found}, state}
          end
        else
          spawn_task_worker({:new, message, context_id, metadata, extensions}, from, nil, state)
        end
      end

      def handle_call({:cancel, task_id}, _from, state) do
        case AshA2A.Protocol.Agent.State.get_task(state, task_id) do
          {:ok, task} ->
            cond do
              # A2A v1.0 §3.3.1: cancel is idempotent — a repeated cancel of
              # an already-canceled task has the same effect as the first one
              # (success, reporting the canceled task). The cancel hook does
              # not run a second time, no push notification re-fires, and the
              # stored terminal task is returned as-is.
              task.status.state == :canceled ->
                {:reply, :ok, state}

              # Other terminal states are genuinely not cancelable.
              task.status.state in [:completed, :failed, :rejected] ->
                {:reply, {:error, :not_cancelable}, state}

              true ->
                cancel_active_task(task, state)
            end

          {:error, :not_found} ->
            {:reply, {:error, :not_found}, state}
        end
      end

      defp cancel_active_task(task, state) do
        context = %{
          task_id: task.id,
          context_id: task.context_id,
          history: task.history,
          metadata: task.metadata,
          extensions: %{}
        }

        span_meta = %{
          agent: __MODULE__,
          task_id: task.id,
          context_id: task.context_id
        }

        result =
          :telemetry.span([:a2a, :agent, :cancel], span_meta, fn ->
            {AshA2A.Protocol.Agent.Runtime.run_cancel(__MODULE__, context), span_meta}
          end)

        case result do
          :ok ->
            task = AshA2A.Protocol.Agent.State.transition(task, :canceled)
            state = AshA2A.Protocol.Agent.State.put_task(state, task)
            AshA2A.Protocol.PushNotification.deliver(state, task)
            state = notify_subscribers(state, task)
            {:reply, :ok, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
      end

      def handle_call({:get_task, task_id}, _from, state) do
        {:reply, AshA2A.Protocol.Agent.State.get_task(state, task_id), state}
      end

      def handle_call({:list_tasks, params}, _from, state) do
        {:reply, AshA2A.Protocol.Agent.State.list_tasks(state, params), state}
      end

      def handle_call(:get_agent_card, _from, state) do
        {:reply, __MODULE__.agent_card(), state}
      end

      def handle_call({:set_push_config, config}, _from, state) do
        {state, result} = AshA2A.Protocol.Agent.State.put_push_config(state, config)
        {:reply, result, state}
      end

      def handle_call({:get_push_config, task_id, config_id}, _from, state) do
        {:reply, AshA2A.Protocol.Agent.State.get_push_config(state, task_id, config_id), state}
      end

      def handle_call({:list_push_configs, task_id}, _from, state) do
        {:reply, AshA2A.Protocol.Agent.State.list_push_configs(state, task_id), state}
      end

      def handle_call({:delete_push_config, task_id, config_id}, _from, state) do
        {state, result} = AshA2A.Protocol.Agent.State.delete_push_config(state, task_id, config_id)
        {:reply, result, state}
      end

      def handle_call({:subscribe, task_id}, {pid, _tag}, state) do
        case AshA2A.Protocol.Agent.State.get_task(state, task_id) do
          {:ok, task} ->
            if AshA2A.Protocol.Task.terminal?(task) do
              {:reply, {:error, :terminal}, state}
            else
              # Never hand back metadata[:stream]: enumerating it replays the
              # agent's output from the start and casts a second
              # {:stream_done, …}, duplicating artifacts and history. A
              # subscriber receives pushed events instead.
              snapshot = AshA2A.Protocol.Task.strip_stream_metadata(task)
              {:reply, {:ok, snapshot}, AshA2A.Protocol.Agent.State.add_subscriber(state, task_id, pid)}
            end

          {:error, :not_found} ->
            {:reply, {:error, :not_found}, state}
        end
      end

      # SEC-01 wrapper probe (A2ATransport.Plug `tasks/list`): the
      # owner-scoped `{:ash_a2a_list_tasks, principal, params}` message has
      # no specific clause on the vendored surface. Without a fallback the
      # FunctionClauseError kills this process on every probe; restart churn
      # then leaves the agent permanently dead mid-suite ("no process" on
      # every later request). Answer typed instead of dying — the transport
      # maps `{:error, :unsupported}` to -32004 UNSUPPORTED_OPERATION, the
      # same wire answer its `catch :exit` backstop produces, with zero
      # collateral on this process.
      def handle_call({:ash_a2a_list_tasks, _principal, _params}, _from, state) do
        {:reply, {:error, :unsupported}, state}
      end

      # A worker's DOWN is the failure half of the isolation contract: reply
      # to the pending caller and fail the task without ever exposing the
      # worker's exit reason (`_reason` is only ever logged server-side, under
      # a fresh opaque ref, by `SafeError.internal/3`).
      @impl GenServer
      def handle_info({:DOWN, mref, :process, _pid, reason}, state) do
        case Enum.find(task_workers(), fn {_token, {ref, _from, _id}} -> ref == mref end) do
          {token, {_mref, from, task_id}} ->
            {_entry, rest} = Map.pop(task_workers(), token)
            Process.put(@task_workers_key, rest)
            {:noreply, fail_worker_task(task_id, from, reason, state)}

          # Not a task worker — a monitored subscriber (SSE connection)
          # went away; registration goes with it.
          nil ->
            {:noreply, AshA2A.Protocol.Agent.State.drop_subscriber(state, mref)}
        end
      end

      def handle_info({:ash_a2a_protocol_task_done, token, result}, state) do
        case Map.pop(task_workers(), token) do
          {{mref, from, task_id}, rest} ->
            Process.demonitor(mref, [:flush])
            Process.put(@task_workers_key, rest)
            {:noreply, apply_default_result(task_id, from, result, state)}

          {nil, _rest} ->
            {:noreply, state}
        end
      end

      # Mirrors `AshA2A.Transport.Runtime.spawn_worker/4`: a monitored worker
      # rooted at this agent via `$callers`, a fresh token routing the result
      # back, and a per-agent in-flight table in the process dictionary.
      defp spawn_task_worker(job, from, task_id, state) do
        parent = self()
        callers = [parent | Process.get(:"$callers", [])]
        token = make_ref()

        {_pid, mref} =
          spawn_monitor(fn ->
            Process.put(:"$callers", callers)
            send(parent, {:ash_a2a_protocol_task_done, token, run_default_task(job)})
          end)

        Process.put(@task_workers_key, Map.put(task_workers(), token, {mref, from, task_id}))
        {:noreply, state}
      end

      # Runs entirely in the worker. Both Runtime entry points touch `state`
      # only through pure struct functions (`State.transition/3`,
      # `State.track_context/2`), so the worker runs against a minimal fresh
      # struct — the worker never sees the live state — and the resulting
      # task/message is folded into the server's CURRENT state afterwards.
      defp run_default_task({:new, message, context_id, metadata, extensions}) do
        {:ok,
         AshA2A.Protocol.Agent.Runtime.process_message(
           __MODULE__,
           message,
           context_id,
           %AshA2A.Protocol.Agent.State{module: __MODULE__},
           metadata,
           extensions
         )}
      end

      defp run_default_task({:continue, message, task, extensions}) do
        AshA2A.Protocol.Agent.Runtime.continue_task(
          __MODULE__,
          message,
          task,
          %AshA2A.Protocol.Agent.State{module: __MODULE__},
          extensions
        )
      end

      # Success half of the contract — the same case split the inline path
      # always performed, but applied against the CURRENT state (the worker
      # computed `task` against a snapshot, and updates that landed while the
      # handler ran must not be clobbered by it).
      defp apply_default_result(_task_id, from, result, state) do
        case result do
          {:ok, {%AshA2A.Protocol.Message{} = agent_message, _snapshot}} ->
            GenServer.reply(from, {:ok, agent_message})
            state

          {:ok, {%AshA2A.Protocol.Task{} = task, _snapshot}} ->
            task = maybe_wrap_stream(task, from)

            state =
              state
              |> AshA2A.Protocol.Agent.State.put_task(task)
              |> AshA2A.Protocol.Agent.State.track_context(task)

            AshA2A.Protocol.PushNotification.deliver(state, task)
            state = notify_subscribers(state, task)
            GenServer.reply(from, {:ok, task})
            state

          {:error, reason} ->
            GenServer.reply(from, {:error, reason})
            state
        end
      end

      # Crash half. A continued task exists in this state, so it fails exactly
      # the way `AshA2A.Transport.Runtime.apply_reply({:error, reason}, task)`
      # fails one: `:failed` with a redacted status message, push delivered,
      # subscribers notified, caller answered `{:ok, failed_task}`. A crashed
      # new task was never observable (the default path persists a task only
      # after the handler returns), so there is no task id to hand back — the
      # caller gets the typed internal_error map, code + opaque ref only.
      defp fail_worker_task(task_id, from, reason, state) do
        error = AshA2A.Transport.SafeError.internal(:internal_error, {:worker_exit, reason})

        case task_id && AshA2A.Protocol.Agent.State.get_task(state, task_id) do
          {:ok, task} ->
            if AshA2A.Protocol.Task.terminal?(task) do
              # Defensive, mirrors `AshA2A.Transport.Runtime.finish/5`: a task
              # finalized by another path is never overwritten.
              GenServer.reply(from, {:ok, task})
              state
            else
              error_msg =
                AshA2A.Protocol.Message.new_agent(
                  "Error: #{inspect(AshA2A.Transport.SafeError.redact(error))}"
                )

              task = AshA2A.Protocol.Agent.State.transition(task, :failed, error_msg)
              state = AshA2A.Protocol.Agent.State.put_task(state, task)
              AshA2A.Protocol.PushNotification.deliver(state, task)
              state = notify_subscribers(state, task)
              GenServer.reply(from, {:ok, task})
              state
            end

          _no_task ->
            GenServer.reply(from, {:error, error})
            state
        end
      end

      defp task_workers, do: Process.get(@task_workers_key, %{})

      @impl GenServer
      def handle_cast({:deliver_push, task_id}, state) do
        case AshA2A.Protocol.Agent.State.get_task(state, task_id) do
          {:ok, task} -> AshA2A.Protocol.PushNotification.deliver(state, task)
          {:error, :not_found} -> :ok
        end

        {:noreply, state}
      end

      def handle_cast({:stream_done, task_id, artifact_id, parts, outcome}, state) do
        case AshA2A.Protocol.Agent.State.get_task(state, task_id) do
          {:ok, task} ->
            artifact =
              case artifact_id do
                nil -> AshA2A.Protocol.Artifact.new(parts)
                id -> struct(AshA2A.Protocol.Artifact, artifact_id: id, parts: parts)
              end
            agent_msg = AshA2A.Protocol.Message.new_agent(parts)
            task = %{task | artifacts: task.artifacts ++ [artifact]}
            task = %{task | history: task.history ++ [agent_msg]}
            task = %{task | metadata: Map.delete(task.metadata, :stream)}

            # A stream that raised or was abandoned did not produce the result
            # it promised. The parts it managed to emit are kept — they are
            # still the agent's output — but the state says so rather than
            # reporting success to `tasks/get`, webhooks and subscribers alike.
            final_state = if outcome == :complete, do: :completed, else: :failed

            task = AshA2A.Protocol.Agent.State.transition(task, final_state)
            state = AshA2A.Protocol.Agent.State.put_task(state, task)
            AshA2A.Protocol.PushNotification.deliver(state, task)
            state = notify_subscribers(state, task)
            {:noreply, state}

          {:error, :not_found} ->
            {:noreply, state}
        end
      end

      defp notify_subscribers(state, task) do
        snapshot = AshA2A.Protocol.Task.strip_stream_metadata(task)

        for pid <- AshA2A.Protocol.Agent.State.subscribers_for(state, task.id) do
          send(pid, {:a2a_task_event, task.id, snapshot})
        end

        # A terminal task ends every stream attached to it, so the
        # registrations go with it rather than lingering until each
        # connection happens to close.
        if AshA2A.Protocol.Task.terminal?(task) do
          AshA2A.Protocol.Agent.State.drop_subscribers(state, task.id)
        else
          state
        end
      end

      defp maybe_wrap_stream(%{metadata: %{stream: enum}} = task, {pid, _ref}) do
        # One stable artifact id per stream, shared by the SSE chunk emitter
        # and the stream_done fold (v1.0 chunk reassembly keys on artifactId).
        artifact_id = AshA2A.Protocol.ID.generate("art")
        task = put_in(task.metadata[:stream_artifact_id], artifact_id)
        wrapped = AshA2A.Protocol.Agent.Runtime.wrap_stream(enum, self(), task.id, artifact_id)
        %{task | metadata: Map.put(task.metadata, :stream, wrapped)}
      end

      defp maybe_wrap_stream(task, _from), do: task
    end
  end

  defp build_card_ast(opts) do
    if Keyword.has_key?(opts, :name) do
      name = Keyword.fetch!(opts, :name)
      description = Keyword.get(opts, :description, "")
      version = Keyword.get(opts, :version, "0.1.0")
      skills = Keyword.get(opts, :skills, [])
      extra_opts = Keyword.get(opts, :opts, [])

      # Card fields beyond the base five (capabilities, supported_interfaces,
      # ...) may arrive as either literal values or escaped-AST fragments from
      # the `use` site; both are valid quote fragments, so build the extras as
      # a map-literal fragment directly.
      extra_keys = [
        :capabilities,
        :default_input_modes,
        :default_output_modes,
        :supported_interfaces,
        :security_schemes,
        :security,
        :signatures
      ]

      extras_fragment = {:%{}, [], Keyword.take(opts, extra_keys)}

      quote do
        @impl AshA2A.Protocol.Agent
        def agent_card do
          Map.merge(
            %{
              name: unquote(name),
              description: unquote(description),
              version: unquote(version),
              skills: unquote(skills),
              opts: unquote(extra_opts)
            },
            unquote(extras_fragment)
          )
        end

        defoverridable agent_card: 0
      end
    else
      quote do
      end
    end
  end
end
