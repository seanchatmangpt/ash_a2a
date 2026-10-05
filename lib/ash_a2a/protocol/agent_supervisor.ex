defmodule AshA2A.Protocol.AgentSupervisor do
  @moduledoc """
  Supervisor for a fleet of A2A agents with an integrated registry.

  Starts an `AshA2A.Protocol.Registry` followed by each agent as a child, all under a
  `:one_for_one` strategy. Agents are independent — one crashing won't take
  down others.

  ## Usage

      children = [
        {AshA2A.Protocol.AgentSupervisor, agents: [
          MyApp.PricingAgent,
          {MyApp.RiskAgent, task_store: {AshA2A.Protocol.TaskStore.ETS, :risk_tasks}}
        ]}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  ## Options

  - `:agents` — list of agent modules or `{module, opts}` tuples (required)
  - `:name` — supervisor name (default: `AshA2A.Protocol.AgentSupervisor`)
  - `:registry` — registry name (default: `AshA2A.Protocol.Registry`)
  - `:agent_opts` — default options merged into every agent (default: `[]`)
  """

  use Supervisor

  @doc """
  Starts the agent supervisor.

  See module documentation for available options.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    agents = Keyword.fetch!(opts, :agents)
    name = Keyword.get(opts, :name, __MODULE__)
    registry = Keyword.get(opts, :registry, AshA2A.Protocol.Registry)
    agent_opts = Keyword.get(opts, :agent_opts, [])

    Supervisor.start_link(
      __MODULE__,
      {agents, registry, agent_opts},
      name: name
    )
  end

  @impl Supervisor
  def init({agents, registry, agent_opts}) do
    {agent_modules, agent_children} =
      Enum.reduce(agents, {[], []}, fn entry, {mods, children} ->
        {mod, per_opts} = normalize_agent(entry)
        opts = Keyword.merge(agent_opts, per_opts)
        {[mod | mods], [{mod, opts} | children]}
      end)

    agent_modules = Enum.reverse(agent_modules)
    agent_children = Enum.reverse(agent_children)

    registry_child = {AshA2A.Protocol.Registry, name: registry, agents: agent_modules}

    children = [registry_child | agent_children]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp normalize_agent({mod, opts}) when is_atom(mod) and is_list(opts), do: {mod, opts}
  defp normalize_agent(mod) when is_atom(mod), do: {mod, []}
end
