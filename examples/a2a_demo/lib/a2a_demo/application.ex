defmodule A2aDemo.Application do
  @moduledoc """
  Boots the demo stack: ash_a2a's own application (receipt store, package
  store, agent supervisor) starts first as a dependency application, then
  the demo supervision tree -- the InMemory authority broker, the demo
  agent GenServer, the boot grant, the Bandit listener on `A2A_DEMO_PORT`
  (default 4010), and the gRPC endpoint on `A2A_DEMO_GRPC_PORT` (default
  4011) serving `lf.a2a.v1.A2AService` through `A2aDemo.GrpcHandler`.

  `A2A_DEMO_TCK=1` additionally opts the agent into unauthenticated
  callers (the A2A TCK drives the SUT without credentials); the router
  drops its auth plug for the run (A2aDemo.Router).
  """

  use Application

  @impl true
  def start(_type, _args) do
    port = String.to_integer(System.get_env("A2A_DEMO_PORT") || "4010")
    grpc_port = String.to_integer(System.get_env("A2A_DEMO_GRPC_PORT") || "4011")
    base_url = "http://localhost:#{port}"

    if System.get_env("A2A_DEMO_TCK") == "1" do
      Application.put_env(:ash_a2a, :require_authenticated_caller, false)
    end

    # The gRPC mount delegates to the same dispatcher as the HTTP mounts:
    # handler is the `AshA2A.Protocol.JSONRPC` behaviour implementation and
    # ctx carries the agent + the default A2ATransport (whose TaskEvents
    # registry the gRPC server-streaming RPCs subscribe to).
    Application.put_env(:ash_a2a, AshA2A.Transport.GRPC.Server,
      handler: A2aDemo.GrpcHandler,
      ctx: %{agent: A2aDemo.Agent, opts: [], transport: AshA2A.A2ATransport.default_name(), principal: :anonymous}
    )

    children = [
      {AshA2A.Authority.Broker.InMemory, []},
      {A2aDemo.Agent, []},
      %{
        id: A2aDemo.Grants,
        start:
          {Task, :start_link,
           [
             fn ->
               :ok = A2aDemo.Auth.issue_demo_grants()
               :ok
             end
           ]},
        restart: :transient
      },
      {Bandit,
       plug: {A2aDemo.Router, base_url: base_url},
       port: port,
       thousand_island_options: [read_timeout: 30_000]},
      %{
        id: A2aDemo.GrpcEndpoint,
        start:
          {GRPC.Server, :start_endpoint,
           [AshA2A.Transport.GRPC.Server.Endpoint, grpc_port]},
        restart: :permanent
      }
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: A2aDemo.Supervisor)
  end
end
