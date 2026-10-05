# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Cluster.Checkpoint do
  @moduledoc """
  Durable landing of an in-flight task's execution frame at drain time.

  The execution call frame and pending steps of a task that cannot finish
  inside the drain window are serialized into the same durable storage the
  task already lives in -- `AshA2A.TaskStore.Ekv`'s on-disk EKV instance
  (whose `put/2` raises on any non-`:ok` EKV acknowledgement, so a failed
  landing is a crash, never a silent non-durable success).

  The landed record is a real `AshA2A.Protocol.Task` whose metadata carries
  the `"a2a.cluster.checkpoint"` envelope:

      %{
        "version" => 1,
        "frame" => term(),
        "sequence" => pos_integer(),
        "checkpointed_at" => %DateTime{},
        "source_node" => node(),
        "reason" => :drain_deadline,
        "drain_manager" => atom()
      }

  A surviving peer rehydrates the task through `AshA2A.Cluster.Handover`.
  """

  alias AshA2A.Protocol.Task

  @version 1
  @metadata_key "a2a.cluster.checkpoint"

  @type store :: {module(), term()}

  @doc "Metadata key under which the checkpoint envelope is stored."
  @spec metadata_key() :: String.t()
  def metadata_key, do: @metadata_key

  @doc """
  Lands `frame` for `task_id` durably, failing closed.

  Reads the task from the store (a task admitted before dispatch is already
  there; a task the store has never seen is synthesized in `:working` so the
  frame is never lost for lack of a prior record), stamps the checkpoint
  envelope into its metadata, and writes through the store. Any store `put`
  failure raises -- the drain must not report a checkpoint it does not have.
  """
  @spec land(store(), String.t(), term(), keyword()) :: Task.t()
  def land(store, task_id, frame, opts \\ []) when is_binary(task_id) do
    {store_mod, store_ref} = store
    task = fetch_or_synthesize(store_mod, store_ref, task_id, opts)

    sequence = Keyword.get(opts, :sequence, 1)

    envelope = %{
      "version" => @version,
      "frame" => frame,
      "sequence" => sequence,
      "checkpointed_at" => DateTime.utc_now(),
      "source_node" => Keyword.get(opts, :source_node, node()),
      "reason" => Keyword.get(opts, :reason, :drain_deadline),
      "drain_manager" => Keyword.get(opts, :drain_manager, nil)
    }

    checkpointed = %{
      task
      | status: AshA2A.Protocol.Task.Status.new(:working),
        metadata:
          Map.put(task.metadata || %{}, @metadata_key, envelope)
          |> Map.drop(["a2a.auth", :stream])
    }

    :ok = store_mod.put(store_ref, checkpointed)
    checkpointed
  end

  @doc "`true` when `task` carries a drain checkpoint envelope."
  @spec checkpointed?(Task.t()) :: boolean()
  def checkpointed?(%Task{metadata: metadata}) when is_map(metadata),
    do: Map.has_key?(metadata, @metadata_key)

  def checkpointed?(_other), do: false

  @doc "The checkpoint envelope of a checkpointed task, or `:error`."
  @spec envelope(Task.t()) :: {:ok, map()} | :error
  def envelope(%Task{metadata: metadata}) when is_map(metadata),
    do: Map.fetch(metadata, @metadata_key)

  def envelope(_other), do: :error

  @doc """
  Removes the checkpoint envelope from a rehydrated task's metadata (the
  rehydrating node calls this when it writes the completed task back).
  """
  @spec cleared(Task.t()) :: Task.t()
  def cleared(%Task{metadata: metadata} = task) when is_map(metadata),
    do: %{task | metadata: Map.delete(metadata, @metadata_key)}

  def cleared(task), do: task

  defp fetch_or_synthesize(store_mod, store_ref, task_id, opts) do
    case store_mod.get(store_ref, task_id) do
      {:ok, %Task{} = task} ->
        task

      {:error, :not_found} ->
        Task.new(
          id: task_id,
          context_id: Keyword.get(opts, :context_id),
          metadata: Keyword.get(opts, :metadata, %{})
        )
        |> then(&%{&1 | status: AshA2A.Protocol.Task.Status.new(:working)})
    end
  end
end
