defmodule SwarmNode.Application do
  @moduledoc """
  Starts cluster membership (`:libcluster`) and the node's HTTP surfaces.
  `ash_a2a` itself declares `mod: {AshA2A.Application, []}` and is started
  first as a dependency (receipt store, broker, GraphLaw host,
  `AshA2A.Protocol.AgentSupervisor` booting `SwarmNode.EchoAgent`).

  Boot gate (DEP-01): before starting anything, `SwarmNode.Health.boot_gate/1`
  runs. With `config :swarm_node, :require_graphlaw` true (set by the prod
  `config/runtime.exs`) and the GraphLaw WASM not loaded, start returns
  `{:error, :graphlaw_unavailable}`; because the release starts this app
  `:permanent`, the node halts instead of serving with degraded admission.

  Children:
    * `Cluster.Supervisor` when libcluster topologies are configured.
    * `Bandit` admin listener (`SwarmNode.AdminRouter`, `:admin_port`, default
      4001) for kubelet probes and the preStop drain -- when
      `config :swarm_node, :admin_http` is true (prod runtime config).
    * `Bandit` A2A listener (`SwarmNode.A2ARouter`) only when
      `config :swarm_node, :a2a_http, enabled: true`.
  """

  use Application

  @impl true
  def start(_type, _args) do
    case SwarmNode.Health.boot_gate() do
      :ok ->
        Supervisor.start_link(children(), strategy: :one_for_one, name: SwarmNode.Supervisor)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def children do
    cluster_children() ++ admin_children() ++ a2a_children()
  end

  defp cluster_children do
    case Application.get_env(:libcluster, :topologies, []) do
      [] -> []
      topologies -> [{Cluster.Supervisor, [topologies, [name: SwarmNode.ClusterSupervisor]]}]
    end
  end

  defp admin_children do
    if Application.get_env(:swarm_node, :admin_http, false) do
      port = Application.get_env(:swarm_node, :admin_port, 4001)
      [Supervisor.child_spec({Bandit, plug: SwarmNode.AdminRouter, port: port}, id: :admin_http)]
    else
      []
    end
  end

  defp a2a_children do
    a2a = Application.get_env(:swarm_node, :a2a_http, [])

    if Keyword.get(a2a, :enabled, false) do
      port = Keyword.get(a2a, :port, 4000)
      [Supervisor.child_spec({Bandit, plug: SwarmNode.A2ARouter, port: port}, id: :a2a_http)]
    else
      []
    end
  end
end
