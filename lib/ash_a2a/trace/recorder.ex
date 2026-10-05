# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Trace.Recorder do
  @moduledoc """
  Real `:telemetry` recorder backing `AshA2A.Trace.export/3`.

  It attaches to telemetry a task saga already emits -- the transport runtime's
  `[:a2a, :agent, :message]` span, the dispatcher's `[:ash_a2a, :dispatch]`
  span, the command bus's `[:ash_a2a, :command_bus, ...]` boundary events, the
  authority gate's `[:ash_a2a, :authority, :decision]`, and `[:ash_a2a,
  :receipt, :committed/:outboxed]` -- and stores one ordered record per event,
  keyed by the task the saga belongs to. Recording is observational only: it
  never changes dispatch behavior.

  ## Task correlation

  A saga is correlated to its task by execution process: the transport runtime
  runs the whole handler chain (message span -> dispatch -> CommandBus ->
  authority -> receipt) synchronously inside one worker process, so the
  `[:a2a, :agent, :message, :start]` event binds that process to `task_id`
  until the matching `:stop`/`:exception`. Telemetry fired with no bound task
  (direct `AshA2A.Dispatcher.dispatch/6` unit calls, non-A2A command-bus
  callers) is not recorded: the trace export is task-scoped by definition.

  ## Span model

  The recorder stores raw records; `AshA2A.Trace.export/3` folds them into the
  exported span tree:

      a2a.task      (root; the runtime's per-task message span)
      └── a2a.dispatch   (child; the dispatcher's per-dispatch span; span
                          events carry the authority and command-bus
                          boundaries plus the committed receipt)
          └── a2a.actuation   (grandchild; the command bus's actuate
                               start/stop span pair, when the saga actuated)

  Every handler is wrapped: an observability bug must never raise into the
  dispatching process (`:telemetry` handlers run synchronously in the emitter).
  """

  use GenServer

  alias AshA2A.Telemetry.Redact

  @name __MODULE__
  # Process-dictionary keys on the saga's worker process.
  @stack_key :ash_a2a_trace_stack
  @task_binding_key :ash_a2a_trace_task
  @dispatch_n_key :ash_a2a_trace_dispatch_n
  @actuation_n_key :ash_a2a_trace_actuation_n

  @type task_id :: String.t()
  @type span_key :: String.t()

  @typedoc """
  One raw recorder record.

    * `{:open, key, name, parent_key, start_mono, start_sys, attrs}`
    * `{:close, key, end_mono, end_sys, extra_attrs, status}`
    * `{:event, key, name, mono, sys, attrs}`

  `key` is the span key (`"task"`, `"dispatch:1"`, `"actuation:1"`, ...);
  `mono` is a `System.monotonic_time/0` value and `sys` a
  `System.system_time/0` value, both captured when the telemetry event fired.
  """
  @type record ::
          {:open, span_key(), String.t(), span_key() | nil, integer(), integer(), map()}
          | {:close, span_key(), integer(), integer(), map(), :ok | :error}
          | {:event, span_key(), String.t(), integer(), integer(), map()}

  # Instantaneous saga boundaries, recorded as span events on the innermost
  # open `a2a.dispatch` span (or the task root when no dispatch span is open).
  @boundary_events [
    [:ash_a2a, :command_bus, :target],
    [:ash_a2a, :command_bus, :preflight],
    [:ash_a2a, :command_bus, :admission],
    [:ash_a2a, :command_bus, :work_order],
    [:ash_a2a, :command_bus, :pre_do_gate],
    [:ash_a2a, :command_bus, :kill_switch],
    [:ash_a2a, :command_bus, :lease_gate],
    [:ash_a2a, :command_bus, :claim],
    [:ash_a2a, :command_bus, :prepare],
    [:ash_a2a, :command_bus, :postcondition],
    [:ash_a2a, :command_bus, :commit],
    [:ash_a2a, :command_bus, :actuation_commit],
    [:ash_a2a, :authority, :decision]
  ]

  @doc """
  Lazily starts the recorder GenServer (which owns the record table and
  attaches the telemetry handlers). Idempotent; safe from any process.
  """
  @spec ensure() :: :ok
  def ensure do
    if is_nil(GenServer.whereis(@name)) do
      case GenServer.start(@name, :ok, name: @name) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, _other} -> :ok
        :ignore -> :ok
      end
    else
      :ok
    end
  end

  @doc "The recorded records of `task_id`, ordered by record sequence."
  @spec records(task_id()) :: [{non_neg_integer(), record()}]
  def records(task_id) do
    case :ets.info(table()) do
      :undefined ->
        []

      _ ->
        :ets.select(table(), [
          {{{task_id, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}
        ])
        |> Enum.sort()
    end
  end

  @doc "Forgets `task_id`'s records (retention sweeps and tests)."
  @spec forget(task_id()) :: :ok
  def forget(task_id) do
    if :ets.info(table()) != :undefined do
      :ets.match_delete(table(), {{task_id, :_}, :_})
    end

    :ok
  end

  @doc false
  def table, do: @name

  # -- GenServer -----------------------------------------------------------------

  @impl true
  def init(:ok) do
    :ets.new(table(), [:ordered_set, :public, :named_table, read_concurrency: true])

    for event <- span_events() ++ boundary_events() ++ actuate_events() ++ receipt_events() do
      attach(event)
    end

    {:ok, %{}}
  end

  # The recorder has no runtime logic beyond owning the table; telemetry is
  # handled synchronously in the emitting process by handle_event/4 below.
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp attach(event) do
    handler_id = {@name, event}

    case :telemetry.attach(handler_id, event, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  defp span_events do
    for prefix <- [[:a2a, :agent, :message], [:ash_a2a, :dispatch]],
        suffix <- [:start, :stop, :exception] do
      prefix ++ [suffix]
    end
  end

  defp boundary_events, do: @boundary_events

  defp actuate_events,
    do: [[:ash_a2a, :command_bus, :actuate, :start], [:ash_a2a, :command_bus, :actuate, :stop]]

  defp receipt_events,
    do: [[:ash_a2a, :receipt, :committed], [:ash_a2a, :receipt, :outboxed]]

  # -- telemetry handlers --------------------------------------------------------
  # Handlers run in the emitting (worker) process. `safe/1` keeps any
  # observability bug from reaching the dispatch that emitted the event.

  @doc false
  def handle_event([:a2a, :agent, :message, :start], _m, meta, _c) do
    safe(fn ->
      case meta[:task_id] do
        nil ->
          :ok

        task_id when is_binary(task_id) ->
          stack = Process.get(@stack_key, [])

          if stack == [] do
            reopened = task_span_recorded?(task_id)
            Process.put(@task_binding_key, task_id)
            push(task_id, entry("task", reopened, %{}))

            unless reopened do
              write_open(task_id, "task", "a2a.task", nil, %{
                "a2a.agent" => agent_label(meta[:agent]),
                "a2a.context_id" => text(meta[:context_id])
              })
            end
          end
      end
    end)
  end

  def handle_event([:a2a, :agent, :message, suffix], _m, meta, _c) when suffix in [:stop, :exception] do
    safe(fn ->
      case pop() do
        %{key: "task", task_id: task_id, reopened: false} = _top ->
          write_close(task_id, "task", status(suffix), %{
            "a2a.reply_type" => text(meta[:reply_type])
          })

        _open_or_absent ->
          :ok
      end
    end)
  end

  @doc false
  def handle_event([:ash_a2a, :dispatch, :start], _m, meta, _c) do
    safe(fn ->
      if task_id = bound_task() do
        n = Process.get(@dispatch_n_key, 0) + 1
        Process.put(@dispatch_n_key, n)
        key = "dispatch:#{n}"
        parent = innermost_span_key()
        push(task_id, entry(key, false, dispatch_attrs(meta)))
        write_open(task_id, key, "a2a.dispatch", parent, dispatch_attrs(meta))
      end
    end)
  end

  def handle_event([:ash_a2a, :dispatch, suffix], _m, meta, _c) when suffix in [:stop, :exception] do
    safe(fn ->
      case pop() do
        %{key: "dispatch:" <> _n = key, task_id: task_id} ->
          attrs =
            dispatch_attrs(meta)
            |> Map.merge(close_attrs(suffix, meta))

          write_close(task_id, key, status(suffix), attrs)

        _ ->
          :ok
      end
    end)
  end

  def handle_event(event, measurements, metadata, _config) when event in @boundary_events do
    safe(fn ->
      if task_id = bound_task() do
        write_event(
          task_id,
          innermost_span_key(),
          event_name(event),
          boundary_attrs(event, measurements, metadata)
        )
      end
    end)
  end

  # The command bus's actuate start/stop pair is the saga's actuation stage:
  # a real span nested inside the open dispatch span.
  def handle_event([:ash_a2a, :command_bus, :actuate, :start], _m, meta, _c) do
    safe(fn ->
      with task_id when is_binary(task_id) <- bound_task(),
           key when is_binary(key) <- innermost_span_key() do
        n = Process.get(@actuation_n_key, 0) + 1
        Process.put(@actuation_n_key, n)
        span_key = "actuation:#{n}"
        push(task_id, entry(span_key, false, nil))

        write_open(task_id, span_key, "a2a.actuation", key, %{
          "command_bus.command_id" => text(meta[:command_id]),
          "command_bus.capability_id" => text(meta[:capability_id]),
          "command_bus.execution_id" => text(meta[:execution_id])
        })
      end
    end)
  end

  def handle_event([:ash_a2a, :command_bus, :actuate, :stop], _m, meta, _c) do
    safe(fn ->
      case pop() do
        %{key: "actuation:" <> _n = key, task_id: task_id} ->
          write_close(task_id, key, status(:stop), %{
            "command_bus.outcome" => text(meta[:outcome]),
            "command_bus.receipt_id" => text(meta[:receipt_id])
          })

        _ ->
          :ok
      end
    end)
  end

  def handle_event([:ash_a2a, :receipt, kind], _m, %{receipt: %AshA2A.Receipt{} = receipt}, _c)
      when kind in [:committed, :outboxed] do
    safe(fn ->
      if task_id = bound_task() do
        write_event(task_id, innermost_span_key(), "receipt.#{kind}", %{
          "receipt.command_id" => identity_text(receipt.command_id),
          "receipt.capability_id" => text(receipt.capability_id),
          "receipt.principal_id" => identity_text(receipt.principal_id),
          "receipt.status" => text(receipt.status),
          "receipt.terminal_status" => text(receipt.terminal_status)
        })
      end
    end)
  end

  def handle_event(_event, _m, _meta, _c), do: :ok

  # -- process-dictionary span stack -----------------------------------------------

  defp entry(key, reopened, _attrs) do
    %{
      key: key,
      task_id: bound_task(),
      reopened: reopened
    }
  end

  defp push(_task_id, entry), do: Process.put(@stack_key, [entry | Process.get(@stack_key, [])])

  defp pop do
    case Process.get(@stack_key, []) do
      [top | rest] ->
        Process.put(@stack_key, rest)
        top

      [] ->
        nil
    end
  end

  defp bound_task, do: Process.get(@task_binding_key)

  # The innermost open span key ("task", "actuation:<n>", "dispatch:<n>").
  defp innermost_span_key do
    case Process.get(@stack_key, []) do
      [%{key: key} | _] -> key
      [] -> nil
    end
  end

  defp task_span_recorded?(task_id) do
    Enum.any?(records(task_id), fn
      {_seq, {:open, "task", _, _, _, _, _}} -> true
      _ -> false
    end)
  end

  # -- record writes ----------------------------------------------------------------

  defp write_open(task_id, key, name, parent_key, attrs) do
    insert(task_id, {:open, key, name, parent_key, System.monotonic_time(), System.system_time(), attrs})
  end

  defp write_close(task_id, key, status, extra_attrs)

  defp write_close(nil, _key, _status, _extra_attrs), do: :ok

  defp write_close(task_id, key, status, extra_attrs) when is_binary(task_id) do
    insert(task_id, {:close, key, System.monotonic_time(), System.system_time(), extra_attrs, status})
  end

  defp write_event(task_id, key, name, attrs) do
    if is_binary(task_id) do
      insert(
        task_id,
        {:event, key, name, System.monotonic_time(), System.system_time(), attrs}
      )
    end

    :ok
  end

  defp insert(task_id, record) do
    try do
      if :ets.info(table()) != :undefined do
        seq = :ets.update_counter(table(), {task_id, 0}, 1, {task_id, 0, nil})
        :ets.insert(table(), {{task_id, seq}, record})
      end
    rescue
      _ -> :ok
    end

    :ok
  end

  # -- attribute mapping --------------------------------------------------------------

  defp close_attrs(:stop, meta), do: %{"a2a.reply_type" => text(meta[:reply_type])}

  defp close_attrs(:exception, meta) do
    %{
      "a2a.error.kind" => text(meta[:kind]),
      "a2a.error.code" => error_code(meta[:reason])
    }
  end

  defp error_code(%{kind: :exception, exception: module}) when is_atom(module),
    do: "exception:" <> inspect(module)

  defp error_code(reason), do: text(reason && Redact.error_summary(reason).kind)

  defp dispatch_attrs(meta) do
    %{
      "a2a.skill" => text(meta[:skill_name]),
      "a2a.resource" => resource_label(meta[:resource_or_domain]),
      "a2a.command_id" => text(meta[:command_id]),
      "a2a.traceparent" => text(meta[:traceparent])
    }
  end

  defp boundary_attrs(event, measurements, metadata) do
    base = %{
      "boundary.outcome" => text(metadata[:outcome]),
      "boundary.code" => text(metadata[:code]),
      "boundary.command_id" => text(metadata[:command_id]),
      "boundary.capability_id" => text(metadata[:capability_id]),
      "boundary.principal_id" => text(metadata[:principal_id])
    }

    base =
      base
      |> maybe_put("boundary.receipt_id", text(metadata[:receipt_id]))
      |> maybe_put("boundary.execution_id", text(metadata[:execution_id]))
      |> maybe_put("boundary.duration_native", int(measurements[:duration]))

    if event == [:ash_a2a, :authority, :decision] do
      base
      |> Map.drop(["boundary.outcome", "boundary.code"])
      |> Map.merge(%{
        "authority.outcome" => text(metadata[:outcome]),
        "authority.reason" => text(metadata[:reason]),
        "authority.token_id" => text(metadata[:token_id])
      })
    else
      base
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp event_name([:ash_a2a, :command_bus, suffix]) when is_atom(suffix),
    do: "command_bus.#{suffix}"

  defp event_name([:ash_a2a, :command_bus, a, b]) when is_atom(a) and is_atom(b),
    do: "command_bus.#{a}.#{b}"

  defp event_name([:ash_a2a, :authority, :decision]), do: "authority.decision"

  defp event_name(event) when is_list(event),
    do: event |> Enum.map(&to_string/1) |> Enum.join(".")

  defp agent_label(nil), do: nil

  defp agent_label(module) when is_atom(module), do: inspect(module)

  defp agent_label(other), do: text(other)

  defp resource_label(nil), do: nil

  defp resource_label(resource) when is_atom(resource), do: inspect(resource)

  defp resource_label(other), do: text(other)

  # Receipt identities are %AshA2A.Identity{} structs; the trace carries
  # their value, never the struct inspect.
  defp identity_text(%{value: value}), do: text(value)
  defp identity_text(other), do: text(other)

  defp text(nil), do: nil
  defp text(v) when is_binary(v), do: v
  defp text(v) when is_atom(v) and not is_boolean(v), do: Atom.to_string(v)
  defp text(v) when is_integer(v), do: Integer.to_string(v)
  defp text(v), do: inspect(v)

  defp int(nil), do: nil
  defp int(v) when is_integer(v), do: v

  defp status(:stop), do: :ok
  defp status(:exception), do: :error

  defp safe(fun) do
    fun.()
  rescue
    _ -> :ok
  catch
    _kind, _reason -> :ok
  end
end
