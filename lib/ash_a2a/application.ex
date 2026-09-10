defmodule AshA2A.Application do
  @moduledoc """
  Starts the real `A2A.AgentSupervisor` (`~/xaas/deps/a2a/lib/a2a/agent_supervisor.ex`)
  so any `AshA2A.Agent`-built agent module configured for this application
  actually runs as a supervised process -- not just as a synchronous
  `AshA2A.Dispatcher.dispatch/3` function call, which is all a caller had
  before this wiring existed.

  `AshA2A` itself is a library extension with no fixed resources of its own,
  so the agent list is read from application config rather than hard-coded:

      config :ash_a2a, :agents, [MyApp.EchoAgent, {MyApp.OrdersAgent, []}]

  Each entry is a module built with `use AshA2A.Agent, resource_or_domain: ...`
  (or any other real `A2A.Agent`), matching `A2A.AgentSupervisor`'s own
  `:agents` option shape (module, or `{module, opts}`). Defaults to `[]` so a
  host application that hasn't configured any agents yet still boots cleanly
  -- but the supervisor itself, and its `A2A.Registry`, are always started,
  so wiring up a real agent is a one-line config change away instead of a
  missing subtree.
  """

  use Application

  @impl true
  def start(_type, _args) do
    agents = Application.get_env(:ash_a2a, :agents, [])

    children = [
      {A2A.AgentSupervisor, agents: agents}
    ]

    opts = [strategy: :one_for_one, name: AshA2A.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
