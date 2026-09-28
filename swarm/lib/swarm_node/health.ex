defmodule SwarmNode.Health do
  @moduledoc """
  Liveness, readiness, boot gate and graceful drain for the swarm node
  (DEP-01 boot gate, DEP-05 probes, DEP-06 preStop drain).

  * `live/0` -- the supervision trees that make this node useful are running:
    `AshA2A.Supervisor` (receipt store, broker, GraphLaw host, agents) and
    `A2A.AgentSupervisor`. A wedged or crashed tree fails liveness, so the
    kubelet restarts the container.
  * `ready/0` -- live, not draining, GraphLaw loaded when
    `config :swarm_node, :require_graphlaw` is true, and at least
    `config :swarm_node, :min_peers` connected BEAM peers. A pod is only
    published as an endpoint (and counted available in a rollout) once this
    returns `:ok`.
  * `boot_gate/1` -- called from `SwarmNode.Application.start/2`, after the
    `:ash_a2a` application is up. With `:require_graphlaw` true and the
    GraphLaw WASM not loaded, the node refuses to boot
    (`{:error, :graphlaw_unavailable}`) instead of running with every
    semantic/SA2A admission surface degraded to typed errors.
  * `drain/1` -- marks the node not-ready, then waits `:drain_ms` so the
    endpoint is withdrawn before SIGTERM. This is a bounded time window, not
    an in-flight tracker: a dispatch still running when it elapses is cut off
    by shutdown (ash_a2a exposes no in-flight dispatch counter to wait on).

  Everything is read from the running system (`Process.whereis/1`,
  `Node.list/0`, `AshA2A.GraphLaw.WasmexHost.available?/2`); nothing is cached.
  """

  @draining_key {__MODULE__, :draining}

  @type reason ::
          :ash_a2a_supervisor_down
          | :agent_supervisor_down
          | :draining
          | :graphlaw_unavailable
          | {:insufficient_peers, non_neg_integer(), non_neg_integer()}

  @doc "`:ok` when the node's supervision trees are alive."
  @spec live() :: :ok | {:error, [reason()]}
  def live do
    []
    |> check(alive?(AshA2A.Supervisor), :ash_a2a_supervisor_down)
    |> check(alive?(A2A.AgentSupervisor), :agent_supervisor_down)
    |> result()
  end

  @doc "`:ok` when the node may receive traffic. See the moduledoc."
  @spec ready(keyword()) :: :ok | {:error, [reason()]}
  def ready(opts \\ []) do
    min_peers = opt(opts, :min_peers, 0)
    peers = length(Node.list())

    live_errors =
      case live() do
        :ok -> []
        {:error, errors} -> errors
      end

    live_errors
    |> Enum.reverse()
    |> check(not draining?(), :draining)
    |> check(graphlaw_ok?(opts), :graphlaw_unavailable)
    |> check(peers >= min_peers, {:insufficient_peers, peers, min_peers})
    |> result()
  end

  @doc """
  Boot gate: `{:error, :graphlaw_unavailable}` when GraphLaw is required and
  not loaded, otherwise `:ok`. Options (each defaulting to the same key under
  `config :swarm_node`): `:require_graphlaw`, `:graphlaw_host` (default
  `AshA2A.GraphLaw.WasmexHost`).
  """
  @spec boot_gate(keyword()) :: :ok | {:error, :graphlaw_unavailable}
  def boot_gate(opts \\ []) do
    if graphlaw_ok?(opts), do: :ok, else: {:error, :graphlaw_unavailable}
  end

  @doc """
  Marks this node draining (readiness fails from now on) and waits
  `:drain_ms` (default `config :swarm_node, :drain_ms`, 15_000) for the
  endpoint to be withdrawn. Time-bounded only; it does not observe in-flight
  dispatches.
  """
  @spec drain(keyword()) :: :ok
  def drain(opts \\ []) do
    :persistent_term.put(@draining_key, true)
    Process.sleep(opt(opts, :drain_ms, 15_000))
    :ok
  end

  @doc "Clears the draining mark (tests, or an aborted drain)."
  @spec undrain() :: :ok
  def undrain do
    :persistent_term.erase(@draining_key)
    :ok
  end

  @doc "Whether `drain/1` has marked this node."
  @spec draining?() :: boolean()
  def draining?, do: :persistent_term.get(@draining_key, false)

  defp graphlaw_ok?(opts) do
    if opt(opts, :require_graphlaw, false) do
      AshA2A.GraphLaw.WasmexHost.available?(opt(opts, :graphlaw_host, AshA2A.GraphLaw.WasmexHost))
    else
      true
    end
  end

  defp opt(opts, key, default),
    do: Keyword.get_lazy(opts, key, fn -> Application.get_env(:swarm_node, key, default) end)

  defp alive?(name) do
    case Process.whereis(name) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  defp check(errors, true, _reason), do: errors
  defp check(errors, false, reason), do: [reason | errors]

  defp result([]), do: :ok
  defp result(errors), do: {:error, Enum.reverse(errors)}
end
