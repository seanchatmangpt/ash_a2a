# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Transport.Follow do
  @moduledoc false
  # The event stream of one task, shared by the streaming RPCs of every
  # binding (`SendStreamingMessage`, gRPC `SubscribeToTask`).
  #
  # ## Admit first
  #
  # `admit_opts/1` turns agent call options into an admit-first send: the
  # agent stores the task and answers with it before the handler runs
  # (`return_immediately`), and the calling process joins the task's
  # subscriber fan-out in that same step (`subscribe: self()`). The binding
  # sends that Task as the first frame, so its id is usable (GetTask,
  # CancelTask) while the handler is still running (A2A v1.1 3.1.2).
  #
  # ## Following
  #
  # `events/4` is a lazy enumerable, consumed in the process that subscribed.
  # It yields `opening` first, then, for every stored task the agent shows the
  # subscriber, the mutations not yet sent (`AshA2A.Protocol.Task.Delta`): each
  # event carries the generation the task store gave that mutation, a mutation
  # that landed before the subscription is not lost, nothing is sent twice.
  #
  # ## Lifetime
  #
  # The stream ends when the task is terminal, and in `:send` mode also when
  # it is interrupted (input-required / auth-required). A quiet handler does
  # not end it: the specification closes a stream on the task's state, never
  # on silence. Every `:tick_ms` (15 s) without an event the task is read
  # again from the agent, so a notification that never arrived cannot strand
  # the stream, and `:keepalive` is yielded when `keepalive: true` (an SSE
  # binding writes a comment line, which keeps proxies from cutting the
  # connection). `:max_idle_ms` bounds the silence when a host wants a bound;
  # it is `:infinity` unless configured.

  alias AshA2A.Protocol.Task, as: T
  alias AshA2A.Protocol.Task.{Delta, Generation}

  @default_tick_ms 15_000

  @type mode :: :send | :subscribe

  @doc "Agent call options for an admit-first send from the calling process."
  @spec admit_opts(keyword()) :: keyword()
  def admit_opts(call_opts) do
    call_opts
    |> Keyword.put(:return_immediately, true)
    |> Keyword.put(:subscribe, self())
  end

  @doc """
  The stream's options from a transport context or option map: `:stream_tick_ms`,
  `:stream_max_idle_ms` (the legacy `:stream_idle_ms` is read as that bound).
  """
  @spec stream_opts(map() | keyword()) :: keyword()
  def stream_opts(source) do
    get = fn key ->
      cond do
        is_map(source) -> Map.get(source, key)
        is_list(source) -> Keyword.get(source, key)
        true -> nil
      end
    end

    [
      tick_ms: positive(get.(:stream_tick_ms)),
      max_idle_ms: positive(get.(:stream_max_idle_ms)) || positive(get.(:stream_idle_ms))
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp positive(ms) when is_integer(ms) and ms > 0, do: ms
  defp positive(_), do: nil

  @doc """
  The enumerable. `task` is the wire-safe task the stream starts from
  (`wire/1`), `opening` what is yielded first (that task, or replayed events).

  Options: `:subscribed?` (the caller joined the fan-out at admission; default
  `false`, the enumerable subscribes itself), `:tick_ms`, `:max_idle_ms`,
  `:keepalive`, `:on_settled` (called once with the task that ended the
  stream).
  """
  @spec events(GenServer.server(), T.t(), [struct()], mode(), keyword()) :: Enumerable.t()
  def events(agent, %T{} = task, opening, mode, opts \\ []) do
    tick_ms = Keyword.get(opts, :tick_ms) || default_tick_ms()
    max_idle_ms = Keyword.get(opts, :max_idle_ms) || :infinity
    tick_ms = if is_integer(max_idle_ms), do: min(tick_ms, max_idle_ms), else: tick_ms
    keepalive? = Keyword.get(opts, :keepalive, false)
    on_settled = Keyword.get(opts, :on_settled, fn _task -> :ok end)
    task_id = task.id

    advance = fn queue, last, seen_task ->
      next = wire(seen_task)

      cond do
        Generation.generation_of(next) < Generation.generation_of(last) ->
          {queue, {:follow, last, 0}}

        settled?(next, mode) ->
          on_settled.(next)
          {queue ++ delta(last, next), :done}

        true ->
          {queue ++ delta(last, next), {:follow, next, 0}}
      end
    end

    Stream.resource(
      fn ->
        cond do
          settled?(task, mode) ->
            on_settled.(task)
            {opening, :done}

          Keyword.get(opts, :subscribed?, false) ->
            {opening, {:follow, task, 0}}

          true ->
            case subscribe(agent, task_id) do
              {:ok, %T{} = snapshot} -> advance.(opening, task, snapshot)
              _terminal_or_gone -> advance.(opening, task, fetch(agent, task_id) || task)
            end
        end
      end,
      fn
        {[event | rest], next} ->
          {[event], {rest, next}}

        {[], :done} ->
          {:halt, :done}

        {[], {:follow, last, idle}} ->
          receive do
            {:a2a_task_event, ^task_id, %T{} = seen} ->
              {[], advance.([], last, seen)}
          after
            tick_ms ->
              idle = idle + tick_ms
              current = fetch(agent, task_id)

              cond do
                # The task is gone (or its agent is): nothing more can come.
                current == nil ->
                  {:halt, :done}

                # A mutation whose notification never arrived.
                Generation.generation_of(current) > Generation.generation_of(last) ->
                  {[], advance.([], last, current)}

                max_idle_ms != :infinity and idle >= max_idle_ms ->
                  {:halt, :done}

                true ->
                  {if(keepalive?, do: [:keepalive], else: []), {[], {:follow, last, idle}}}
              end
          end
      end,
      fn _state -> :ok end
    )
  end

  @doc """
  Whether the task is stored and not terminal. A subscribe stream that has
  been silent for its idle bound asks this before closing: a task that is
  still running keeps its subscriber, however quiet its handler is.
  """
  @spec running?(GenServer.server() | nil, String.t()) :: boolean()
  def running?(nil, _task_id), do: false

  def running?(agent, task_id) do
    case fetch(agent, task_id) do
      %T{} = task -> not T.terminal?(task)
      nil -> false
    end
  end

  @doc "The task as a binding may send it: no credential, owner key or stream."
  @spec wire(T.t()) :: T.t()
  def wire(%T{} = task),
    do: task |> AshA2A.Transport.Runtime.wire_task() |> T.strip_stream_metadata()

  @doc "Whether `task` ends a stream of `mode`."
  @spec settled?(T.t(), mode()) :: boolean()
  def settled?(%T{} = task, :subscribe), do: T.terminal?(task)

  def settled?(%T{} = task, :send),
    do: T.terminal?(task) or task.status.state in [:input_required, :auth_required]

  # The mutations between two shown tasks. A task without a timeline still
  # reports a status change.
  defp delta(last, task) do
    events = for {_gen, event} <- Delta.events(last, task), do: event

    status_reported? = Enum.any?(events, &match?(%AshA2A.Protocol.Event.StatusUpdate{}, &1))

    if not status_reported? and task.status.state != last.status.state do
      events ++
        [
          AshA2A.Protocol.Event.StatusUpdate.new(task.id, task.status,
            context_id: task.context_id,
            final: T.terminal?(task),
            generation: Generation.generation_of(task)
          )
        ]
    else
      events
    end
  end

  defp subscribe(agent, task_id) do
    GenServer.call(agent, {:subscribe, task_id}, 5_000)
  catch
    :exit, _ -> :error
  end

  defp fetch(agent, task_id) do
    case GenServer.call(agent, {:get_task, task_id}, 5_000) do
      {:ok, %T{} = task} -> task
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  defp default_tick_ms do
    case Application.get_env(:ash_a2a, :stream_tick_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @default_tick_ms
    end
  end
end
