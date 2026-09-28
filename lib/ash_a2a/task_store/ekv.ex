defmodule AshA2A.TaskStore.Ekv do
  @moduledoc """
  EKV-backed, on-disk `A2A.TaskStore` for `AshA2A.Agent` agents.

  `A2A.Agent` keeps every task in its own GenServer state; without an
  external store an agent crash or restart loses every task. `A2A.Agent`
  already consults a configured `:task_store` on every write
  (`A2A.Agent.State.put_task/2`) and falls back to it on every read miss
  (`A2A.Agent.State.get_task/2`), so starting an agent with this store makes
  task state survive:

    * an agent process crash/restart (the store is a separate supervised
      `EKV` instance, not agent state), and
    * a BEAM/node restart against the same `:data_dir` (EKV persists to disk).

  ## Wiring

      children = [
        AshA2A.TaskStore.Ekv.child_spec(name: MyApp.Tasks, data_dir: "/var/lib/my_app/tasks"),
        {MyAgent, task_store: {AshA2A.TaskStore.Ekv, MyApp.Tasks}}
      ]

  `:data_dir` is required (fail closed): a default under the OS tmp dir
  would silently not survive a host reboot on some platforms, which is the
  exact durability claim this store exists to make. `:cluster_size`
  defaults to `1`; any other `EKV` option is passed through.

  ## Failure semantics

  EKV errors and exits are NOT swallowed. `A2A.Agent.State.put_task/2`
  ignores a store's return value, so returning `{:error, _}` from `put/2`
  would let an agent acknowledge a task it never persisted. `put/2` therefore
  raises `AshA2A.TaskStore.Ekv.WriteError` on any non-`:ok` EKV result, and
  an unavailable EKV instance exits as EKV does -- either crashes the agent
  call, so the caller sees a failure instead of a non-durable success.

  ## At-rest redaction

  `put/2` strips `metadata["a2a.auth"]` (the verified credential) and the
  node-local `metadata[:stream]` before writing. The owner key
  (`"ash_a2a.owner"`) is persisted so ownership checks still hold after a
  restart; a continuation rebinds auth from the current call.

  ## Scope

  This store provides durable task *state*. It does not make in-flight
  dispatch work resumable (that is DurableServer continuity, GitHub issue #8)
  and does not change `A2A.Agent`'s in-memory task map, which is still
  populated in parallel by the `a2a` dependency.
  """

  @behaviour A2A.TaskStore

  defmodule WriteError do
    @moduledoc "Raised when EKV does not acknowledge a task write or delete."
    defexception [:operation, :task_id, :reason]

    @impl true
    def message(%{operation: op, task_id: id, reason: reason}),
      do: "AshA2A.TaskStore.Ekv #{op} of task #{inspect(id)} failed: #{inspect(reason)}"
  end

  @prefix "a2a_task/"
  @not_persisted ["a2a.auth", :stream]

  @doc """
  Child spec for the `EKV` instance backing this store.

  Requires `:name` and `:data_dir`. Raises `ArgumentError` when either is
  missing.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    name =
      Keyword.get(opts, :name) || raise ArgumentError, "#{inspect(__MODULE__)} requires :name"

    data_dir =
      Keyword.get(opts, :data_dir) ||
        raise ArgumentError,
              "#{inspect(__MODULE__)} requires an explicit :data_dir (no tmp-dir default: " <>
                "a durable task store must name where it persists)"

    opts
    |> Keyword.put(:name, name)
    |> Keyword.put(:data_dir, data_dir)
    |> Keyword.put_new(:cluster_size, 1)
    |> EKV.child_spec()
  end

  @doc "The `{module, ref}` tuple to pass as an agent's `:task_store` option."
  @spec task_store(atom()) :: {module(), atom()}
  def task_store(name) when is_atom(name), do: {__MODULE__, name}

  @impl A2A.TaskStore
  def get(name, task_id) when is_binary(task_id) do
    case EKV.get(name, key(task_id)) do
      %A2A.Task{} = task -> {:ok, task}
      nil -> {:error, :not_found}
    end
  end

  @impl A2A.TaskStore
  def put(name, %A2A.Task{id: task_id} = task) when is_binary(task_id) do
    case EKV.put(name, key(task_id), at_rest(task)) do
      :ok -> :ok
      other -> raise WriteError, operation: :put, task_id: task_id, reason: other
    end
  end

  @impl A2A.TaskStore
  def delete(name, task_id) when is_binary(task_id) do
    case EKV.delete(name, key(task_id)) do
      :ok -> :ok
      other -> raise WriteError, operation: :delete, task_id: task_id, reason: other
    end
  end

  @impl A2A.TaskStore
  def list(name, context_id) do
    {:ok, name |> all_tasks() |> Enum.filter(&(&1.context_id == context_id))}
  end

  @impl A2A.TaskStore
  def list_all(name, opts \\ []) do
    name
    |> all_tasks()
    |> A2A.Task.Filter.apply(opts)
  end

  defp all_tasks(name) do
    name
    |> EKV.scan(@prefix)
    |> Stream.map(fn {_key, value, _vsn} -> value end)
    |> Enum.filter(&match?(%A2A.Task{}, &1))
  end

  defp key(task_id), do: @prefix <> task_id

  # Never persist the verified credential (`"a2a.auth"`, which can carry a
  # bearer token) or the node-local `:stream` enumerable. `A2A.Agent` writes
  # a task to the store while it is still `:working`/`:input_required`, i.e.
  # before `AshA2A.Transport.Runtime` drops terminal auth, so without this a
  # killed agent would leave the caller's credential on disk indefinitely.
  # Safe to drop: a continuation rebinds `"a2a.auth"` from the *current*
  # call, and ownership is keyed on `"ash_a2a.owner"`, which is kept.
  defp at_rest(%A2A.Task{metadata: metadata} = task) when is_map(metadata),
    do: %{task | metadata: Map.drop(metadata, @not_persisted)}

  defp at_rest(task), do: task
end
