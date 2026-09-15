defmodule SwarmNode.Application do
  @moduledoc """
  Starts `:libcluster`'s topology supervisor. `ash_a2a` itself already
  declares `mod: {AshA2A.Application, []}` (`../mix.exs`) and starts
  `A2A.AgentSupervisor` (booting `SwarmNode.EchoAgent`, per
  `config :ash_a2a, agents:` in `config/runtime.exs`) as part of being an
  OTP application dependency -- this application's own supervisor only
  needs to add the one real thing `ash_a2a` does not own: real cluster
  membership.
  """

  use Application

  @impl true
  def start(_type, _args) do
    topologies = Application.get_env(:libcluster, :topologies, [])

    children =
      if topologies == [] do
        []
      else
        [{Cluster.Supervisor, [topologies, [name: SwarmNode.ClusterSupervisor]]}]
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: SwarmNode.Supervisor)
  end
end
