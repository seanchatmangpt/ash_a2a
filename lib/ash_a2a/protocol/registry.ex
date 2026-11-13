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
  - `:disclose` — `(card, principal -> card | nil)` selective-disclosure
    callback applied by `list_for/3` and `get_for/3` (default: none)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    agents = Keyword.get(opts, :agents, [])
    disclose = Keyword.get(opts, :disclose)
    GenServer.start_link(__MODULE__, {name, agents, disclose}, name: name)
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
    registry
    |> find(%{tag: tag})
    |> Enum.map(fn {mod, _card} -> mod end)
  end

  @doc """
  Returns `{module, card}` entries matching every given criterion (AND).

  Criteria (all optional; unknown keys are ignored):

    * `:skill_id` -- a skill with this `id`
    * `:tag` -- a skill carrying this tag
    * `:provider` -- provider organization (or the provider map's `:organization`)
    * `:capabilities` -- map such as `%{streaming: true}`; every pair must equal
      the card's capability value
    * `:input_mode` / `:output_mode` -- listed in the card's default modes
      (or in any skill's modes)

  Cards lacking a field never match a criterion on it; they never crash.
  Reads ETS directly.
  """
  @spec find(GenServer.server(), map() | keyword()) :: [{module(), AshA2A.Protocol.Agent.card()}]
  def find(registry, criteria \\ %{}) do
    criteria = Map.new(criteria)

    registry
    |> all()
    |> Enum.filter(fn {_mod, card} -> matches?(card, criteria) end)
  end

  @doc """
  Like `find/2` but each matching card is passed through the registry's
  `:disclose` callback (`(card, principal -> card | nil)`) for `principal`.
  A callback returning `nil` hides the agent from that caller. Without a
  callback the card is returned unchanged.
  """
  @spec list_for(GenServer.server(), term(), map() | keyword()) ::
          [{module(), AshA2A.Protocol.Agent.card()}]
  def list_for(registry, principal, criteria \\ %{}) do
    registry
    |> find(criteria)
    |> Enum.flat_map(fn {mod, card} ->
      case disclose(registry, card, principal) do
        nil -> []
        shown -> [{mod, shown}]
      end
    end)
  end

  @doc "Single-agent lookup with per-principal disclosure; hidden == not found."
  @spec get_for(GenServer.server(), module(), term()) ::
          {:ok, AshA2A.Protocol.Agent.card()} | {:error, :not_found}
  def get_for(registry, module, principal) do
    with {:ok, card} <- get(registry, module),
         shown when not is_nil(shown) <- disclose(registry, card, principal) do
      {:ok, shown}
    else
      _ -> {:error, :not_found}
    end
  end

  defp disclose(registry, card, principal) do
    case :persistent_term.get({__MODULE__, :disclose, registry}, nil) do
      fun when is_function(fun, 2) -> fun.(card, principal)
      _ -> card
    end
  end

  defp matches?(card, criteria) do
    Enum.all?(criteria, fn {key, want} -> match_one?(card, key, want) end)
  end

  defp match_one?(card, :skill_id, id), do: Enum.any?(skills(card), &(fetch(&1, :id) == id))

  defp match_one?(card, :tag, tag),
    do: Enum.any?(skills(card), fn s -> tag in List.wrap(fetch(s, :tags)) end)

  defp match_one?(card, :provider, want) do
    case fetch(card, :provider) do
      %{} = p -> want in [fetch(p, :organization), fetch(p, :name)]
      p when is_binary(p) -> p == want
      _ -> false
    end
  end

  defp match_one?(card, :capabilities, want) do
    caps = fetch(card, :capabilities)

    is_map(caps) and Enum.all?(want, fn {k, v} -> fetch(caps, k) == v end)
  end

  defp match_one?(card, :input_mode, mode),
    do: mode_match?(card, :default_input_modes, :input_modes, mode)

  defp match_one?(card, :output_mode, mode),
    do: mode_match?(card, :default_output_modes, :output_modes, mode)

  defp match_one?(_card, _unknown, _want), do: true

  defp mode_match?(card, card_key, skill_key, mode) do
    mode in List.wrap(fetch(card, card_key)) or
      Enum.any?(skills(card), fn s -> mode in List.wrap(fetch(s, skill_key)) end)
  end

  defp skills(card) do
    case fetch(card, :skills) do
      list when is_list(list) -> Enum.filter(list, &is_map/1)
      _ -> []
    end
  end

  defp fetch(%{} = map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp fetch(_other, _key), do: nil

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
  def init({name, agents, disclose}) do
    :persistent_term.put({__MODULE__, :disclose, name}, disclose)

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
