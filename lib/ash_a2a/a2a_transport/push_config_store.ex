defmodule AshA2A.A2ATransport.PushConfigStore do
  @moduledoc """
  Store for A2A `TaskPushNotificationConfig` records, keyed by
  `{task_id, config_id}`.

  This default implementation is a GenServer-owned `:protected` ETS table:
  node-local and not durable across restarts (see
  `docs/reference/a2a-spec-version-mapping.md`, "Durability"). Writes go
  through the owning process so a crashed caller cannot corrupt the table;
  reads are direct ETS lookups.

  Records are plain maps:

      %{id: String.t(), task_id: String.t(), url: String.t(),
        token: String.t() | nil, authentication: map() | nil,
        inserted_at: DateTime.t()}

  A per-task ceiling (`:max_per_task`, default 16) bounds how many configs a
  single caller can attach to one task; exceeding it is the typed refusal
  `:refused_push_config_limit`.
  """

  use GenServer

  @type config :: %{
          required(:id) => String.t(),
          required(:task_id) => String.t(),
          required(:url) => String.t(),
          required(:token) => String.t() | nil,
          required(:authentication) => map() | nil,
          required(:inserted_at) => DateTime.t()
        }

  @doc false
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    true = is_atom(name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Stores (inserts or replaces) `config` for its task."
  @spec put(GenServer.server(), map()) :: {:ok, config()} | {:error, atom(), String.t()}
  def put(store, config), do: GenServer.call(store, {:put, config})

  @doc "Fetches one config, or the first config of the task when `config_id` is nil."
  @spec get(GenServer.server(), String.t(), String.t() | nil) :: {:ok, config()} | :error
  def get(store, task_id, nil) do
    case list(store, task_id) do
      [first | _] -> {:ok, first}
      [] -> :error
    end
  end

  def get(store, task_id, config_id) do
    case :ets.lookup(table(store), {task_id, config_id}) do
      [{_, config}] -> {:ok, config}
      [] -> :error
    end
  end

  @doc "Lists every config of `task_id`, ordered by insertion."
  @spec list(GenServer.server(), String.t()) :: [config()]
  def list(store, task_id) do
    store
    |> table()
    |> :ets.match_object({{task_id, :_}, :_})
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(& &1.inserted_at, DateTime)
  end

  @doc "Deletes one config. Returns `:error` when it did not exist."
  @spec delete(GenServer.server(), String.t(), String.t()) :: :ok | :error
  def delete(store, task_id, config_id), do: GenServer.call(store, {:delete, task_id, config_id})

  # The table is a named table carrying the store's registered (atom) name.
  defp table(store) when is_atom(store), do: store

  # -- server -------------------------------------------------------------------

  @impl true
  def init(opts) do
    table =
      :ets.new(Keyword.fetch!(opts, :name), [
        :set,
        :protected,
        :named_table,
        read_concurrency: true
      ])

    {:ok, %{table: table, max_per_task: Keyword.get(opts, :max_per_task, 16)}}
  end

  @impl true
  def handle_call({:put, config}, _from, state) do
    key = {config.task_id, config.id}
    existing = :ets.match_object(state.table, {{config.task_id, :_}, :_})
    replacing? = :ets.member(state.table, key)

    if not replacing? and length(existing) >= state.max_per_task do
      {:reply,
       {:error, :refused_push_config_limit,
        "task #{config.task_id} already has #{state.max_per_task} push configs"}, state}
    else
      record = Map.put_new(config, :inserted_at, DateTime.utc_now())
      true = :ets.insert(state.table, {key, record})
      {:reply, {:ok, record}, state}
    end
  end

  def handle_call({:delete, task_id, config_id}, _from, state) do
    key = {task_id, config_id}

    if :ets.member(state.table, key) do
      :ets.delete(state.table, key)
      {:reply, :ok, state}
    else
      {:reply, :error, state}
    end
  end

  @doc false
  # S42 refusal totality: every typed refusal this module returns is classified.
  def __sa2a_refusal_codes__, do: %{refused_push_config_limit: :refused_bounds}
end
