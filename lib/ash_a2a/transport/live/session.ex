# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Transport.Live.Session do
  @moduledoc """
  One live (`SendLiveMessage`) exchange as a GenServer. See
  `AshA2A.Transport.Live` for the public API and semantics; this module is the
  implementation and is not called directly.

  The session binds to one task, follows it through the agent's own subscriber
  fan-out (`{:subscribe, task_id}` -> `{:a2a_task_event, task_id, task}`) and
  turns each observed task snapshot into the minimal downlink events by diffing
  against the last snapshot it delivered. Because call results and fan-out
  pushes go through the same idempotent diff, no event is ever delivered twice.
  Agent calls run in a monitored worker so the session stays responsive; a send
  arriving while one is in flight is declined with `UNAVAILABLE`.
  """

  use GenServer, restart: :temporary

  alias AshA2A.A2ATransport.Ownership
  alias AshA2A.Protocol.{ClientArtifacts, Message, StreamRequest}
  alias AshA2A.Protocol.Event.{ArtifactUpdate, MessageUpdate, StatusUpdate}
  alias AshA2A.Protocol.Task, as: T
  alias AshA2A.Transport.{Live, Principal}

  @busy [:task_in_progress, :server_busy, :rate_limited]

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  # -- init ---------------------------------------------------------------------

  @impl true
  def init({id, agent, ctx, downlink, card}) do
    metadata = Map.get(ctx, :metadata, %{})
    principal = Live.principal(ctx)

    dl_mon = if is_pid(downlink), do: Process.monitor(downlink)
    Live.register({:session, id}, principal)

    {:ok,
     %{
       id: id,
       agent: agent,
       ctx: ctx,
       card: card,
       principal: principal,
       tenant: Principal.tenant(metadata),
       downlink: downlink,
       dl_mon: dl_mon,
       task_id: nil,
       last: nil,
       started?: false,
       call: nil,
       closed?: false
     }}
  end

  # -- calls --------------------------------------------------------------------

  @impl true
  def handle_call(:id, _from, st), do: {:reply, st.id, st}

  def handle_call({:uplink, map}, from, st),
    do: st |> request(map, {:stream, from}) |> finish()

  def handle_call({:uplink_call, map, principal}, from, st) do
    if principal == st.principal do
      st |> request(map, {:ack, from}) |> finish()
    else
      {:reply, {:error, :unknown_session}, st}
    end
  end

  @impl true
  def handle_cast(:close, st), do: st |> close(:closed) |> finish()

  @impl true
  def handle_info({:call_done, ref, result}, %{call: %{ref: ref} = call} = st) do
    Process.demonitor(call.mref, [:flush])
    %{st | call: nil} |> apply_result(call, result) |> finish()
  end

  def handle_info({:DOWN, mref, :process, _pid, reason}, %{call: %{mref: mref} = call} = st) do
    %{st | call: nil}
    |> apply_result(call, {:error, {:worker_exit, reason}})
    |> finish()
  end

  def handle_info({:DOWN, mref, :process, _pid, _reason}, %{dl_mon: mref} = st),
    do: {:stop, :normal, %{st | closed?: true}}

  def handle_info({:a2a_task_event, id, %T{} = task}, %{task_id: id, closed?: false} = st)
      when is_binary(id),
      do: st |> observe(task) |> finish()

  def handle_info(_other, st), do: {:noreply, st}

  @impl true
  def terminate(_reason, %{call: %{pid: pid}}), do: Process.exit(pid, :kill)
  def terminate(_reason, _st), do: :ok

  defp finish(%{closed?: true} = st), do: {:stop, :normal, st}
  defp finish(st), do: {:noreply, st}

  # -- request dispatch ---------------------------------------------------------

  defp request(st, map, mode) do
    case StreamRequest.decode(map) do
      {:ok, %StreamRequest{kind: :subscribe} = r} ->
        subscribe(st, r, mode)

      {:ok, %StreamRequest{kind: :send_message} = r} ->
        send_message(st, r, mode)

      {:error, {:unknown_payload, keys}} ->
        reject(st, mode, "UNIMPLEMENTED", "unknown payload kind: " <> Enum.map_join(keys, ",", &inspect/1), nil)

      {:error, {:invalid, detail, ref}} ->
        reject(st, mode, "INVALID_ARGUMENT", detail, ref)
    end
  end

  defp reject(st, mode, code, message, ref) do
    st = emit(st, Live.stream_error(code, message, st.task_id, ref))
    reply_ok(st, mode)
    st
  end

  defp reply_ok(_st, {:stream, from}), do: GenServer.reply(from, :ok)
  defp reply_ok(st, {:ack, from}), do: GenServer.reply(from, {:ack, current_task(st)})

  defp reply_error(error, {_, from}), do: GenServer.reply(from, {:error, error})

  # -- subscribe ----------------------------------------------------------------

  defp subscribe(st, r, mode) do
    cond do
      st.started? ->
        reject(st, mode, "FAILED_PRECONDITION", "subscribe is only valid as the first request of a stream", nil)

      match?({:ack, _}, mode) ->
        reject(st, mode, "FAILED_PRECONDITION", "an uplink call cannot open a stream", nil)

      true ->
        %{task_id: id, last_seen_generation: seen} = r.payload
        tenant = r.tenant || st.tenant

        case Ownership.fetch_strict(st.agent, id, {st.principal, tenant}) do
          {:ok, task} ->
            reply_ok(st, mode)
            {st, task} = bind(%{st | tenant: tenant}, task)
            deliver_initial(st, task, seen)

          {:error, reason} ->
            reply_error(reason, mode)
            st
        end
    end
  end

  defp deliver_initial(st, task, seen) do
    wired = Live.wire(task)

    events =
      case if(seen, do: replay(wired, seen), else: :snapshot) do
        :snapshot -> [wired]
        events -> events
      end

    st = emit_all(st, events)
    %{st | last: wired} |> close_if_terminal(wired)
  end

  defp bind(st, task) do
    Live.register({:task, st.agent, task.id}, st.principal)

    task =
      if T.terminal?(task) do
        task
      else
        case agent_subscribe(st.agent, task.id) do
          %T{} = snapshot -> snapshot
          _ -> task
        end
      end

    {%{st | task_id: task.id, started?: true}, task}
  end

  defp agent_subscribe(agent, task_id) do
    case GenServer.call(agent, {:subscribe, task_id}, 5_000) do
      {:ok, snapshot} -> snapshot
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  # -- send ---------------------------------------------------------------------

  defp send_message(st, r, mode) do
    p = r.payload
    tenant = r.tenant || st.tenant
    ref = p.message && p.message.message_id
    task_id = st.task_id || p.task_id

    with :ok <- if(st.call == nil, do: :ok, else: {:reject, "UNAVAILABLE", "a previous request is still being processed"}),
         :ok <- validate_send(st.card, st.task_id, p),
         {:ok, gen_match} <- parse_gen_match(p.configuration),
         :ok <- check_owned(st, task_id, tenant) do
      start_call(%{st | tenant: tenant}, p, task_id, gen_match, ref, mode)
    else
      {:reject, code, message} ->
        reject(st, mode, code, message, ref)

      {:error, :bad_gen} ->
        reject(st, mode, "INVALID_ARGUMENT", "ifGenerationMatch must be a non-negative integer", ref)

      {:error, :not_found} when is_nil(st.task_id) ->
        reply_error(:not_found, mode)
        st

      {:error, :not_found} ->
        reject(st, mode, "NOT_FOUND", "task not found", ref)

      {:error, _unavailable} ->
        reject(st, mode, "UNAVAILABLE", "agent unavailable", ref)
    end
  end

  defp check_owned(_st, nil, _tenant), do: :ok

  defp check_owned(st, task_id, tenant) do
    case Ownership.fetch_strict(st.agent, task_id, {st.principal, tenant}) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc false
  def validate_send(card, bound_task_id, p) do
    task_id = bound_task_id || p.task_id

    cond do
      bound_task_id != nil and p.task_id != nil and p.task_id != bound_task_id ->
        {:reject, "INVALID_ARGUMENT", "request names a different task than the one this stream is bound to"}

      p.artifact_updates != [] and not Live.capability?(card, :user_artifacts) ->
        {:reject, "UNSUPPORTED_OPERATION", "userArtifacts capability is not declared"}

      task_id == nil and p.message == nil ->
        {:reject, "INVALID_ARGUMENT", "message is required when creating a task"}

      true ->
        :ok
    end
  end

  defp parse_gen_match(configuration) do
    case Map.get(configuration, "ifGenerationMatch") do
      nil -> {:ok, nil}
      n when is_integer(n) and n >= 0 -> {:ok, n}
      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} when n >= 0 -> {:ok, n}
          _ -> {:error, :bad_gen}
        end

      _ -> {:error, :bad_gen}
    end
  end

  defp start_call(st, p, task_id, gen_match, ref, mode) do
    message =
      case p.message do
        nil -> nil
        m -> if task_id, do: %{m | task_id: task_id}, else: m
      end

    opts = call_opts(st.ctx, st.principal, st.tenant, task_id, p.configuration, gen_match)
    session = self()
    token = make_ref()
    agent = st.agent
    updates = p.artifact_updates

    {pid, mref} =
      spawn_monitor(fn ->
        send(session, {:call_done, token, run_send(agent, message, updates, task_id, opts)})
      end)

    call = %{ref: token, pid: pid, mref: mref, ref_id: ref, ack_from: nil}
    st = %{st | call: call, started?: true}

    case {mode, task_id} do
      {{:stream, from}, _} ->
        GenServer.reply(from, :ok)
        st

      {{:ack, from}, nil} ->
        # task id unknown until the agent answers: ack with the result
        %{st | call: %{call | ack_from: from}}

      {{:ack, _from}, _id} ->
        reply_ok(st, mode)
        st
    end
  end

  @doc false
  def call_opts(ctx, principal, tenant, task_id, configuration, gen_match) do
    metadata = Map.get(ctx, :metadata, %{})
    metadata = if tenant, do: Map.put(metadata, "ash_a2a.tenant", tenant), else: metadata

    modes =
      case Map.get(configuration, "acceptedOutputModes") do
        [_ | _] = list -> list
        _ -> nil
      end

    [
      metadata: metadata,
      principal: principal,
      timeout: Map.get(ctx, :timeout, 60_000),
      task_id: task_id,
      accepted_output_modes: modes,
      if_generation_match: gen_match
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  @doc false
  def run_send(agent, message, updates, task_id, opts) do
    result =
      if message do
        AshA2A.Protocol.call(agent, message, opts)
      else
        case GenServer.call(agent, {:get_task, task_id}) do
          {:ok, task} ->
            case ClientArtifacts.check_generation(task, Keyword.get(opts, :if_generation_match)) do
              :ok -> {:ok, task}
              error -> error
            end

          error ->
            error
        end
      end

    case result do
      {:ok, %T{} = task} when updates != [] -> apply_updates(agent, task.id, updates)
      other -> other
    end
  catch
    :exit, reason -> {:error, {:worker_exit, reason}}
  end

  defp apply_updates(agent, task_id, updates) do
    case ClientArtifacts.decode_updates(updates) do
      {:ok, decoded} -> GenServer.call(agent, {:apply_artifact_updates, task_id, decoded})
      {:error, reason} -> {:error, {:invalid_params, inspect(reason)}}
    end
  end

  # -- call results -------------------------------------------------------------

  defp apply_result(st, call, {:ok, %T{} = task}) do
    {st, task} = if st.task_id, do: {st, task}, else: bind(st, task)
    drain_stream(task)
    st = observe(st, task)
    ack_reply(call, {:ack, Live.wire(task)})
    st
  end

  defp apply_result(st, call, {:ok, %Message{} = message}) do
    st = emit(st, message)
    ack_reply(call, {:ack, message})
    if st.task_id, do: st, else: close(st, :message)
  end

  defp apply_result(st, call, {:error, reason}) do
    {code, text} = error_code(reason)
    st = emit(st, Live.stream_error(code, text, st.task_id, call.ref_id))
    ack_reply(call, {:ack, nil})
    if st.task_id, do: st, else: %{st | started?: false}
  end

  defp apply_result(st, call, other),
    do: apply_result(st, call, {:error, {:unexpected_result, other}})

  defp ack_reply(%{ack_from: nil}, _), do: :ok
  defp ack_reply(%{ack_from: from}, value), do: GenServer.reply(from, value)

  # A `{:stream, enum}` reply leaves the task :working until the enumerable is
  # consumed; nobody on a live downlink consumes it, so drain it (as the
  # protocol agent does for detached calls). Its `:stream_done` cast folds the
  # artifact and notifies this session through the subscriber fan-out.
  defp drain_stream(%T{metadata: %{stream: stream}}) do
    callers = [self() | Process.get(:"$callers", [])]

    spawn(fn ->
      Process.put(:"$callers", callers)
      Stream.run(stream)
    end)

    :ok
  end

  defp drain_stream(_task), do: :ok

  @doc false
  def error_code(:not_found), do: {"NOT_FOUND", "task not found"}
  def error_code(:context_mismatch), do: {"INVALID_ARGUMENT", "contextId does not match the task"}
  def error_code(:not_continuable), do: {"FAILED_PRECONDITION", "task is terminal and cannot be continued"}
  def error_code(:generation_mismatch), do: {"ABORTED", "ifGenerationMatch does not match the task generation"}
  def error_code(:task_in_progress), do: {"UNAVAILABLE", "agent is not accepting input right now"}
  def error_code(%{code: code}) when code in @busy, do: {"UNAVAILABLE", "agent is not accepting input right now"}
  def error_code({:unsupported_operation, _}), do: {"UNSUPPORTED_OPERATION", "operation not supported"}
  def error_code({:invalid_params, detail}) when is_binary(detail), do: {"INVALID_ARGUMENT", detail}
  def error_code(_other), do: {"INTERNAL", "internal error"}

  # -- observation / diff -------------------------------------------------------

  defp observe(%{closed?: true} = st, _task), do: st

  defp observe(st, task) do
    wired = Live.wire(task)

    case st.last do
      nil ->
        st |> emit(wired) |> Map.put(:last, wired) |> close_if_terminal(wired)

      last ->
        if gen(wired) < gen(last) do
          st
        else
          st |> emit_all(diff(last, wired)) |> Map.put(:last, wired) |> close_if_terminal(wired)
        end
    end
  end

  defp close_if_terminal(st, task), do: if(T.terminal?(task), do: close(st, :terminal), else: st)

  defp diff(last, task) do
    ctx_id = task.context_id

    messages =
      for {m, g} <- new_user_messages(last, task),
          do: MessageUpdate.new(task.id, m, context_id: ctx_id, generation: g)

    artifacts =
      Enum.flat_map(task.artifacts, fn art ->
        prev = Enum.find(last.artifacts, &(&1.artifact_id == art.artifact_id))

        cond do
          prev == nil ->
            [artifact_event(task, art, false)]

          length(art.parts) > length(prev.parts) ->
            fresh = %{art | parts: Enum.drop(art.parts, length(prev.parts))}
            [artifact_event(task, fresh, true, art)]

          true ->
            []
        end
      end)

    status =
      if last.status != task.status do
        [
          StatusUpdate.new(task.id, task.status,
            context_id: ctx_id,
            final: T.terminal?(task),
            generation: status_gen(task)
          )
        ]
      else
        []
      end

    messages ++ artifacts ++ status
  end

  defp artifact_event(task, art, append?, full \\ nil) do
    full = full || art

    ArtifactUpdate.new(task.id, art,
      context_id: task.context_id,
      append: append?,
      last_chunk: full.end_generation != nil or T.terminal?(task),
      generation: full.end_generation || full.start_generation || gen(task)
    )
  end

  defp new_user_messages(last, task) do
    if task.timeline != [] do
      lg = gen(last)

      for %{entry: {:message, %Message{role: :user} = m}, generation: g} <- task.timeline,
          g > lg,
          do: {m, g}
    else
      task.history
      |> Enum.drop(length(last.history))
      |> Enum.filter(&(&1.role == :user))
      |> Enum.map(&{&1, gen(task)})
    end
  end

  defp status_gen(task) do
    task.timeline
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{entry: {:status, _}, generation: g} -> g
      _ -> nil
    end) || gen(task)
  end

  # Events strictly after `seen`, reconstructed from the timeline and artifacts.
  # `:snapshot` when the server cannot replay from `seen`.
  defp replay(task, seen) do
    g = gen(task)

    cond do
      seen > g ->
        :snapshot

      seen == g ->
        []

      true ->
        from_timeline =
          for %{entry: entry, generation: eg} <- task.timeline, eg > seen, reduce: [] do
            acc ->
              case entry do
                {:status, status} ->
                  acc ++
                    [
                      {eg,
                       StatusUpdate.new(task.id, status,
                         context_id: task.context_id,
                         final: status.state in [:completed, :failed, :canceled, :rejected],
                         generation: eg
                       )}
                    ]

                {:message, %Message{role: :user} = m} ->
                  acc ++ [{eg, MessageUpdate.new(task.id, m, context_id: task.context_id, generation: eg)}]

                _ ->
                  acc
              end
          end

        from_artifacts =
          Enum.flat_map(task.artifacts, fn art ->
            ag = art.end_generation || art.start_generation

            if is_integer(ag) and ag > seen,
              do: [{ag, artifact_event(task, art, false)}],
              else: []
          end)

        case Enum.sort_by(from_timeline ++ from_artifacts, &elem(&1, 0)) do
          [] -> :snapshot
          events -> Enum.map(events, &elem(&1, 1))
        end
    end
  end

  defp gen(task), do: T.Generation.generation_of(task)

  defp current_task(%{task_id: nil}), do: nil

  defp current_task(st) do
    case Ownership.fetch_strict(st.agent, st.task_id, {st.principal, st.tenant}) do
      {:ok, task} -> Live.wire(task)
      _ -> st.last
    end
  end

  # -- delivery -----------------------------------------------------------------

  defp emit_all(st, events), do: Enum.reduce(events, st, &emit(&2, &1))

  defp emit(%{closed?: true} = st, _event), do: st

  defp emit(st, event) do
    deliver(st, {:a2a_live, st.id, event})
    st
  end

  defp close(%{closed?: true} = st, _reason), do: st

  defp close(st, reason) do
    deliver(st, {:a2a_live_closed, st.id, reason})
    %{st | closed?: true}
  end

  defp deliver(%{downlink: pid}, msg) when is_pid(pid), do: send(pid, msg)
  defp deliver(%{downlink: fun}, msg) when is_function(fun, 1), do: fun.(msg)

  # -- session-less uplink call ---------------------------------------------------

  @doc false
  def direct(agent, ctx, request) do
    principal = Live.principal(ctx)

    case StreamRequest.decode(request) do
      {:ok, %StreamRequest{kind: :subscribe}} ->
        {:error,
         Live.stream_error("FAILED_PRECONDITION", "an uplink call cannot open a stream", nil, nil)}

      {:ok, %StreamRequest{kind: :send_message} = r} ->
        direct_send(agent, ctx, principal, r)

      {:error, {:unknown_payload, keys}} ->
        {:error,
         Live.stream_error("UNIMPLEMENTED", "unknown payload kind: " <> Enum.map_join(keys, ",", &inspect/1), nil, nil)}

      {:error, {:invalid, detail, ref}} ->
        {:error, Live.stream_error("INVALID_ARGUMENT", detail, nil, ref)}
    end
  end

  defp direct_send(agent, ctx, principal, r) do
    p = r.payload
    tenant = r.tenant || Principal.tenant(Map.get(ctx, :metadata, %{}))
    ref = p.message && p.message.message_id

    with :ok <- validate_send(ctx.card, nil, p),
         {:ok, gen_match} <- parse_gen_match(p.configuration),
         :ok <- owned(agent, p.task_id, principal, tenant) do
      message = p.message && if(p.task_id, do: %{p.message | task_id: p.task_id}, else: p.message)
      opts = call_opts(ctx, principal, tenant, p.task_id, p.configuration, gen_match)

      case run_send(agent, message, p.artifact_updates, p.task_id, opts) do
        {:ok, %T{} = task} ->
          drain_stream(task)
          {:ack, Live.wire(task)}

        {:ok, %Message{} = m} ->
          {:ack, m}

        {:error, :not_found} ->
          {:error, :not_found}

        {:error, reason} ->
          {code, text} = error_code(reason)
          {:error, Live.stream_error(code, text, p.task_id, ref)}
      end
    else
      {:reject, code, text} -> {:error, Live.stream_error(code, text, p.task_id, ref)}
      {:error, :bad_gen} -> {:error, Live.stream_error("INVALID_ARGUMENT", "ifGenerationMatch must be a non-negative integer", p.task_id, ref)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  defp owned(_agent, nil, _principal, _tenant), do: :ok

  defp owned(agent, task_id, principal, tenant) do
    case Ownership.fetch_strict(agent, task_id, {principal, tenant}) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end
end
