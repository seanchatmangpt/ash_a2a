# A2A TCK SUT harness for ash_a2a (lane AT2).
#
# Run from /Users/sac/ash_a2a with:
#   MIX_ENV=test mix run --no-start tck_sut.exs
#
# Boots a real AshA2A.Agent (handle_message/2 overridden — the same seam the
# reference Python SUT hand-implements) behind the real owned transport
# (AshA2A.Transport.Plug) on a real Bandit listener, port from
# TCK_SUT_PORT (default 9999).
#
# The messageId-prefix routing table mirrors the official reference SUT
# (a2a-tck sut/a2a-python/sut_agent handler). That prefix contract is the
# TCK's own behavioral harness, not protocol logic.

defmodule TckSut.Resource do
  use Ash.Resource,
    domain: TckSut.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:message, :string, public?: true)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:echo, :read)
  end
end

defmodule TckSut.Domain do
  use Ash.Domain
end

defmodule TckSut.Agent do
  @moduledoc false

  use AshA2A.Agent,
    resource_or_domain: TckSut.Resource,
    name: "tck_sut_agent",
    require_authenticated_caller: false

  alias AshA2A.Protocol.Part

  @impl AshA2A.Protocol.Agent
  def handle_message(message, _ctx) do
    id = message.message_id || ""

    cond do
      String.starts_with?(id, "tck-stream-artifact-chunked") ->
        {:stream, [Part.Text.new("chunk-1 "), Part.Text.new("chunk-2")]}

      String.starts_with?(id, "test-resubscribe-message-id") ->
        {:stream,
         Stream.map([:go], fn _ ->
           Process.sleep(4_000)
           Part.Text.new("done")
         end)}

      String.starts_with?(id, "tck-stream-artifact-text") ->
        {:stream, [Part.Text.new("Streamed text content")]}

      String.starts_with?(id, "tck-stream-artifact-file") ->
        {:stream, [file_part()]}

      String.starts_with?(id, "tck-stream-ordering-001") ->
        {:stream, [Part.Text.new("Ordered output")]}

      # gRPC streaming sample ids (tck/validators' grpc test_streaming.py
      # _SAMPLE_MESSAGE: "tck-grpc-streaming-NNN") — must stream, else
      # SendStreamingMessage refuses "Task is not streamable" and GRPC-ERR-003
      # is never exercised. Mirrors the tck-stream-001 behavior.
      String.starts_with?(id, "tck-grpc-streaming") ->
        {:stream, [Part.Text.new("Stream hello from TCK")]}

      String.starts_with?(id, "tck-stream-001") ->
        {:stream, [Part.Text.new("Stream hello from TCK")]}

      String.starts_with?(id, "tck-stream-002") ->
        {:stream, []}

      String.starts_with?(id, "tck-stream-003") ->
        {:stream, [Part.Text.new("Stream task lifecycle")]}

      String.starts_with?(id, "tck-artifact-file-url") ->
        {:reply, [url_file_part()]}

      String.starts_with?(id, "tck-message-response") ->
        {:message, [Part.Text.new("Direct message response")]}

      String.starts_with?(id, "tck-input-required") ->
        {:input_required, [Part.Text.new("Need more input")]}

      String.starts_with?(id, "tck-complete-task") ->
        {:reply, [Part.Text.new("Hello from TCK")]}

      String.starts_with?(id, "tck-artifact-text") ->
        {:reply, [Part.Text.new("Generated text content")]}

      String.starts_with?(id, "tck-artifact-file") ->
        {:reply, [file_part()]}

      String.starts_with?(id, "tck-artifact-data") ->
        {:reply, [Part.Data.new(%{"key" => "value", "count" => 42})]}

      String.starts_with?(id, "tck-passthrough") ->
        {:reply, [Part.Text.new("Echo reply")]}

      String.starts_with?(id, "tck-reject-task") ->
        {:error, :forbidden}

      true ->
        # Reference-SUT default: complete with an echo of the unhandled id.
        {:reply, [Part.Text.new("Unhandled messageId prefix: " <> id)]}
    end
  end

  defp file_part do
    Part.File.new(
      AshA2A.Protocol.FileContent.from_bytes("tck", name: "output.txt", mime_type: "text/plain")
    )
  end

  defp url_file_part do
    Part.File.new(
      AshA2A.Protocol.FileContent.from_uri("https://example.com/output.txt",
        name: "output.txt",
        mime_type: "text/plain"
      )
    )
  end
end

defmodule TckSut.CardKeys do
  @moduledoc false
  # Card-signing key material (lane DY3 card-serving sections): a fresh HMAC
  # key per boot, published at /.well-known/jwks.json so a verifier can
  # resolve the `kid` the JWS protected header carries.
  use GenServer

  @kid "tck-sut-card-key-1"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    {:ok, %{key: :crypto.strong_rand_bytes(32), kid: @kid}}
  end

  def signing_key, do: GenServer.call(__MODULE__, :signing_key)
  def kid, do: GenServer.call(__MODULE__, :kid)

  @impl GenServer
  def handle_call(:signing_key, _from, state), do: {:reply, state.key, state}

  def handle_call(:kid, _from, state), do: {:reply, state.kid, state}
end

defmodule TckSut.Cards do
  @moduledoc false
  # Card projection for the TCK SUT (lane DY3 card-serving sections): a
  # signed public card — JWS over the JCS bytes of the exact served document
  # (A2A v1.0 §8.4, via the real AshA2A.Protocol.CardSigning) — and the
  # extended card (public card + admin skill), served with EXPLICIT private
  # cache headers so it never inherits the public card's public caching
  # (AT5 advisory: authenticated card must not be cacheable as public).
  alias AshA2A.Protocol.CardSigning

  # extendedAgentCard: true activates the TCK's CARD-EXT-001/002 probe tests.
  def capabilities do
    %{streaming: true, push_notifications: true, extended_agent_card: true}
  end

  def public_card(base_url, interfaces) do
    card = GenServer.call(TckSut.Agent, :get_agent_card)

    card_opts = [
      url: base_url,
      capabilities: capabilities(),
      kid: TckSut.CardKeys.kid(),
      supported_interfaces: interfaces
    ]

    card
    |> CardSigning.sign(card_key(), card_opts)
    |> AshA2A.Protocol.JSON.encode_agent_card(card_opts)
  end

  def extended_card(base_url, interfaces) do
    admin_skill = %{
      "id" => "tck-admin",
      "name" => "TCK Admin",
      "description" => "Authenticated extended-card skill (CARD-EXT-001)",
      "tags" => ["tck", "admin"]
    }

    public_card(base_url, interfaces)
    |> Map.update!("skills", &(&1 ++ [admin_skill]))
  end

  @doc "JWS-verify the SERVED public card bytes against the SUT key (self-court)."
  def verify_served(body, base_url, interfaces) do
    {:ok, card} = body |> Jason.decode!() |> AshA2A.Protocol.JSON.decode_agent_card()

    CardSigning.verify(card, card_key(),
      url: base_url,
      capabilities: capabilities(),
      supported_interfaces: interfaces
    )
  end

  defp card_key, do: TckSut.CardKeys.signing_key()
end

defmodule TckSut.Router do
  @moduledoc false
  import Plug.Conn

  def init(opts) do
    opts
    |> Map.new()
    |> Map.update!(:jsonrpc, fn {mod, o} -> {mod, mod.init(o)} end)
    |> Map.update!(:rest, fn {mod, o} -> mod.init(o) end)
  end

  # -- lane DY3 card-serving sections ----------------------------------------

  # Signed public card (lane DY3): served from the router so the JWS
  # `signatures` member and the `extendedAgentCard` capability ride the exact
  # document the TCK decodes (the digest binds the served bytes).
  def call(%{method: "GET", path_info: [".well-known", "agent-card.json"]} = conn, opts) do
    serve_public_card(conn, opts)
  end

  # CARD-EXT: the extended card over HTTP+JSON — GET /a2a/rest/extendedAgentCard
  # (the TCK's http_json client path). Explicit private cache headers: the
  # authenticated card must NOT inherit the public card's public caching.
  # Matched BEFORE the REST passthrough clause below.
  def call(%{method: "GET", path_info: ["a2a", "rest", "extendedAgentCard"]} = conn, opts) do
    serve_extended_card(conn, opts)
  end

  # -- REST mount (HTTP+JSON binding; push CRUD surface included) -------------

  # PUSH-DELIVER over the REST binding: the §5.3 message:send route answers
  # through AshA2A.Transport.HTTPJSON (whose REST send path does not run the
  # JSON-RPC binding's inline push-config registration), so the SUT wraps the
  # route here — read the body, forward, then register the inline config
  # against the created task exactly like register_inline_push_config does.
  # The REST plug reads pre-set body_params without re-reading the socket.
  def call(%{method: "POST", path_info: ["a2a", "rest", "message:send"]} = conn, opts) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, conn} ->
        case Jason.decode(body) do
          {:ok, %{"configuration" => %{"taskPushNotificationConfig" => raw}} = decoded}
          when is_map(raw) ->
            conn =
              AshA2A.Transport.HTTPJSON.call(
                %{conn | path_info: ["message:send"], body_params: decoded},
                opts.rest
              )

            rest_register_inline_push(decoded, conn, opts)

          {:ok, decoded} ->
            AshA2A.Transport.HTTPJSON.call(
              %{conn | path_info: ["message:send"], body_params: decoded},
              opts.rest
            )

          _ ->
            send_json(conn, 400, "bad request")
        end

      {:error, _, conn} ->
        send_json(conn, 400, "bad request")
    end
  end

  def call(%{path_info: ["a2a", "rest" | rest]} = conn, opts) do
    AshA2A.Transport.HTTPJSON.call(%{conn | path_info: rest}, opts.rest)
  end

  defp rest_register_inline_push(decoded, conn, _opts) do
    with 200 <- conn.status,
         {:ok, %{"task" => %{"id" => task_id}} = task} <- Jason.decode(conn.resp_body || ""),
         {:ok, config} <-
           AshA2A.Protocol.JSON.decode(decoded["configuration"]["taskPushNotificationConfig"], :push_notification_config) do
      config = %{config | task_id: task_id, id: config.id || AshA2A.Protocol.ID.generate("pcfg")}
      {:ok, _} = GenServer.call(TckSut.Agent, {:set_push_config, config})
      GenServer.cast(TckSut.Agent, {:deliver_push, task_id})

      # The REST send already served the task's final state before the webhook
      # was registered, so force one delivery of the served snapshot (the same
      # rule Protocol.Plug applies on the JSON-RPC side).
      state = get_in(task, ["status", "state"]) || ""
      final? = closed_state?(state)
      payload = %{"task" => AshA2A.A2ATransport.Ownership.strip_wire(task)}

      AshA2A.A2ATransport.TaskEvents.publish(
        TckSut.Transport,
        task_id,
        "task",
        payload,
        final?
      )

      :ok
    else
      _ -> :ok
    end
  end

  defp closed_state?(state) do
    state
    |> String.downcase()
    |> String.replace_prefix("task_state_", "")
    |> then(& &1 in ~w(completed canceled cancelled failed rejected))
  end

  # CARD-EXT over JSON-RPC: GetExtendedAgentCard (PascalCase alias, the name
  # the TCK sends) is answered here because the vendored JSON-RPC dispatcher
  # answers it `unsupported_operation`. Any other POST forwards to the mount
  # with the read body re-attached as `body_params` (the plugs' read_json_body
  # uses pre-set body_params without re-reading the socket).
  def call(%{method: "POST"} = conn, opts) do
    {mod, jsonrpc_opts} = opts.jsonrpc

    case Plug.Conn.read_body(conn) do
      {:ok, body, conn} ->
        case Jason.decode(body) do
          {:ok, %{"method" => m} = decoded}
          when m in ["GetExtendedAgentCard", "agent/getAuthenticatedExtendedCard"] ->
            extended_card_rpc(conn, decoded, opts)

          {:ok, decoded} ->
            mod.call(%{conn | body_params: decoded}, jsonrpc_opts)

          _ ->
            mod.call(%{conn | body_params: %{}}, jsonrpc_opts)
        end

      {:more, _, conn} ->
        send_json(conn, 413, "body too large")

      {:error, _reason, conn} ->
        send_json(conn, 400, "bad request")
    end
  end

  defp extended_card_rpc(conn, decoded, opts) do
    json = TckSut.Cards.extended_card(base_url(opts), interfaces(opts))

    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => decoded["id"], "result" => json}))
  end

  defp serve_public_card(conn, opts) do
    body = Jason.encode!(TckSut.Cards.public_card(base_url(opts), interfaces(opts)))

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("etag", etag(body))
    |> put_resp_header("last-modified", last_modified())
    |> put_resp_header("cache-control", "public, max-age=300")
    |> send_resp(200, body)
  end

  defp serve_extended_card(conn, opts) do
    json = TckSut.Cards.extended_card(base_url(opts), interfaces(opts))

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "private, no-store")
    |> send_resp(200, Jason.encode!(json))
  end

  defp base_url(opts),
    do: opts |> get_in([:jsonrpc, Access.elem(1), :base_url]) ||
          "http://127.0.0.1:#{System.get_env("TCK_SUT_PORT", "9999")}"

  defp interfaces(opts) do
    opts |> get_in([:jsonrpc, Access.elem(1), :agent_card_opts]) |> get_in([:supported_interfaces])
  end

  defp etag(body), do: ~s(") <> (:crypto.hash(:sha256, body) |> Base.encode16(case: :lower)) <> ~s(")

  defp last_modified do
    Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S GMT")
  end

  defp send_json(conn, status, body) when is_integer(status) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  defp send_json(conn, body_map, cache: cache) do
    conn
    |> put_resp_header("cache-control", cache)
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body_map))
  end
end

port = System.get_env("TCK_SUT_PORT", "9999") |> String.to_integer()
base_url = "http://127.0.0.1:#{port}"

grpc_port = System.get_env("TCK_SUT_GRPC_PORT", "#{port + 1}") |> String.to_integer()

interfaces = [
  %{url: base_url, protocol_binding: "JSONRPC", protocol_version: "1.0"},
  %{url: "#{base_url}/a2a/rest", protocol_binding: "HTTP+JSON", protocol_version: "1.0"},
  # GRPC interface — bare host:port. The TCK's GrpcClient passes this string
  # straight to grpc.insecure_channel/1, which resolves it as a DNS target:
  # an "http://" scheme here produces "Misformatted domain name" UNAVAILABLE
  # failures (observed). Card URLs in the spec's HTTP sense don't apply to
  # gRPC — the binding is addressed by authority only.
  %{url: "127.0.0.1:#{grpc_port}", protocol_binding: "GRPC", protocol_version: "1.0"}
]

# TCK webhook receiver is http://localhost:<port> — the sender's SSRF-safe
# defaults (require_https/block_private_ips, lane S2) must be explicitly
# opted OUT for this compliance-suite SUT only; library defaults stay ON.
{:ok, _} =
  TckSut.Agent.start_link(
    push_sender:
      {AshA2A.Protocol.PushNotificationSender.HTTP, require_https: false, block_private_ips: false}
  )
{:ok, _} = TckSut.CardKeys.start_link([])

# Set-time webhook admission (WebhookPolicy via the transport's push opts)
# must also admit the TCK receiver: http scheme + loopback addresses.
{:ok, _} =
  AshA2A.A2ATransport.start_link(
    name: TckSut.Transport,
    push: [allow_http: true, allow_cidrs: ["127.0.0.0/8", "::1/128"]]
  )

# The push sender delivers via Req/Finch; `mix run --no-start` boots no
# dependency applications, so the Req.Finch pool (Finch instance named
# Req.Finch) must be started here or every delivery dies with
# `unknown registry: Req.Finch` (the observed silent webhook gap).
{:ok, _} = Application.ensure_all_started(:finch)
{:ok, _} = Finch.start_link(name: Req.Finch)

{:ok, srv} =
  Bandit.start_link(
    plug:
      {TckSut.Router,
       jsonrpc:
         {AshA2A.Protocol.Plug, agent: TckSut.Agent, base_url: base_url,
          transport: TckSut.Transport,
          agent_card_opts: [supported_interfaces: interfaces,
                            capabilities: %{streaming: true, push_notifications: true}]},
       rest:
         {AshA2A.Transport.HTTPJSON, agent: TckSut.Agent, base_url: base_url,
          transport: TckSut.Transport, push_notifications: true}},
    port: port,
    ip: {127, 0, 0, 1}
  )

{:ok, {_, bound}} = ThousandIsland.listener_info(srv)
IO.puts("TCK SUT listening on http://127.0.0.1:#{bound}")

# -- gRPC binding (lane DY1) ------------------------------------------------
#
# Serves the canonical `lf.a2a.v1.A2AService` over HTTP/2 on grpc_port via
# AshA2A.Transport.GRPC.Server, with the SAME handler the JSON-RPC side uses
# (AshA2A.Transport.Plug, an AshA2A.Protocol.JSONRPC behaviour impl) and the
# same agent (TckSut.Agent). Streaming RPCs subscribe to the per-task event
# log of a dedicated AshA2A.A2ATransport instance.
defmodule TckSut.GrpcHandler do
  @moduledoc false

  # Delegates to the SAME handler the JSON-RPC side uses
  # (AshA2A.Transport.Plug, a full AshA2A.Protocol.JSONRPC behaviour impl),
  # so gRPC and JSON-RPC share one dispatch path per RPC. The HTTP side
  # builds its ctx from the live Plug.Conn (line ~216 of plug.ex); the gRPC
  # side has no conn, so we supply the anonymous-caller equivalent: an empty
  # conn (no auth/metadata private map) + :anonymous principal — exactly the
  # ctx the HTTP side would build for an unauthenticated request.
  @behaviour AshA2A.Protocol.JSONRPC

  # The plug opts the HTTP JSON-RPC mount inits with (init/1's map shape),
  # rebuilt here so the gRPC side dispatches through the SAME injected
  # AshA2A.Protocol.Plug handlers the HTTP side uses — including inline push
  # registration (register_inline_push_config gates on
  # agent_card_opts capabilities push_notifications) and event-log publishing.
  defp plug_opts do
    %{
      transport: TckSut.Transport,
      metadata: %{},
      authorize_task: nil,
      agent_card_opts: [capabilities: %{streaming: true, push_notifications: true}]
    }
  end

  defp agent_ctx do
    %{agent: TckSut.Agent, opts: plug_opts(), conn: %Plug.Conn{private: %{}},
      principal: :anonymous}
  end

  # The HTTP side's handle_json_rpc publish_result/1 equivalent for unary
  # task replies: a task result must land in the named transport's event log
  # or a later SubscribeToTask (STREAM-ORDER-*) sees an empty log.
  defp publish_result(%AshA2A.Protocol.Task{} = task) do
    # The HTTP side's handle_json_rpc publish_result/1 equivalent: a task
    # result lands in the named transport's event log or a later
    # SubscribeToTask (STREAM-ORDER-*) sees an empty log.
    final? =
      task.status.state in [
        # Hard-terminal states only: input-required keeps the subscribe
        # stream open (more input is expected), so it must not carry final?.
        :completed, :canceled, :failed, :rejected
      ]

    {:ok, wire} = AshA2A.Protocol.JSON.encode(task)

    AshA2A.A2ATransport.TaskEvents.publish(
      TckSut.Transport,
      task.id,
      "task",
      %{"task" => AshA2A.A2ATransport.Ownership.strip_wire(wire)},
      final?
    )

    :ok
  end

  defp publish_result(_), do: :ok

  @impl AshA2A.Protocol.JSONRPC
  def handle_send(message, params, _ctx) do
    # gRPC dispatches through the SAME injected AshA2A.Protocol.Plug handlers
    # the HTTP JSON-RPC binding uses (TckSut.Agent.handle_send/3), so inline
    # push-config registration + the deliver_push cast (PUSH-DELIVER-*) run
    # identically on both bindings.
    case AshA2A.Protocol.Plug.handle_send(message, params, agent_ctx()) do
      {:ok, result} ->
        publish_result(result)
        {:ok, wire_result(result)}

      {:error, %AshA2A.Protocol.JSONRPC.Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, AshA2A.Transport.Plug.wire_error(reason)}
    end
  end

  defp wire_result(%AshA2A.Protocol.Task{} = task), do: AshA2A.Transport.Runtime.wire_task(task)
  defp wire_result(%AshA2A.Protocol.Message{} = msg), do: msg
  defp wire_result(other), do: other

  @impl AshA2A.Protocol.JSONRPC
  def handle_get(task_id, params, _ctx), do: AshA2A.Transport.Plug.handle_get(task_id, params, ctx())

  @impl AshA2A.Protocol.JSONRPC
  def handle_cancel(task_id, params, _ctx), do: AshA2A.Transport.Plug.handle_cancel(task_id, params, ctx())

  @impl AshA2A.Protocol.JSONRPC
  def handle_list(params, _ctx), do: AshA2A.Transport.Plug.handle_list(params, ctx())

  # Push CRUD on the gRPC side routes through the SAME injected
  # AshA2A.Protocol.Plug handlers the HTTP JSON-RPC binding uses (the
  # transport-module delegation answered UndefinedFunctionError ->
  # INTERNAL, the observed PUSH-CREATE-001 "Internal error").
  @impl AshA2A.Protocol.JSONRPC
  def handle_set_push_config(config, params, _ctx),
    do: AshA2A.Protocol.Plug.handle_set_push_config(config, params, agent_ctx())

  @impl AshA2A.Protocol.JSONRPC
  def handle_get_push_config(task_id, config_id, params, _ctx),
    do: AshA2A.Protocol.Plug.handle_get_push_config(task_id, config_id, params, agent_ctx())

  @impl AshA2A.Protocol.JSONRPC
  def handle_list_push_configs(task_id, params, _ctx),
    do: AshA2A.Protocol.Plug.handle_list_push_configs(task_id, params, agent_ctx())

  @impl AshA2A.Protocol.JSONRPC
  def handle_delete_push_config(task_id, config_id, params, _ctx),
    do: AshA2A.Protocol.Plug.handle_delete_push_config(task_id, config_id, params, agent_ctx())

  # CARD-EXT over the gRPC binding: the gRPC dispatch consults this opt-in
  # callback (lib/.../grpc/dispatch.ex) before falling back to the JSON-RPC
  # dispatcher's UNIMPLEMENTED refusal. Serves the same extended card the
  # HTTP router serves (public card + admin skill, private cache intent is
  # an HTTP header concept, so nothing to mirror on gRPC).
  def handle_extended_card(_ctx) do
    {:ok, TckSut.Cards.extended_card(base_url(), grpc_interfaces())}
  end

  defp base_url, do: "http://127.0.0.1:#{System.get_env("TCK_SUT_PORT", "9999")}"

  defp grpc_interfaces do
    grpc_port = System.get_env("TCK_SUT_GRPC_PORT", "#{String.to_integer(System.get_env("TCK_SUT_PORT", "9999")) + 1}")

    [
      %{url: base_url(), protocol_binding: "JSONRPC", protocol_version: "1.0"},
      %{url: "#{base_url()}/a2a/rest", protocol_binding: "HTTP+JSON", protocol_version: "1.0"},
      %{url: "127.0.0.1:#{grpc_port}", protocol_binding: "GRPC", protocol_version: "1.0"}
    ]
  end

  defp ctx do
    %{agent: TckSut.Agent, opts: [], transport: TckSut.Transport,
      conn: %Plug.Conn{private: %{}}, principal: :anonymous}
  end
end

Application.put_env(:ash_a2a, AshA2A.Transport.GRPC.Server,
  handler: TckSut.GrpcHandler,
  ctx: %{agent: TckSut.Agent, opts: [], transport: TckSut.Transport}
)

{:ok, _} = Application.ensure_all_started(:grpc)
{:ok, _} = Application.ensure_all_started(:ranch)

{:ok, _grpc_pid, grpc_bound} =
  GRPC.Server.start_endpoint(AshA2A.Transport.GRPC.Server.Endpoint, grpc_port)

IO.puts("TCK SUT gRPC listening on 127.0.0.1:#{grpc_bound}")
Process.sleep(:infinity)
