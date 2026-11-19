defmodule AshA2A.Protocol.Agent.Runtime do
  @moduledoc false

  alias AshA2A.Protocol.Agent.State
  alias AshA2A.Protocol.{Artifact, Message, Task}
  alias AshA2A.Transport.SafeError

  @doc """
  Calls the agent's `handle_cancel/1` callback via `apply/3`.
  """
  @spec run_cancel(module(), AshA2A.Protocol.Agent.context()) :: :ok | {:error, String.t()}
  def run_cancel(module, context) do
    apply(module, :handle_cancel, [context])
  end

  @doc """
  Processes an incoming message through the agent's task lifecycle.

  Creates a new task, transitions through states, and calls `handle_message/2`.
  An agent that replies `{:message, parts}` answers without a task: the task
  built for the turn is discarded and only the agent message is returned.
  """
  @spec process_message(
          module(),
          Message.t(),
          String.t() | nil,
          State.t(),
          map(),
          map()
        ) :: {Task.t() | Message.t(), State.t()}
  def process_message(module, message, context_id, state, metadata \\ %{}, extensions \\ %{}) do
    task = Task.new(context_id: context_id, metadata: metadata)
    task = %{task | history: []}
    task = AshA2A.Protocol.Task.Generation.append_message(task, message)
    run_task(module, message, task, state, extensions)
  end

  @doc """
  Continues an existing task with a new message.

  Appends the message to the task's history and re-runs `handle_message/2`.
  Valid for any non-terminal task state. An agent that answers
  `{:message, parts}` here is rejected: the client is holding a task id, so a
  bare Message would strand the task and drop the turn from its history.
  """
  @spec continue_task(module(), Message.t(), Task.t(), State.t(), map()) ::
          {:ok, {Task.t(), State.t()}} | {:error, :not_continuable | :message_on_task}
  def continue_task(module, message, task, state, extensions \\ %{}) do
    if Task.terminal?(task) do
      {:error, :not_continuable}
    else
      task = Task.Generation.append_message(task, message)
      task = %{task | metadata: Map.delete(task.metadata, :stream)}

      case run_task(module, message, task, state, extensions) do
        {%Task{}, _state} = result -> {:ok, result}
        {%Message{}, _state} -> {:error, :message_on_task}
      end
    end
  end

  @doc """
  Runs `handle_message/2` for a task the caller already admitted and
  persisted (the `return_immediately` path): the task already carries the
  inbound message in its history, so nothing is appended here.
  """
  @spec run_admitted(module(), Message.t(), Task.t(), State.t(), map()) ::
          {:ok, {Task.t() | Message.t(), State.t()}}
  def run_admitted(module, message, task, state, extensions \\ %{}) do
    task = %{task | metadata: Map.delete(task.metadata, :stream)}
    {:ok, run_task(module, message, task, state, extensions)}
  end

  @doc """
  Wraps a stream so that consuming it stores every chunk and, at the end,
  notifies the agent GenServer to finalize the task.

  Each element is stored as its own task mutation before it is handed to the
  consumer (`{:stream_chunk, ...}`: the stream's artifact gains the chunk and
  the task generation advances by one), so the generation a chunk is emitted
  with is the generation `tasks/get` reports after it (A2A v1.1 3.2.7). The
  final element is stored as the chunk that completes the artifact
  (`end_generation`), which is what `lastChunk: true` is derived from; to know
  it is final, an element is handed out when its successor arrives or the
  stream ends.
  `chunk_generation/1` returns that generation to the consuming process.

  The closing notification carries how the enumeration ended.
  `Stream.transform/5` runs its `last_fun` only on normal completion, while
  the `after_fun` runs however enumeration stops — so the difference between
  the two is what separates a stream that finished from one that raised or
  was abandoned when the client disconnected. Without it the cleanup hook
  reports success for every ending, and a failed stream is stored as completed.
  """
  @spec wrap_stream(Enumerable.t(), GenServer.server(), String.t(), String.t() | nil) ::
          Enumerable.t()
  def wrap_stream(enum, server, task_id, artifact_id \\ nil) do
    # One stable artifact id per stream: the chunk mutations, the SSE chunk
    # emitter and the stream_done fold MUST reference the same artifact (v1.0
    # chunk reassembly is keyed on artifactId). The caller may pre-mint it
    # (the protocol agent stamps it onto the task metadata for the chunk
    # emitter); otherwise one is minted here for the default path.
    artifact_id = artifact_id || AshA2A.Protocol.ID.generate("art")

    # One-ahead: a lazy stream reveals its last element only by ending, so
    # chunk i is stored and handed out when chunk i+1 arrives, and the final
    # chunk when the stream ends. The final chunk is therefore STORED as the
    # one that completes the artifact, and every event derived from the stored
    # task (`AshA2A.Protocol.Task.Delta`) carries `lastChunk: true` on it and
    # on no other, whoever reports it first.
    Stream.transform(
      enum,
      fn -> {nil, [], :incomplete} end,
      fn part, {pending, acc, outcome} ->
        case pending do
          nil ->
            {[], {{:chunk, part}, [part | acc], outcome}}

          {:chunk, held} ->
            store_chunk(server, task_id, artifact_id, held, false)
            {[held], {{:chunk, part}, [part | acc], outcome}}
        end
      end,
      fn
        {{:chunk, held}, acc, _outcome} ->
          store_chunk(server, task_id, artifact_id, held, true)
          {[held], {nil, acc, :complete}}

        {nil, acc, _outcome} ->
          {[], {nil, acc, :complete}}
      end,
      fn {_pending, acc, outcome} ->
        # A chunk still held here (the stream raised or was abandoned) was
        # never stored; `finish_stream_artifact/2` folds it.
        parts = Enum.reverse(acc)
        GenServer.cast(server, {:stream_done, task_id, artifact_id, parts, outcome})
      end
    )
  end

  @chunk_generation_key :ash_a2a_stream_chunk_generation
  @chunk_last_key :ash_a2a_stream_chunk_last

  @doc """
  The task generation after the chunk the calling process last took from a
  wrapped stream of `task_id`, or `nil` when that chunk was not stored (the
  task was already terminal, or the agent could not be reached).
  """
  @spec chunk_generation(String.t()) :: pos_integer() | nil
  def chunk_generation(task_id), do: Process.get({@chunk_generation_key, task_id})

  @doc """
  Whether the chunk the calling process last took from a wrapped stream of
  `task_id` is the stream's final one (`lastChunk`).
  """
  @spec chunk_last?(String.t()) :: boolean()
  def chunk_last?(task_id), do: Process.get({@chunk_last_key, task_id}) == true

  # A stream enumerated inside the agent process itself cannot call the agent;
  # its parts are folded by `finish_stream_artifact/2` instead.
  defp store_chunk(server, task_id, artifact_id, part, last?) do
    reply =
      if server == self() do
        :not_stored
      else
        try do
          GenServer.call(server, {:stream_chunk, task_id, artifact_id, part, last?}, 15_000)
        catch
          :exit, _ -> :not_stored
        end
      end

    case reply do
      {:ok, generation} -> Process.put({@chunk_generation_key, task_id}, generation)
      _ -> Process.delete({@chunk_generation_key, task_id})
    end

    Process.put({@chunk_last_key, task_id}, last?)

    :ok
  end

  @doc """
  Closes a stream's artifact on the stored `task`. `artifact` carries every
  part the stream produced. Parts the chunk mutations already stored are left
  alone and the artifact is marked complete at the task's current generation
  (no new mutation); parts that were never stored are appended as one
  mutation. A stream that produced no part stores no artifact.
  """
  @spec finish_stream_artifact(Task.t(), Artifact.t()) :: Task.t()
  def finish_stream_artifact(%Task{} = task, %Artifact{} = artifact) do
    parts = Enum.flat_map(artifact.parts, &List.wrap/1)
    existing = Enum.find(task.artifacts, &(&1.artifact_id == artifact.artifact_id))
    stored = if existing, do: length(existing.parts), else: 0

    case {Enum.drop(parts, stored), existing} do
      {[], nil} ->
        task

      {[], %Artifact{}} ->
        generation = Task.Generation.generation_of(task)

        artifacts =
          Enum.map(task.artifacts, fn
            %Artifact{artifact_id: id} = a when id == artifact.artifact_id ->
              %{a | end_generation: a.end_generation || generation}

            other ->
              other
          end)

        %{task | artifacts: artifacts}

      {missing, _} ->
        {task, _stored} =
          Task.Generation.record_artifact(task, %{artifact | parts: missing}, true)

        task
    end
  end

  defp run_task(module, message, task, state, extensions) do
    task = State.transition(task, :working)

    context = %{
      task_id: task.id,
      context_id: task.context_id,
      history: task.history,
      metadata: task.metadata,
      extensions: extensions
    }

    meta = %{agent: module, task_id: task.id, context_id: task.context_id}

    reply =
      :telemetry.span([:a2a, :agent, :message], meta, fn ->
        result = module.handle_message(message, context)
        reply_type = elem(result, 0)
        {result, Map.put(meta, :reply_type, reply_type)}
      end)

    case handle_reply(reply, task) do
      %Task{} = task -> {task, State.track_context(state, task)}
      %Message{} = agent_message -> {agent_message, state}
    end
  end

  defp handle_reply({:reply, parts}, task) do
    artifact = Artifact.new(parts)
    agent_msg = Message.new_agent(parts)
    {task, _artifact} = Task.Generation.record_artifact(task, artifact, true)
    task = %{task | history: task.history ++ [agent_msg]}
    State.transition(task, :completed)
  end

  defp handle_reply({:stream, enum}, task) do
    %{task | metadata: Map.put(task.metadata, :stream, enum)}
  end

  # A bare Message answers out-of-band: the task built for this turn is
  # discarded, never persisted, and never reachable via `tasks/get`.
  defp handle_reply({:message, parts}, task) do
    %{Message.new_agent(parts) | context_id: task.context_id}
  end

  defp handle_reply({:input_required, parts}, task) do
    agent_msg = Message.new_agent(parts)
    task = %{task | history: task.history ++ [agent_msg]}
    State.transition(task, :input_required, agent_msg)
  end

  defp handle_reply({:error, reason}, task) do
    cond do
      # REJECTED (v1.0): the task was refused at admission -- an
      # authority-gate denial or a capability-resolution refusal that fired
      # BEFORE the handler had any effect. Nothing was attempted, so there
      # is nothing a resubmission-with-credentials could resume: terminal,
      # with a redacted reason.
      admission_refusal?(reason) ->
        refused_msg = Message.new_agent("Rejected: #{inspect(SafeError.redact(reason))}")
        State.transition(task, :rejected, refused_msg)

      # AUTH_REQUIRED (spec §3.4) is a non-terminal, resumable state: the
      # client supplies credentials and continues via the same task id. An
      # auth failure is therefore parked, not failed -- `continue_task/5`
      # accepts any non-terminal state, so a follow-up message with the
      # same task_id resumes it.
      auth_failure?(reason) ->
        agent_msg = Message.new_agent("Auth required: #{inspect(reason)}")
        State.transition(task, :auth_required, agent_msg)

      # Attempted-and-errored: the handler ran and something failed mid-run
      # -- terminal `:failed`.
      true ->
        error_msg = Message.new_agent("Error: #{inspect(reason)}")
        State.transition(task, :failed, error_msg)
    end
  end

  # Reasons that mean "the caller lacks the credentials to continue": the
  # direct protocol-agent contract (`{:error, :unauthorized}` /
  # `{:error, {:unauthorized, _}}` / `{:error, {:auth_required, _}}`). The
  # folded `"forbidden: <message>"` form `AshA2A.Dispatcher.to_reply/1`
  # emits for Ash `:forbidden`-class errors is an authority-gate refusal,
  # NOT a credentials gap, and classifies as `:rejected` below instead of
  # here. Everything else stays a terminal `:failed`.
  defp auth_failure?(:unauthorized), do: true
  defp auth_failure?({:unauthorized, _}), do: true
  defp auth_failure?({:auth_required, _}), do: true
  defp auth_failure?(_), do: false

  # Admission-phase refusals (v1.0 `rejected` = refused at admission, vs
  # `failed` = attempted-and-errored): refusal shapes produced BEFORE the
  # handler has any effect, so no resubmission with fresh credentials could
  # ever resume them.
  #
  #   * `"forbidden: " <> _` -- the folded form `AshA2A.Dispatcher.to_reply/1`
  #     emits for Ash `:forbidden`-class errors (`class_message/2` folds the
  #     class into a string rather than a tuple), i.e. the authority gate:
  #     an `Ash.Policy.Authorizer` denial.
  #   * `:forbidden` / `{:forbidden, _}` -- the same denial in direct
  #     protocol-agent tuple form.
  #   * `{:no_skill, _}` / `{:ambiguous_skill, _}` / `:skill_not_found` --
  #     capability resolution (`AshA2A.Agent.resolve_skill_name/2` and the
  #     dispatcher's skill lookup) could not name a capability for the
  #     request.
  #   * `{:unknown_skill, _}` -- the dispatcher's own skill lookup found no
  #     capability under the requested name.
  #   * `%{code: code}` -- an `AshA2A.CommandBus` admission or authority-gate
  #     refusal (`:consequence_unclassified`, `:authority_required`,
  #     `:authority_mismatch`, ...): the agent decided not to perform the
  #     task (A2A v1.1 `TASK_STATE_REJECTED`).
  #
  # One classifier for both task-finalizing paths:
  # `AshA2A.Transport.Runtime.admission_refusal?/1`.
  defp admission_refusal?(reason), do: AshA2A.Transport.Runtime.admission_refusal?(reason)
end
