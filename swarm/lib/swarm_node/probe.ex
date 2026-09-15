defmodule SwarmNode.Probe do
  @moduledoc """
  Real cross-pod A2A dispatch probe, invoked from a running release via
  `bin/swarm_node rpc "SwarmNode.Probe.run() |> IO.puts()"` (or from an
  `iex --remsh`/`bin/swarm_node remote` session) -- never from a test
  process on this same node. Every collaborator here is real: real
  distributed-Erlang peer nodes (`Node.list/0`, populated by libcluster's
  real `Cluster.Strategy.Kubernetes.DNS` polling against the real headless
  Service), a real cross-node `GenServer.call` via `A2A.Agent`'s own
  `call/3` (`SwarmNode.EchoAgent.call({SwarmNode.EchoAgent, peer}, msg)`),
  and a real Ash action (`SwarmNode.Echo`'s `:ping`) whose reply names the
  REAL node that executed it (`Kernel.node/0`, not a caller-supplied or
  invented value) -- the falsifiable proof this whole swarm test exists
  to produce.
  """

  require Logger

  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 15_000)
    peers = Node.list()

    result =
      %{
        self_node: to_string(node()),
        peers_seen: Enum.map(peers, &to_string/1),
        dispatches: Enum.map(peers, &dispatch_one(&1, timeout))
      }

    ok? =
      peers != [] and
        Enum.any?(result.dispatches, fn
          %{status: :ok, reply_node: reply_node, peer: peer} ->
            reply_node == to_string(peer) and reply_node != to_string(node())

          _ ->
            false
        end)

    IO.puts(Jason.encode!(Map.put(result, :swarm_dispatch_verified, ok?)))

    if ok?, do: :ok, else: {:error, :no_verified_cross_node_dispatch}
  end

  defp dispatch_one(peer, timeout) do
    message = A2A.Message.new_user([A2A.Part.Data.new(%{"from" => to_string(node())})])

    case SwarmNode.EchoAgent.call({SwarmNode.EchoAgent, peer}, message, timeout: timeout) do
      {:ok, task} ->
        case task.artifacts do
          [%A2A.Artifact{parts: [%A2A.Part.Data{data: %{node: reply_node}}]} | _] ->
            %{peer: peer, status: :ok, reply_node: reply_node, task_state: task.status.state}

          other ->
            %{peer: peer, status: :unexpected_artifact_shape, detail: inspect(other)}
        end

      {:error, reason} ->
        %{peer: peer, status: :error, detail: inspect(reason)}
    end
  rescue
    e -> %{peer: peer, status: :raised, detail: Exception.format(:error, e, __STACKTRACE__)}
  catch
    kind, reason -> %{peer: peer, status: :caught, detail: inspect({kind, reason})}
  end
end
