defmodule A2aDemo.Router do
  @moduledoc """
  Mounts BOTH flagship A2A transport bindings on one Bandit listener:

    * `/jsonrpc` -> `AshA2A.Transport.Plug` (JSON-RPC 2.0: `message/send`,
      `stream` SSE, `tasks/*`)
    * `/rest` -> `AshA2A.Transport.HTTPJSON` (v1.0 HTTP+JSON/REST:
      `POST /message:send`, `GET /tasks`, `GET /tasks/{id}`,
      `POST /tasks/{id}:cancel`)

  plus the spec-discovery card at the ROOT `/.well-known/agent-card.json`
  (spec section 8.2: the card is discovered at the well-known path of the
  host root), served unauthenticated through the JSON-RPC transport's card
  path. The gRPC binding is a separate HTTP/2 endpoint
  (A2aDemo.Application, port `A2A_DEMO_GRPC_PORT`, default 4011) sharing
  the same agent and dispatcher.

  The card is also served at both transport mounts' own
  `/.well-known/agent-card.json`, unauthenticated; every other route runs
  the REAL `AshA2A.Protocol.Plug.Auth` in front of the transport (bearer
  scheme, `A2aDemo.Auth.verify/3`) -- fail closed, 401 without a valid
  token.

  `A2A_DEMO_TCK=1` puts the demo into TCK mode: the A2A TCK drives the SUT
  without credentials (and the agent opts into unauthenticated callers via
  the same env, see A2aDemo.Application), so the auth plug is dropped for
  the run. Normal mode is untouched: bearer auth, fail closed.
  """

  @behaviour Plug

  import Plug.Conn

  @card_path [".well-known", "agent-card.json"]

  @impl Plug
  def init(opts) do
    base_url = Keyword.fetch!(opts, :base_url)
    tck_mode? = System.get_env("A2A_DEMO_TCK") == "1"
    signatures = A2aDemo.CardSigning.maybe_signatures(base_url)

    auth =
      if tck_mode? do
        nil
      else
        AshA2A.Protocol.Plug.Auth.init(
          schemes: %{
            "bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}
          },
          verify: &A2aDemo.Auth.verify/3,
          exempt_paths: [@card_path]
        )
      end

    jsonrpc =
      AshA2A.Transport.Plug.init(
        agent: A2aDemo.Agent,
        base_url: base_url,
        json_rpc_path: [],
        agent_card_opts: [signatures: signatures],
        extensions: [AshA2A.Semantic.Extension.capability_declaration()]
      )

    rest = AshA2A.Transport.HTTPJSON.init(agent: A2aDemo.Agent, base_url: base_url)

    %{auth: auth, jsonrpc: jsonrpc, rest: rest, card_path: @card_path}
  end

  @impl Plug
  def call(%{method: "GET", path_info: @card_path} = conn, opts) do
    conn
    |> Map.put(:path_info, @card_path)
    |> AshA2A.Transport.Plug.call(opts.jsonrpc)
  end

  def call(%{path_info: ["jsonrpc" | rest]} = conn, opts) do
    mount(conn, AshA2A.Transport.Plug, opts.jsonrpc, rest, opts.auth)
  end

  def call(%{path_info: ["rest" | rest]} = conn, opts) do
    mount(conn, AshA2A.Transport.HTTPJSON, opts.rest, rest, opts.auth)
  end

  def call(conn, _opts), do: send_resp(conn, 404, "Not Found")

  # Card path: served unauthenticated (both transports answer a card GET
  # themselves). Every other path: the real Plug.Auth runs first and halts
  # with 401 on a missing or invalid credential (skipped entirely in TCK
  # mode).
  defp mount(conn, transport, transport_opts, rest, auth) do
    conn = %{conn | path_info: rest}

    if rest == @card_path do
      transport.call(conn, transport_opts)
    else
      conn = if auth, do: AshA2A.Protocol.Plug.Auth.call(conn, auth), else: conn

      if conn.halted,
        do: conn,
        else: transport.call(conn, transport_opts)
    end
  end
end
