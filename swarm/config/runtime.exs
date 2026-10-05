import Config

# libcluster topology over the *headless* Service (k8s/headless-service.yaml,
# publishNotReadyAddresses: true so peers find each other before Ready).
#
#   * SWARM_K8S_SERVICE + SWARM_K8S_NAMESPACE -> Kubernetes.DNSSRV: node names
#     swarm_node@<pod>.<service>.<namespace>.svc.cluster.local, i.e. the stable
#     StatefulSet hostnames RELEASE_NODE uses (k8s/deployment.yaml), so a
#     rescheduled pod rejoins under the same identity.
#   * SWARM_K8S_SERVICE only -> Kubernetes.DNS: node names swarm_node@<pod IP>.
#   * Neither -> no topology: the node runs UNCLUSTERED.
case {System.get_env("SWARM_K8S_SERVICE"), System.get_env("SWARM_K8S_NAMESPACE")} do
  {nil, _} ->
    :ok

  {service, namespace} when is_binary(namespace) and namespace != "" ->
    config :libcluster,
      topologies: [
        swarm: [
          strategy: Cluster.Strategy.Kubernetes.DNSSRV,
          config: [
            service: service,
            namespace: namespace,
            application_name: "swarm_node",
            polling_interval: 5_000
          ]
        ]
      ]

  {service, _} ->
    config :libcluster,
      topologies: [
        swarm: [
          strategy: Cluster.Strategy.Kubernetes.DNS,
          config: [service: service, application_name: "swarm_node", polling_interval: 5_000]
        ]
      ]
end

# `AshA2A.Agent.__using__/1`'s generated module is registered under the
# module's own name, and `AshA2A.Protocol.AgentSupervisor` starts it as a supervised child.
config :ash_a2a, agents: [SwarmNode.EchoAgent]

# --- Production: fail closed (DEP-02 / DEP-03 / DEP-04 / DEP-12) -------------
#
# Every production-critical ash_a2a key is set here from the environment, and
# a missing or malformed variable RAISES, so the release refuses to boot rather
# than silently falling back to the library's dev defaults (per-pod in-memory
# receipt store, no authority broker, inert release gate, no receipt binding
# key, per-node random standing-ledger key, state under System.tmp_dir!()).
# See docs/reference/configuration.md "Production checklist".
if config_env() == :prod do
  env! = fn name ->
    case System.get_env(name) do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        raise ArgumentError,
              "environment variable #{name} is required in production (see " <>
                "docs/reference/configuration.md, Production checklist)"
    end
  end

  abs_dir! = fn name ->
    dir = env!.(name)

    if Path.type(dir) != :absolute do
      raise ArgumentError, "#{name} must be an absolute path, got: #{inspect(dir)}"
    end

    dir
  end

  pos_int! = fn name ->
    case Integer.parse(env!.(name)) do
      {n, ""} when n > 0 -> n
      _ -> raise ArgumentError, "#{name} must be a positive integer"
    end
  end

  key! = fn name, min_bytes, max_bytes ->
    case Base.decode64(env!.(name)) do
      {:ok, key} when byte_size(key) >= min_bytes and byte_size(key) <= max_bytes ->
        key

      {:ok, key} ->
        raise ArgumentError,
              "#{name} must decode to #{min_bytes}..#{max_bytes} bytes, got #{byte_size(key)}"

      :error ->
        raise ArgumentError, "#{name} must be base64"
    end
  end

  bool! = fn name, default ->
    case System.get_env(name, default) do
      "true" -> true
      "false" -> false
      other -> raise ArgumentError, "#{name} must be true or false, got: #{inspect(other)}"
    end
  end

  ekv_cluster_size = pos_int!.("ASH_A2A_EKV_CLUSTER_SIZE")

  # Readiness peer floor: an EKV write needs a majority (div(n, 2) + 1) of
  # cluster_size voters, i.e. this node plus div(n, 2) peers. A node with fewer
  # connected peers cannot commit a receipt, so it must not report Ready. The
  # floor is the default and the minimum; a lower SWARM_MIN_PEERS refuses boot.
  quorum_peers = div(ekv_cluster_size, 2)

  min_peers =
    case Integer.parse(System.get_env("SWARM_MIN_PEERS", Integer.to_string(quorum_peers))) do
      {n, ""} when n >= quorum_peers ->
        n

      _ ->
        raise ArgumentError,
              "SWARM_MIN_PEERS must be an integer >= #{quorum_peers} (the EKV write " <>
                "quorum peers for ASH_A2A_EKV_CLUSTER_SIZE=#{ekv_cluster_size})"
    end

  config :ash_a2a,
    receipt_store: AshA2A.ReceiptStore.Ekv,
    receipt_store_ekv_opts: [
      data_dir: abs_dir!.("ASH_A2A_RECEIPT_DATA_DIR"),
      cluster_size: ekv_cluster_size
    ],
    authority_broker:
      {AshA2A.Authority.Broker.Ekv,
       data_dir: abs_dir!.("ASH_A2A_BROKER_DATA_DIR"), cluster_size: ekv_cluster_size},
    receipt_outbox_dir: abs_dir!.("ASH_A2A_OUTBOX_DIR"),
    capability_release_mode: :strict,
    capability_release_closure:
      SwarmNode.ReleaseClosure.load!(
        env!.("ASH_A2A_CAPABILITY_RELEASE_MANIFEST"),
        env!.("ASH_A2A_CAPABILITY_RELEASE_DIGEST"),
        standing_artifacts_dir: abs_dir!.("ASH_A2A_STANDING_ARTIFACTS_DIR")
      ),
    receipt_binding_key: key!.("ASH_A2A_RECEIPT_BINDING_KEY", 32, 1024),
    standing_ledger_key: key!.("ASH_A2A_STANDING_LEDGER_KEY", 32, 32)

  config :swarm_node,
    require_graphlaw: bool!.("SWARM_REQUIRE_GRAPHLAW", "true"),
    min_peers: min_peers,
    drain_ms: String.to_integer(System.get_env("SWARM_DRAIN_MS", "15000")),
    admin_http: true,
    admin_port: String.to_integer(System.get_env("SWARM_ADMIN_PORT", "4001")),
    a2a_http: [
      enabled: bool!.("SWARM_A2A_HTTP", "false"),
      port: String.to_integer(System.get_env("SWARM_A2A_PORT", "4000")),
      base_url: System.get_env("SWARM_A2A_BASE_URL")
    ]

  # Structured JSON logs, one object per line (DEP-12).
  config :logger, level: String.to_existing_atom(System.get_env("SWARM_LOG_LEVEL", "info"))

  config :logger, :default_handler,
    formatter:
      {SwarmNode.JsonLogFormatter,
       %{metadata: [:request_id, :command_id, :receipt_id, :task_id, :node]}}
end
