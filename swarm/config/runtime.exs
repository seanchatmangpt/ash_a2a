import Config

# Real libcluster Kubernetes.DNS topology -- the *headless* Service
# (spec.clusterIP: None, rendered via ash_a2a's own k8s/headless-service.yaml,
# see k8s/README.md) resolves to one A record per real, ready pod.
# `:application_name` must match the
# real node basename this release is started with (RELEASE_NODE below),
# and `:service` must match the headless Service's real metadata.name in
# the same namespace this pod runs in.
if System.get_env("SWARM_K8S_SERVICE") do
  config :libcluster,
    topologies: [
      swarm: [
        strategy: Cluster.Strategy.Kubernetes.DNS,
        config: [
          service: System.fetch_env!("SWARM_K8S_SERVICE"),
          application_name: "swarm_node",
          polling_interval: 5_000
        ]
      ]
    ]
end

# `AshA2A.Agent.__using__/1`'s generated module is registered under the
# module's own name (`use A2A.Agent` default), and `A2A.AgentSupervisor`
# starts it as a real supervised child -- see `SwarmNode.Application`.
config :ash_a2a, agents: [SwarmNode.EchoAgent]
