defmodule SwarmNode.A2ARouter do
  @moduledoc """
  Opt-in A2A JSON-RPC HTTP surface (DEP-09), served by
  `AshA2A.Transport.Plug` (owner-scoped `tasks/*`, bounded bodies, no
  credential echo -- not the raw `AshA2A.Protocol.Plug`). Mounted only when
  `config :swarm_node, :a2a_http, enabled: true` (runtime env
  `SWARM_A2A_HTTP=true`); off by default, so the default deployment exposes no
  unauthenticated agent endpoint. When enabled it serves
  `AshA2A.Transport.Plug` for `SwarmNode.EchoAgent` at `/a2a` on `config :swarm_node, :a2a_http, port:`
  (default 4000), behind the `ash-a2a-swarm-http` ClusterIP Service. TLS for
  this surface terminates at the ingress (HTTPS-only); caller authentication is
  the host's ingress/gateway policy (or an `AshA2A.Protocol.Plug.Auth` plug in front of
  this router); `SwarmNode.EchoAgent` only exposes the `:observe`-only `ping`
  skill publicly.
  """

  use Plug.Router

  plug(:put_base_url)
  plug(:match)
  plug(:dispatch)

  forward("/a2a", to: AshA2A.Transport.Plug, init_opts: [agent: SwarmNode.EchoAgent])

  # Runtime (not compile-time) base URL: `config :swarm_node, :a2a_http,
  # base_url:` is set from SWARM_A2A_BASE_URL in config/runtime.exs.
  defp put_base_url(conn, _opts) do
    case Keyword.get(Application.get_env(:swarm_node, :a2a_http, []), :base_url) do
      nil -> conn
      url -> AshA2A.Protocol.Plug.put_base_url(conn, url)
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
