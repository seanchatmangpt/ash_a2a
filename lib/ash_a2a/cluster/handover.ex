# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Cluster.Handover do
  @moduledoc """
  Cluster handover events and the peer rehydration path.

  When `AshA2A.Cluster.DrainManager` lands a task's execution frame durably
  (`AshA2A.Cluster.Checkpoint.land/4`), it emits a cluster handover event so
  surviving peers know work is suspended and adoptable. The event travels
  two ways:

    * `[:ash_a2a, :cluster, :handover]` telemetry, always;
    * a `Phoenix.PubSub` broadcast of
      `{:ash_a2a_cluster_handover, %{task_id: _, source_node: _, reason: _}}`
      on the topic configured under `config :ash_a2a, :cluster_pubsub`
      (`{pubsub_name, topic}`), when configured.

  Rehydration, though, does not depend on catching the in-flight event: the
  durable checkpoint IS the handover. A fresh (or surviving) peer runs
  `rehydrate/2` against the same `AshA2A.TaskStore.Ekv` `:data_dir` -- the
  multinode read-through mechanics -- finds every checkpointed task, resumes
  it from its stored frame, and writes the completed task back with the
  checkpoint envelope cleared. Zero-drop is then a property of durable
  storage, not of event delivery.
  """

  alias AshA2A.Cluster.Checkpoint
  alias AshA2A.Protocol.Task

  @result_metadata_key "a2a.cluster.result"
  @default_topic "ash_a2a:cluster"

  @type store :: Checkpoint.store()
  @type resume_fun :: (Task.t(), frame :: term() -> {:ok, term()} | {:error, term()})

  @doc "Metadata key under which a rehydrated task's result is stored."
  @spec result_metadata_key() :: String.t()
  def result_metadata_key, do: @result_metadata_key

  @doc """
  Emits a cluster handover event for `task_id`.

  Always `:ok`; telemetry fires unconditionally, PubSub broadcasts only when
  `config :ash_a2a, :cluster_pubsub` is set.
  """
  @spec emit(String.t(), keyword()) :: :ok
  def emit(task_id, meta \\ []) when is_binary(task_id) do
    event =
      %{
        task_id: task_id,
        source_node: Keyword.get(meta, :source_node, node()),
        reason: Keyword.get(meta, :reason, :drain),
        checkpointed_at: Keyword.get(meta, :checkpointed_at)
      }

    :telemetry.execute([:ash_a2a, :cluster, :handover], %{count: 1}, event)

    case pubsub() do
      {pubsub_name, topic} when is_atom(pubsub_name) and pubsub_name != nil ->
        Phoenix.PubSub.broadcast(pubsub_name, topic, {:ash_a2a_cluster_handover, event})

      _ ->
        :ok
    end

    :ok
  end

  @doc """
  Every durably checkpointed (suspended, adoptable) task in `store`.
  """
  @spec list_checkpointed(store()) :: {:ok, [Task.t()]}
  def list_checkpointed(store) do
    {store_mod, store_ref} = store

    {:ok, %{tasks: tasks}} = store_mod.list_all(store_ref, page_size: 100_000)

    {:ok, Enum.filter(tasks, &Checkpoint.checkpointed?/1)}
  end

  @doc """
  Resumes every checkpointed task in `store` through `resume_fun`.

  `resume_fun` receives the suspended task and its stored execution frame
  and returns `{:ok, result}` when the remaining work concluded. The adopted
  task is written back `:completed` with its result in metadata under
  `"a2a.cluster.result"` and the checkpoint envelope cleared; a duplicate
  write is idempotent (the envelope is gone, so it is no longer
  checkpointed). Returns the list of resumed task results.

  A `resume_fun` `{:error, reason}` leaves the checkpoint envelope intact
  (the task stays suspended and adoptable by another peer) and is collected
  instead of raised.
  """
  @spec rehydrate(store(), resume_fun()) :: {:ok, [map()]} | {:error, [map()]}
  def rehydrate(store, resume_fun) when is_function(resume_fun, 2) do
    {:ok, checkpointed} = list_checkpointed(store)

    {resumed, failed} =
      Enum.reduce(checkpointed, {[], []}, fn task, {resumed, failed} ->
        case rehydrate_one(store, task, resume_fun) do
          {:ok, entry} -> {[entry | resumed], failed}
          {:error, entry} -> {resumed, [entry | failed]}
        end
      end)

    case failed do
      [] -> {:ok, Enum.reverse(resumed)}
      _ -> {:error, Enum.reverse(failed)}
    end
  end

  @doc """
  Resumes a single checkpointed task through `resume_fun`.
  """
  @spec rehydrate_one(store(), Task.t(), resume_fun()) ::
          {:ok, %{task_id: String.t(), result: term()}} | {:error, map()}
  def rehydrate_one(store, %Task{} = task, resume_fun) when is_function(resume_fun, 2) do
    {store_mod, store_ref} = store

    with {:ok, envelope} <- Checkpoint.envelope(task),
         {:ok, result} <- safe_resume(resume_fun, task, envelope["frame"]) do
      completed =
        task
        |> Checkpoint.cleared()
        |> then(&%{&1 | status: AshA2A.Protocol.Task.Status.new(:completed)})
        |> put_result(result)

      :ok = store_mod.put(store_ref, completed)

      :telemetry.execute(
        [:ash_a2a, :cluster, :handover, :completed],
        %{count: 1},
        %{task_id: task.id, node: node()}
      )

      {:ok, %{task_id: task.id, result: result}}
    else
      {:error, reason} ->
        {:error, %{task_id: task.id, reason: reason}}

      :error ->
        {:error, %{task_id: task.id, reason: :missing_checkpoint_envelope}}
    end
  end

  @doc "`{:ok, result}` when `task` was rehydrated to completion, else `:error`."
  @spec result(Task.t()) :: {:ok, term()} | :error
  def result(%Task{metadata: metadata}) when is_map(metadata),
    do: Map.fetch(metadata, @result_metadata_key)

  def result(_other), do: :error

  defp put_result(%{metadata: metadata} = task, result),
    do: %{task | metadata: Map.put(metadata || %{}, @result_metadata_key, result)}

  defp safe_resume(resume_fun, task, frame) do
    resume_fun.(task, frame)
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp pubsub do
    case Application.get_env(:ash_a2a, :cluster_pubsub) do
      {pubsub_name, topic} -> {pubsub_name, topic}
      pubsub_name when is_atom(pubsub_name) -> {pubsub_name, @default_topic}
      _other -> nil
    end
  end
end
