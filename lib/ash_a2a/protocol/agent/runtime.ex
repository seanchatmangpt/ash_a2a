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
    task = %{task | history: [message]}
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
      task = %{task | history: task.history ++ [message]}
      task = %{task | metadata: Map.delete(task.metadata, :stream)}

      case run_task(module, message, task, state, extensions) do
        {%Task{}, _state} = result -> {:ok, result}
        {%Message{}, _state} -> {:error, :message_on_task}
      end
    end
  end

  @doc """
  Wraps a stream so that consuming it notifies the agent GenServer to
  finalize the task (create the artifact, transition to a terminal state).

  The notification carries how the enumeration ended. `Stream.transform/5`
  runs its `last_fun` only on normal completion, while the `after_fun` runs
  however enumeration stops — so the difference between the two is what
  separates a stream that finished from one that raised or was abandoned
  when the client disconnected. Without it the cleanup hook reports success
  for every ending, and a failed stream is stored as completed.
  """
  @spec wrap_stream(Enumerable.t(), GenServer.server(), String.t(), String.t() | nil) ::
          Enumerable.t()
  def wrap_stream(enum, server, task_id, artifact_id \\ nil) do
    # One stable artifact id per stream: the SSE chunk emitter and the
    # stream_done fold MUST reference the same artifact (v1.0 chunk
    # reassembly is keyed on artifactId). The caller may pre-mint it (the
    # protocol agent stamps it onto the task metadata for the chunk emitter);
    # otherwise one is minted here for the default path.
    artifact_id = artifact_id || AshA2A.Protocol.ID.generate("art")

    Stream.transform(
      enum,
      fn -> {[], :incomplete} end,
      fn part, {acc, outcome} -> {[part], {[part | acc], outcome}} end,
      fn {acc, _outcome} -> {[], {acc, :complete}} end,
      fn {acc, outcome} ->
        parts = Enum.reverse(acc)
        GenServer.cast(server, {:stream_done, task_id, artifact_id, parts, outcome})
      end
    )
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
    task = %{task | artifacts: task.artifacts ++ [artifact]}
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
  #   * `%{code: :consequence_unclassified}` -- capability consequence
  #     classification refused the skill (RFC-SA2A-004 S21).
  defp admission_refusal?("forbidden: " <> _), do: true
  defp admission_refusal?(:forbidden), do: true
  defp admission_refusal?({:forbidden, _}), do: true
  defp admission_refusal?(:skill_not_found), do: true
  defp admission_refusal?({:no_skill, _}), do: true
  defp admission_refusal?({:ambiguous_skill, _}), do: true
  defp admission_refusal?(%{code: :consequence_unclassified}), do: true
  defp admission_refusal?(_), do: false
end
