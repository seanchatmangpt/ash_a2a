defmodule AshA2A.TaskStore.Ash do
  @moduledoc """
  Ash-resource-backed `AshA2A.Protocol.TaskStore` (a2a-python
  `DatabaseTaskStore` parity).

  Rows live in `AshA2A.TaskStore.Ash.TaskRow` with columns `task_id`, `owner`,
  `context_id`, `status_state`, `last_updated`, `protocol_version`, `version`
  and `payload` (the task struct, `:term`), plus a `namespace` column holding
  the store `ref`. Push configs live in `AshA2A.TaskStore.Ash.PushRow`.

  Data layer: `Ash.DataLayer.Ets`. mix.exs lists no `ash_postgres` or
  `ash_sqlite`, so the resources use the ETS layer with the same shape a SQL
  layer would need; durability is therefore node-lifetime only.

  The ref is any string or atom naming the namespace. No process is needed.

  `put/2` is an upsert that bumps `version`. `put/3` takes
  `expected_version:` (`0` means "must not exist") and returns
  `{:error, :version_conflict}` on mismatch. Writes are serialized per task
  with `:global.trans/2`.

  Like the EKV store, `"a2a.auth"` and `:stream` metadata are not persisted.
  Write failures raise `AshA2A.TaskStore.Ash.WriteError`.
  """

  @behaviour AshA2A.Protocol.TaskStore

  require Ash.Query

  alias AshA2A.Protocol.{PushNotificationConfig, Task}
  alias AshA2A.TaskStore.Ash.{PushRow, TaskRow}

  @protocol_version "1.0"
  @not_persisted ["a2a.auth", :stream]

  defmodule WriteError do
    @moduledoc "Raised when an Ash write for the task store fails."
    defexception [:operation, :task_id, :reason]

    @impl true
    def message(%{operation: op, task_id: id, reason: reason}),
      do: "AshA2A.TaskStore.Ash #{op} of #{inspect(id)} failed: #{inspect(reason)}"
  end

  @doc "The `{module, ref}` tuple to pass as an agent's `:task_store` option."
  @spec task_store(atom() | String.t()) :: {module(), atom() | String.t()}
  def task_store(ref), do: {__MODULE__, ref}

  @impl AshA2A.Protocol.TaskStore
  def get(ref, task_id) when is_binary(task_id) do
    case fetch(ref, task_id) do
      %TaskRow{payload: %Task{} = task} -> {:ok, task}
      _ -> {:error, :not_found}
    end
  end

  @doc "Current optimistic-concurrency version of a task, or `0` when absent."
  @spec version(term(), String.t()) :: non_neg_integer()
  def version(ref, task_id) do
    case fetch(ref, task_id) do
      %TaskRow{version: v} -> v
      nil -> 0
    end
  end

  @impl AshA2A.Protocol.TaskStore
  def put(ref, %Task{} = task), do: do_put(ref, task, :any)

  @doc "Upsert guarded by `expected_version:` (`0` = must not exist yet)."
  @spec put(term(), Task.t(), keyword()) :: :ok | {:error, :version_conflict}
  def put(ref, %Task{} = task, opts) when is_list(opts),
    do: do_put(ref, task, Keyword.get(opts, :expected_version, :any))

  @impl AshA2A.Protocol.TaskStore
  def delete(ref, task_id) when is_binary(task_id) do
    with_lock(ref, task_id, fn ->
      case fetch(ref, task_id) do
        nil -> :ok
        row -> destroy!(row, :delete, task_id)
      end
    end)
  end

  @impl AshA2A.Protocol.TaskStore
  def list(ref, context_id) do
    {:ok, ref |> all_tasks() |> Enum.filter(&(&1.context_id == context_id))}
  end

  @impl AshA2A.Protocol.TaskStore
  def list_all(ref, opts \\ []) do
    ref |> all_tasks() |> Task.Filter.apply(opts)
  end

  # --- push configs ---

  @impl AshA2A.Protocol.TaskStore
  def set_push_config(ref, %PushNotificationConfig{} = config) do
    ns = ns(ref)

    with_lock(ref, {config.task_id, config.id}, fn ->
      case fetch_push(ref, config.task_id, config.id) do
        nil ->
          PushRow
          |> Ash.Changeset.for_create(:create, %{
            namespace: ns,
            task_id: config.task_id,
            config_id: config.id,
            payload: config
          })
          |> Ash.create(authorize?: false)
          |> ok_or_raise(:set_push_config, config.task_id)

        row ->
          row
          |> Ash.Changeset.for_update(:update, %{payload: config})
          |> Ash.update(authorize?: false)
          |> ok_or_raise(:set_push_config, config.task_id)
      end
    end)

    {:ok, config}
  end

  @impl AshA2A.Protocol.TaskStore
  def get_push_config(ref, task_id, config_id) do
    case fetch_push(ref, task_id, config_id) do
      %PushRow{payload: %PushNotificationConfig{} = c} -> {:ok, c}
      _ -> {:error, :not_found}
    end
  end

  @impl AshA2A.Protocol.TaskStore
  def list_push_configs(ref, task_id) do
    ns = ns(ref)

    configs =
      PushRow
      |> Ash.Query.filter(namespace == ^ns and task_id == ^task_id)
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.payload)

    {:ok, configs}
  end

  @impl AshA2A.Protocol.TaskStore
  def delete_push_config(ref, task_id, config_id) do
    case fetch_push(ref, task_id, config_id) do
      nil -> :ok
      row -> destroy!(row, :delete_push_config, task_id)
    end
  end

  # --- internals ---

  defp do_put(ref, %Task{id: task_id} = task, expected) when is_binary(task_id) do
    with_lock(ref, task_id, fn ->
      existing = fetch(ref, task_id)
      current = if existing, do: existing.version, else: 0

      if expected != :any and expected != current do
        {:error, :version_conflict}
      else
        attrs = columns(task, current + 1)

        case existing do
          nil ->
            TaskRow
            |> Ash.Changeset.for_create(
              :create,
              Map.merge(attrs, %{namespace: ns(ref), task_id: task_id})
            )
            |> Ash.create(authorize?: false)
            |> ok_or_raise(:put, task_id)

          row ->
            row
            |> Ash.Changeset.for_update(:update, attrs)
            |> Ash.update(authorize?: false)
            |> ok_or_raise(:put, task_id)
        end

        :ok
      end
    end)
  end

  defp columns(%Task{} = task, version) do
    stored = at_rest(task)
    status = task.status

    %{
      owner: owner(task),
      context_id: task.context_id,
      status_state: status && status.state && Atom.to_string(status.state),
      last_updated: status && status.timestamp,
      protocol_version: @protocol_version,
      version: version,
      payload: stored
    }
  end

  defp owner(%Task{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, AshA2A.Transport.Runtime.owner_key()) do
      o when is_binary(o) -> o
      nil -> nil
      other -> inspect(other)
    end
  end

  defp owner(_), do: nil

  defp at_rest(%Task{metadata: m} = task) when is_map(m),
    do: %{task | metadata: Map.drop(m, @not_persisted)}

  defp at_rest(task), do: task

  defp fetch(ref, task_id) do
    ns = ns(ref)

    TaskRow
    |> Ash.Query.filter(namespace == ^ns and task_id == ^task_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp fetch_push(ref, task_id, config_id) do
    ns = ns(ref)

    PushRow
    |> Ash.Query.filter(namespace == ^ns and task_id == ^task_id and config_id == ^config_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp all_tasks(ref) do
    ns = ns(ref)

    TaskRow
    |> Ash.Query.filter(namespace == ^ns)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.payload)
    |> Enum.filter(&match?(%Task{}, &1))
  end

  defp destroy!(row, op, id) do
    row |> Ash.destroy(authorize?: false) |> ok_or_raise(op, id)
    :ok
  end

  defp ok_or_raise({:ok, v}, _op, _id), do: v
  defp ok_or_raise(:ok, _op, _id), do: :ok

  defp ok_or_raise({:error, reason}, op, id),
    do: raise(WriteError, operation: op, task_id: id, reason: reason)

  defp with_lock(ref, key, fun), do: :global.trans({{__MODULE__, ns(ref), key}, self()}, fun)

  defp ns(ref) when is_binary(ref), do: ref
  defp ns(ref), do: inspect(ref)
end
