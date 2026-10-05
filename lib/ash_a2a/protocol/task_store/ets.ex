defmodule AshA2A.Protocol.TaskStore.ETS do
  @moduledoc """
  ETS-backed task store implementation.

  Uses a named ETS table for storage. The store reference is the table name atom.
  Suitable for single-node, concurrent access.

  Push notification configs are kept in a second table, `:"\#{name}_push"`,
  created alongside the first. They cannot share the task table: `list/2` and
  `list_all/2` scan every row and treat it as a task, so a config row would
  crash both.

  ## Usage

      {:ok, _pid} = AshA2A.Protocol.TaskStore.ETS.start_link(name: :my_tasks)
      :ok = AshA2A.Protocol.TaskStore.ETS.put(:my_tasks, task)
      {:ok, task} = AshA2A.Protocol.TaskStore.ETS.get(:my_tasks, "tsk-abc123")

  ## With an Agent

      MyAgent.start_link(task_store: {AshA2A.Protocol.TaskStore.ETS, :my_tasks})
  """

  use GenServer

  @behaviour AshA2A.Protocol.TaskStore

  @doc """
  Starts the ETS task store process which creates the underlying table.

  ## Options

  - `:name` — the table/process name (required)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, name, name: name)
  end

  @impl AshA2A.Protocol.TaskStore
  def get(table, task_id) do
    case :ets.lookup(table, task_id) do
      [{^task_id, task}] -> {:ok, task}
      [] -> {:error, :not_found}
    end
  end

  @impl AshA2A.Protocol.TaskStore
  def put(table, %AshA2A.Protocol.Task{} = task) do
    :ets.insert(table, {task.id, task})
    :ok
  end

  @impl AshA2A.Protocol.TaskStore
  def delete(table, task_id) do
    :ets.delete(table, task_id)
    :ok
  end

  @impl AshA2A.Protocol.TaskStore
  def list(table, context_id) do
    tasks =
      :ets.tab2list(table)
      |> Enum.filter(fn {_id, task} -> task.context_id == context_id end)
      |> Enum.map(fn {_id, task} -> task end)

    {:ok, tasks}
  end

  @impl AshA2A.Protocol.TaskStore
  def list_all(table, opts \\ []) do
    :ets.tab2list(table)
    |> Enum.map(fn {_id, task} -> task end)
    |> AshA2A.Protocol.Task.Filter.apply(opts)
  end

  # --- Push notification config callbacks ---

  @impl AshA2A.Protocol.TaskStore
  def set_push_config(table, %AshA2A.Protocol.PushNotificationConfig{} = config) do
    :ets.insert(push_table(table), {{config.task_id, config.id}, config})
    {:ok, config}
  end

  @impl AshA2A.Protocol.TaskStore
  def get_push_config(table, task_id, config_id) do
    key = {task_id, config_id}

    case :ets.lookup(push_table(table), key) do
      [{^key, config}] -> {:ok, config}
      [] -> {:error, :not_found}
    end
  end

  @impl AshA2A.Protocol.TaskStore
  def list_push_configs(table, task_id) do
    configs =
      push_table(table)
      |> :ets.match_object({{task_id, :_}, :_})
      |> Enum.map(fn {_key, config} -> config end)

    {:ok, configs}
  end

  @impl AshA2A.Protocol.TaskStore
  def delete_push_config(table, task_id, config_id) do
    :ets.delete(push_table(table), {task_id, config_id})
    :ok
  end

  # --- GenServer callbacks ---

  @impl GenServer
  def init(name) do
    table = :ets.new(name, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(push_table(name), [:named_table, :public, :set, read_concurrency: true])
    {:ok, table}
  end

  defp push_table(name), do: :"#{name}_push"
end
