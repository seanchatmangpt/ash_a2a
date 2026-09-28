defmodule SwarmNode.AdminRouter do
  @moduledoc """
  Kubelet-facing admin HTTP surface (port `config :swarm_node, :admin_port`,
  default 4001): `GET /healthz` (liveness), `GET /readyz` (readiness),
  `GET /drain` (preStop hook; blocks for the drain window, then 200).

  Deliberately a separate listener from the A2A port: no Service selects this
  port and the NetworkPolicy admits no pod traffic to it, so `/drain` is only
  reachable by the kubelet on the node, never through the ingress.
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/healthz" do
    respond(conn, SwarmNode.Health.live())
  end

  get "/readyz" do
    respond(conn, SwarmNode.Health.ready())
  end

  get "/drain" do
    respond(conn, SwarmNode.Health.drain())
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp respond(conn, :ok), do: send_resp(conn, 200, "ok")

  defp respond(conn, {:error, reasons}),
    do: send_resp(conn, 503, Enum.map_join(reasons, "\n", &inspect/1))
end
