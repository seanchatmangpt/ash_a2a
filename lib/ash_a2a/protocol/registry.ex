defmodule AshA2A.Protocol.Registry do
  @moduledoc """
  Agent discovery registry backed by ETS.

  Stores `{module, card}` entries where `card` is the plain map returned by
  `module.agent_card/0`. The GenServer owns the ETS table and handles writes;
  reads go directly to ETS for concurrent access.

  ## Usage

      {:ok, _pid} = AshA2A.Protocol.Registry.start_link(name: AshA2A.Protocol.Registry)
      :ok = AshA2A.Protocol.Registry.register(AshA2A.Protocol.Registry, MyAgent, MyAgent.agent_card())
      {:ok, card} = AshA2A.Protocol.Registry.get(AshA2A.Protocol.Registry, MyAgent)

  ## Pre-populating on Start

      AshA2A.Protocol.Registry.start_link(
        name: AshA2A.Protocol.Registry,
        agents: [MyApp.PricingAgent, MyApp.RiskAgent]
      )

  Each module's `agent_card/0` is called during `init/1` and the result is
  inserted into the table.
  """

  use GenServer

  # --- Client API ---

  @doc """
  Starts the registry process and creates the underlying ETS table.

  ## Options

  - `:name` — process/table name (required)
  - `:agents` — list of agent modules to pre-populate (default: `[]`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    agents = Keyword.get(opts, :agents, [])
    GenServer.start_link(__MODULE__, {name, agents}, name: name)
  end

  @doc """
  Registers an agent module with its card.

  Overwrites any existing entry for the same module.
  """
  @spec register(GenServer.server(), module(), AshA2A.Protocol.Agent.card()) :: :ok
  def register(registry, module, card) do
    GenServer.call(registry, {:register, module, card})
  end

  @doc """
  Removes an agent module from the registry.
  """
  @spec unregister(GenServer.server(), module()) :: :ok
  def unregister(registry, module) do
    GenServer.call(registry, {:unregister, module})
  end

  @doc """
  Looks up a single agent by module name.

  Reads ETS directly — no message passing.
  """
  @spec get(GenServer.server(), module()) :: {:ok, AshA2A.Protocol.Agent.card()} | {:error, :not_found}
  def get(registry, module) do
    case :ets.lookup(registry, module) do
      [{^module, card}] -> {:ok, card}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Returns all agent modules whose card contains a skill with the given tag.

  Reads ETS directly — no message passing.
  """
  @spec find_by_skill(GenServer.server(), String.t()) :: [module()]
  def find_by_skill(registry, tag) do
    :ets.tab2list(registry)
    |> Enum.filter(fn {_mod, card} ->
      Enum.any?(card.skills, fn skill -> tag in skill.tags end)
    end)
    |> Enum.map(fn {mod, _card} -> mod end)
  end

  @doc """
  Returns all registered `{module, card}` entries.

  Reads ETS directly — no message passing.
  """
  @spec all(GenServer.server()) :: [{module(), AshA2A.Protocol.Agent.card()}]
  def all(registry) do
    :ets.tab2list(registry)
  end

  # --- GenServer callbacks ---

  @impl GenServer
  def init({name, agents}) do
    table = :ets.new(name, [:named_table, :public, :set, read_concurrency: true])

    for mod <- agents do
      :ets.insert(table, {mod, mod.agent_card()})
    end

    {:ok, table}
  end

  @impl GenServer
  def handle_call({:register, module, card}, _from, table) do
    :ets.insert(table, {module, card})
    {:reply, :ok, table}
  end

  def handle_call({:unregister, module}, _from, table) do
    :ets.delete(table, module)
    {:reply, :ok, table}
  end
end
