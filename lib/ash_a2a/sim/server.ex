# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Bandit) do
  defmodule AshA2A.Sim.PushReceiver do
    @moduledoc """
    A real HTTP webhook receiver for push notifications. `AshA2A.Sim.Server`
    starts it on its own port; every `POST` it receives is recorded and can be
    read back with `deliveries/0`.

    Each recorded delivery is a map with `:path`, `:headers` (a map of
    lowercase header names), `:body` (the decoded JSON) and `:raw` (the bytes
    received).
    """

    @behaviour Plug

    import Plug.Conn

    @doc false
    def start_link(_opts \\ []), do: Agent.start_link(fn -> [] end, name: __MODULE__)

    @doc false
    def child_spec(opts),
      do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}

    @doc "Every delivery received so far, oldest first."
    @spec deliveries() :: [map()]
    def deliveries, do: __MODULE__ |> Agent.get(& &1) |> Enum.reverse()

    @doc "Forgets every recorded delivery."
    @spec reset() :: :ok
    def reset, do: Agent.update(__MODULE__, fn _ -> [] end)

    @doc """
    Waits until a recorded delivery satisfies `match?`, polling every 25 ms.
    Returns `{:ok, delivery}` or `:timeout` after `timeout_ms`.
    """
    @spec await((map() -> boolean()), non_neg_integer()) :: {:ok, map()} | :timeout
    def await(match?, timeout_ms \\ 5_000) when is_function(match?, 1) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      do_await(match?, deadline)
    end

    defp do_await(match?, deadline) do
      case Enum.find(deliveries(), match?) do
        nil ->
          if System.monotonic_time(:millisecond) >= deadline do
            :timeout
          else
            Process.sleep(25)
            do_await(match?, deadline)
          end

        delivery ->
          {:ok, delivery}
      end
    end

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(%{method: "POST"} = conn, _opts) do
      {:ok, raw, conn} = read_body(conn)

      body =
        case Jason.decode(raw) do
          {:ok, decoded} -> decoded
          {:error, _} -> nil
        end

      delivery = %{
        path: conn.request_path,
        headers: Map.new(conn.req_headers),
        body: body,
        raw: raw
      }

      Agent.update(__MODULE__, &[delivery | &1])
      send_resp(conn, 200, "")
    end

    def call(conn, _opts), do: send_resp(conn, 405, "")
  end

  defmodule AshA2A.Sim.Router do
    @moduledoc """
    The simulation server's HTTP router. It mounts every HTTP transport the
    library ships on one listener:

    | Path | Served by |
    |---|---|
    | `GET /.well-known/agent-card.json` | the agent card, unauthenticated |
    | `/jsonrpc` | `AshA2A.Transport.Plug` (JSON-RPC 2.0, owner-scoped) |
    | `/a2a` | `AshA2A.A2ATransport.Plug` (JSON-RPC 2.0 with push configs, resubscribe and the extended card) |
    | `/rest` | `AshA2A.Transport.HTTPJSON` (HTTP+JSON, including `message:live`) |

    Each mount also serves its own `/.well-known/agent-card.json` without
    authentication. Every other path runs `AshA2A.Protocol.Plug.Auth` first.

    The mount options depend on the bound port, so `AshA2A.Sim.Server` builds
    them after the listener is up; a request that arrives before then answers
    `503`.
    """

    @behaviour Plug

    import Plug.Conn

    @card_path [".well-known", "agent-card.json"]
    @key {__MODULE__, :mounts}

    @doc false
    def put_mounts(mounts), do: :persistent_term.put(@key, mounts)

    @doc false
    def erase_mounts, do: :persistent_term.erase(@key)

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, _opts) do
      case :persistent_term.get(@key, nil) do
        nil -> send_resp(conn, 503, "simulation server is starting")
        mounts -> route(conn, mounts)
      end
    end

    defp route(%{method: "GET", path_info: @card_path} = conn, mounts) do
      AshA2A.A2ATransport.Plug.call(conn, mounts.root_card)
    end

    defp route(%{path_info: ["jsonrpc" | rest]} = conn, mounts),
      do: mount(conn, AshA2A.Transport.Plug, mounts.jsonrpc, rest, mounts.auth)

    defp route(%{path_info: ["a2a" | rest]} = conn, mounts),
      do: mount(conn, AshA2A.A2ATransport.Plug, mounts.a2a, rest, mounts.auth)

    defp route(%{path_info: ["rest" | rest]} = conn, mounts),
      do: mount(conn, AshA2A.Transport.HTTPJSON, mounts.rest, rest, mounts.auth)

    defp route(conn, _mounts), do: send_resp(conn, 404, "Not Found")

    defp mount(conn, transport, transport_opts, rest, auth) do
      conn = %{conn | path_info: rest, script_name: conn.script_name ++ [hd(conn.path_info)]}

      if rest == @card_path do
        transport.call(conn, transport_opts)
      else
        # A refusal is answered in the error format of the mount's binding.
        format = if transport == AshA2A.Transport.HTTPJSON, do: :http_json, else: :jsonrpc
        conn = AshA2A.Protocol.Plug.Auth.call(conn, Map.put(auth, :error_format, format))
        if conn.halted, do: conn, else: transport.call(conn, transport_opts)
      end
    end
  end

  defmodule AshA2A.Sim.Server do
    @moduledoc """
    Boots the whole served surface of ash_a2a against `AshA2A.Sim.Agent`, on
    real listeners, so every transport can be driven over the wire.

        {:ok, _pid} = AshA2A.Sim.Server.start_link()
        info = AshA2A.Sim.Server.info()
        info.jsonrpc_url
        #=> "http://127.0.0.1:49321/jsonrpc"

    What it starts:

      * `AshA2A.Sim.Agent`, with the standing grants for the writer token
        (`AshA2A.Sim.Auth`).
      * one HTTP listener (`AshA2A.Sim.Router`) serving
        `AshA2A.Transport.Plug` at `/jsonrpc`, `AshA2A.A2ATransport.Plug` at
        `/a2a`, `AshA2A.Transport.HTTPJSON` at `/rest`, and the well-known
        agent card at the root and at each mount.
      * the gRPC endpoint (`AshA2A.Transport.GRPC.Server`), with the same
        bearer authentication.
      * a webhook receiver (`AshA2A.Sim.PushReceiver`) that records
        push-notification deliveries.
      * an ETS event journal (`AshA2A.TaskStore.EventJournalEts`) and a fresh
        Ed25519 key pair that signs every served agent card (public and extended).

    ## Options

      * `:http_port`, `:grpc_port`, `:push_port` - listen ports. Each defaults
        to `0`, which picks a free port.
      * `:name` - registered name, default `AshA2A.Sim.Server`.

    Only one simulation server can run in a VM: the agent is registered under
    its module name and the gRPC server reads one application environment.

    `info/1` returns the bound ports and URLs:

      * `:http_port`, `:grpc_port`, `:push_port`
      * `:base_url`, `:card_url`, `:jsonrpc_url`, `:a2a_url`, `:rest_url`
      * `:grpc_target` (`host:port`), `:push_url`
      * `:tokens` (see `AshA2A.Sim.Auth.tokens/0`)
      * `:card_jwks` - the JWKS (`%{"keys" => [public_jwk]}`) that verifies the
        `signatures` entry of every served agent card
        (`AshA2A.Protocol.AgentCardSignature.verify/3`)

    The agent's task events are journaled in an ETS
    `AshA2A.Protocol.EventJournal` for as long as the server runs
    (`config :ash_a2a, :event_journal` is set on start and put back on stop),
    so `tasks/resubscribe` with `lastSeenGeneration` replays missed events.

    This module is compiled only when Bandit is available. Bandit is an
    optional dependency of ash_a2a; add `{:bandit, "~> 1.5"}` to use the
    simulation server from another project.
    """

    use GenServer

    @transport AshA2A.Sim.Transport
    @host "127.0.0.1"
    # `:event_journal` is saved and restored with the gRPC keys: the server
    # points it at its own journal while it runs.
    @grpc_env_keys [
      AshA2A.Transport.GRPC.Server,
      AshA2A.Transport.GRPC.Server.Endpoint,
      :event_journal
    ]
    @journal AshA2A.Sim.EventJournal
    @card_kid "sim-card-1"

    @doc false
    def child_spec(opts) do
      %{
        id: Keyword.get(opts, :name, __MODULE__),
        start: {__MODULE__, :start_link, [opts]},
        type: :worker,
        shutdown: 10_000
      }
    end

    @doc "Starts the simulation server. See the module documentation for options."
    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    end

    @doc "The bound ports and URLs of a running simulation server."
    @spec info(GenServer.server()) :: map()
    def info(server \\ __MODULE__), do: GenServer.call(server, :info)

    @doc "The `AshA2A.A2ATransport` instance name the mounts share."
    @spec transport() :: atom()
    def transport, do: @transport

    @doc "Stops the simulation server and releases its ports."
    @spec stop(GenServer.server()) :: :ok
    def stop(server \\ __MODULE__), do: GenServer.stop(server, :normal, 15_000)

    @impl GenServer
    def init(opts) do
      Process.flag(:trap_exit, true)

      # The gRPC server reads its handler and its auth seam from the
      # application environment; remember what was there to put it back.
      grpc_env = Enum.map(@grpc_env_keys, &{&1, Application.fetch_env(:ash_a2a, &1)})

      for app <- [:bandit, :req, :grpc, :grpc_server],
          do: {:ok, _} = Application.ensure_all_started(app)

      {:ok, sup} = Supervisor.start_link([], strategy: :one_for_one)

      ensure_broker(sup)

      # The webhook receiver listens on loopback over plain HTTP, which the
      # delivery defaults refuse; this instance opts in for the simulation.
      {:ok, _} =
        Supervisor.start_child(
          sup,
          {AshA2A.A2ATransport,
           name: @transport,
           push: [
             allow_http: true,
             allow_cidrs: ["127.0.0.0/8", "::1/128"],
             max_attempts: 2,
             base_backoff_ms: 50
           ]}
        )

      # Every task write of the agent is journaled, so `tasks/resubscribe`
      # with `lastSeenGeneration` replays missed events (`/jsonrpc` mount).
      {:ok, _} = Supervisor.start_child(sup, {AshA2A.TaskStore.EventJournalEts, name: @journal})

      Application.put_env(
        :ash_a2a,
        :event_journal,
        {AshA2A.TaskStore.EventJournalEts, @journal}
      )

      {:ok, _} = Supervisor.start_child(sup, {AshA2A.Sim.Agent, []})
      :ok = AshA2A.Sim.Auth.issue_grants()

      {:ok, _} = Supervisor.start_child(sup, AshA2A.Sim.PushReceiver)

      push_port =
        listen(sup, :sim_push, AshA2A.Sim.PushReceiver, Keyword.get(opts, :push_port, 0))

      http_port = listen(sup, :sim_http, AshA2A.Sim.Router, Keyword.get(opts, :http_port, 0))
      base_url = "http://#{@host}:#{http_port}"

      {:ok, grpc} =
        Supervisor.start_child(
          sup,
          {AshA2A.Transport.GRPC.Supervisor,
           port: Keyword.get(opts, :grpc_port, 0),
           handler: AshA2A.Sim.GrpcHandler,
           ctx: %{agent: AshA2A.Sim.Agent, opts: %{}, transport: @transport},
           auth:
             {AshA2A.Transport.GRPC.Auth,
              AshA2A.Protocol.Plug.Auth.init(AshA2A.Sim.Auth.plug_auth_opts())}}
        )

      grpc_port = AshA2A.Transport.GRPC.Supervisor.port(grpc)
      {card_private, card_public} = card_keys()

      info = %{
        http_port: http_port,
        grpc_port: grpc_port,
        push_port: push_port,
        base_url: base_url,
        card_url: base_url <> "/.well-known/agent-card.json",
        jsonrpc_url: base_url <> "/jsonrpc",
        a2a_url: base_url <> "/a2a",
        rest_url: base_url <> "/rest",
        grpc_target: "#{@host}:#{grpc_port}",
        push_url: "http://#{@host}:#{push_port}/hook",
        tokens: AshA2A.Sim.Auth.tokens(),
        card_jwks: %{"keys" => [card_public]}
      }

      interfaces = interfaces(info)

      # Every HTTP mount serves its card with an `AgentCardSignature` made
      # with this key; `info.card_jwks` is the public half.
      sign_with = [jwk: card_private, kid: @card_kid]

      # The gRPC handler builds the extended card from the same facts.
      put_grpc_ctx(%{
        agent: AshA2A.Sim.Agent,
        opts: %{},
        transport: @transport,
        base_url: info.a2a_url,
        agent_card_opts: [supported_interfaces: interfaces],
        sign_with: sign_with
      })

      AshA2A.Sim.Router.put_mounts(mounts(info, interfaces, sign_with))

      {:ok,
       %{sup: sup, grpc_env: grpc_env, info: Map.put(info, :supported_interfaces, interfaces)}}
    end

    @impl GenServer
    def handle_call(:info, _from, state), do: {:reply, state.info, state}

    @impl GenServer
    def handle_info({:EXIT, sup, reason}, %{sup: sup} = state), do: {:stop, reason, state}
    def handle_info(_other, state), do: {:noreply, state}

    @impl GenServer
    def terminate(_reason, %{sup: sup, grpc_env: grpc_env}) do
      AshA2A.Sim.Router.erase_mounts()

      try do
        Supervisor.stop(sup, :normal, 10_000)
      catch
        :exit, _ -> :ok
      end

      for {key, previous} <- grpc_env do
        case previous do
          {:ok, value} -> Application.put_env(:ash_a2a, key, value)
          :error -> Application.delete_env(:ash_a2a, key)
        end
      end

      :ok
    end

    @doc false
    def interfaces(info) do
      [
        %{url: info.a2a_url, protocol_binding: "JSONRPC", protocol_version: "1.1"},
        %{url: info.jsonrpc_url, protocol_binding: "JSONRPC", protocol_version: "1.1"},
        %{url: info.rest_url, protocol_binding: "HTTP+JSON", protocol_version: "1.1"},
        %{url: info.grpc_target, protocol_binding: "GRPC", protocol_version: "1.1"}
      ]
    end

    # A fresh Ed25519 key pair per server run, as private and public JWK.
    # EdDSA signatures are deterministic: the same card gets the same
    # signature on every binding and every request.
    defp card_keys do
      {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
      b64 = &Base.url_encode64(&1, padding: false)

      public = %{
        "kty" => "OKP",
        "crv" => "Ed25519",
        "x" => b64.(pub),
        "kid" => @card_kid,
        "use" => "sig",
        "alg" => "EdDSA"
      }

      {Map.put(public, "d", b64.(priv)), public}
    end

    defp mounts(info, interfaces, sign_with) do
      card_opts = [supported_interfaces: interfaces]
      provider = &AshA2A.Sim.Auth.extended_card/2

      a2a = fn base_url ->
        AshA2A.A2ATransport.Plug.init(
          agent: AshA2A.Sim.Agent,
          base_url: base_url,
          json_rpc_path: [],
          agent_card_opts: card_opts,
          sign_with: sign_with,
          transport: @transport,
          push_notifications: true,
          extended_card: provider
        )
      end

      %{
        auth: AshA2A.Protocol.Plug.Auth.init(AshA2A.Sim.Auth.plug_auth_opts()),
        # The root card is the full JSON-RPC mount's card: it advertises what
        # the server as a whole serves (push notifications, extended card).
        root_card: a2a.(info.base_url),
        jsonrpc:
          AshA2A.Transport.Plug.init(
            agent: AshA2A.Sim.Agent,
            base_url: info.jsonrpc_url,
            json_rpc_path: [],
            agent_card_opts: card_opts,
            sign_with: sign_with
          ),
        a2a: a2a.(info.a2a_url),
        rest:
          AshA2A.Transport.HTTPJSON.init(
            agent: AshA2A.Sim.Agent,
            base_url: info.rest_url,
            agent_card_opts: card_opts,
            sign_with: sign_with,
            transport: @transport,
            push_notifications: true,
            extended_card: provider,
            serve_schemas: true,
            schema_index: AshA2A.Sim.Note
          )
      }
    end

    defp listen(sup, id, plug, port) do
      spec =
        Supervisor.child_spec(
          {Bandit,
           plug: plug,
           port: port,
           ip: {127, 0, 0, 1},
           startup_log: false,
           thousand_island_options: [read_timeout: 60_000]},
          id: id
        )

      {:ok, pid} = Supervisor.start_child(sup, spec)
      {:ok, {_ip, bound}} = ThousandIsland.listener_info(pid)
      bound
    end

    # Host applications start `AshA2A.Authority.Broker.InMemory` themselves; a
    # durable broker is started by `AshA2A.Application`. Start the in-memory
    # one only when it is the configured broker and nobody started it.
    defp ensure_broker(sup) do
      in_memory = AshA2A.Authority.Broker.InMemory

      configured =
        case Application.get_env(:ash_a2a, :authority_broker) do
          {module, _opts} -> module
          module -> module
        end

      if configured == in_memory and is_nil(Process.whereis(in_memory)) do
        {:ok, _} = Supervisor.start_child(sup, {in_memory, []})
      end

      :ok
    end

    defp put_grpc_ctx(ctx) do
      key = AshA2A.Transport.GRPC.Server
      existing = Application.get_env(:ash_a2a, key, [])
      Application.put_env(:ash_a2a, key, Keyword.put(existing, :ctx, ctx))
    end
  end
end
