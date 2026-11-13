# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Transport.HTTPJSON do
  @moduledoc """
  A2A v1.0 HTTP+JSON/REST transport binding for `AshA2A.Agent` processes --
  the same owner-scoped surface as `AshA2A.Transport.Plug` (the JSON-RPC 2.0
  binding) with the v1.0 spec's native REST shape instead of JSON-RPC
  envelopes.

  The A2A v1.0 specification
  (https://a2a-protocol.org/latest/specification/) names the REST endpoints
  of this binding in §5.3 ("Method Mapping Reference"):

      | Operation    | REST endpoint             |
      |--------------|---------------------------|
      | Send message | `POST /message:send`      |
      | Stream message | `POST /message:stream`  |
      | List tasks   | `GET /tasks`              |
      | Get task     | `GET /tasks/{id}`         |
      | Cancel task  | `POST /tasks/{id}:cancel` |
      | Subscribe to task | `GET /tasks/{id}:subscribe` (POST: deprecated alias) |
      | Extended card | `GET /extendedAgentCard` (POST /agent: legacy alias) |

  Every route is also served under a leading `/{tenant}` segment (stripped when
  the remainder is a known route, recorded in `conn.private[:a2a][:tenant]`).

  plus the §8.2 well-known Agent Card (`GET /.well-known/agent-card.json`).
  §3.3.2/§5.4 map the error model onto HTTP statuses: validation errors ->
  `400 Bad Request`, resource not found -> `404 Not Found`, system errors ->
  `500`/`503`; the §3.3/§11.6 error body is the AIP-193 envelope
  `{"error": {"code": <HTTP status>, "status": <gRPC status name>,
  "message": ..., "details": [...]}}` (AIP-193 pins `error.code` to the HTTP
  status code; the well-known `google.rpc.ErrorInfo` detail objects keep
  their `@type` and the A2A code travels inside them). Errors are mapped
  through `AshA2A.Protocol.JSONRPC.Error` (whose constructors stamp
  `google.rpc.ErrorInfo` payloads read-only), consumed through
  `Error.to_map/1`.

  ## Routes

      GET  /.well-known/agent-card.json   agent card, served through the same
                                          encode path as the JSON-RPC plug
                                          (AshA2A.Transport.Plug.agent_card_json/3)
      POST /message:send                  MessageSendParams body; 200 with the
                                          SendMessageResponse oneof wrapper
                                          `{"task": ...}` | `{"message": ...}`
      POST /message:stream                MessageSendParams body; SSE
                                          (`text/event-stream`), one
                                          StreamResponse JSON object per
                                          `data:` frame
      GET  /tasks                         200 list envelope (`tasks`,
                                          `totalSize`, `pageSize`,
                                          `nextPageToken`, the same shape as
                                          the JSON-RPC `tasks/list` result);
                                          query parameters pageSize/pageToken/
                                          status/contextId/statusTimestampAfter/
                                          historyLength/includeArtifacts
      GET  /tasks/{id}                    200 task JSON | 404 error body
      POST /tasks/{id}:cancel             200 task JSON | 404 | 400 (a terminal
                                          task is TaskNotCancelable -> 400)
      GET  /tasks/{id}:subscribe          SSE: task snapshot frame first, then
                                          follow events until final; POST is a
                                          deprecated alias. Unknown/foreign
                                          task -> 404 TaskNotFound; terminal
                                          task -> 400 UnsupportedOperation

  A2A v1.1 additions (see the `/message:live` section below for the live
  contract): `POST /message:live` (SSE downlink; uplink calls answer the ack
  Task only), `GET /tasks/{id}?timelineLength=&currentGeneration=` (long-poll,
  held up to `config :ash_a2a, :long_poll_timeout_ms`), `GET /tasks?timelineLength=`,
  `:subscribe?lastSeenGeneration=` (no snapshot frame when set),
  `configuration.ifGenerationMatch` (stale -> 409 `-32010`
  TASK_GENERATION_MISMATCH), `configuration.timelineLength`,
  `artifactUpdates` (refused 400 unless `capabilities.user_artifacts`), event
  generations on every statusUpdate/artifactUpdate frame, `messageUpdate`
  frames only for `A2A-Version >= 1.1`, and `protocolVersion` passthrough on
  push-config set.

  plus the push-notification-config CRUD routes and the authenticated
  extended-card route. The push CRUD serves the §5.3/TCK collection path
  `pushNotificationConfigs` (plural) and keeps the historical singular
  `pushNotificationConfig` spelling as an alias (`AshA2A.Protocol.Client`'s
  REST mode speaks the singular form):

      POST /tasks/{id}/pushNotificationConfigs          set: body
                                                        {"pushNotificationConfig": {...}}
                                                        (the config object itself is
                                                        also accepted); 200 with the
                                                        TaskPushNotificationConfig
                                                        {"taskId", "pushNotificationConfig"}
                                                        shape
      GET  /tasks/{id}/pushNotificationConfigs          200 [TaskPushNotificationConfig]
      GET  /tasks/{id}/pushNotificationConfigs/{cid}    200 config | 400 when missing
      DELETE /tasks/{id}/pushNotificationConfigs/{cid}  200 `null`

  The four push verbs delegate to the very same `AshA2A.A2ATransport.PushConfigRPC`
  handlers the JSON-RPC binding dispatches (`tasks/pushNotificationConfig/{set,get,
  list,delete}` against the named `:transport`'s `PushConfigStore`), so both
  bindings answer identical error envelopes by construction: unknown or foreign
  task -> `-32001` (404 here), refused webhook URL -> `-32602` with the
  `refused_webhook_*` detail, missing config on get -> `-32602` with the
  "push notification config not found" detail (delete is idempotent per TCK
  PUSH-DEL-002 and answers success on a miss). When push notifications are not
  enabled (`:push_notifications` false, the default, or no running `:transport`)
  every push route answers `400` with the `-32003`
  `PUSH_NOTIFICATION_NOT_SUPPORTED` `ErrorInfo` -- never a 404, so the routes'
  existence is not disclosed while the feature is off.

      GET  /extendedAgentCard            (also `POST /agent`, legacy alias, and
                                         both under `/{tenant}`) authenticated extended agent card: the
                                         same provider flow as
                                         `AshA2A.A2ATransport.ExtendedCard`
                                         (2-arity fun or `{m, f, a}` called
                                         through `AshA2A.CallbackRegistry`).
                                         No verified identity -> `401` with a
                                         `Bearer` challenge and a `-32600`
                                         envelope; no provider -> `400` with the
                                         `-32007` `ErrorInfo`; provider error ->
                                         `-32007` -- the public card is never
                                         substituted. Success is the
                                         provider-extended card itself, stripped
                                         of the internal credential keys.

  Subscribing to a terminal task answers `400` with an `UNSUPPORTED_OPERATION`
  `ErrorInfo`; on an unknown or foreign task `404` with
  `TaskNotFound` (TCK STREAM-SUB-004, §5.4 status mapping). A recognized path
  with the wrong method answers `405` with an `allow` header; anything else
  answers `404`.

  ## Ownership and auth

  Task reads, lists and cancels are owner-scoped exactly like
  `AshA2A.Transport.Plug` (SEC-01): a task is answered only for the verified
  principal in `conn.private[:a2a][:auth]`; anyone else's (or an unknown) task
  is `404` -- never `403` -- so existence is not revealed, and a `GET /tasks`
  listing only ever contains tasks the verified caller owns (the same
  `AshA2A.Transport.Runtime.list_tasks_for/3` path the JSON-RPC binding
  takes). The verified `"a2a.auth"` is
  merged into call metadata last, so a caller-supplied `"metadata"` field can
  never forge it, and task results are stripped of `"a2a.auth"`, the owner
  key and the internal `:stream` metadata before encoding.

  ## Content negotiation and body bound

  Responses are `application/json` by default (TCK-safe); the `:content_type`
  option changes the default, and an `Accept` containing `application/a2a+json`
  (§14.1.1) is answered with `application/a2a+json`. Requests with either
  content type are accepted. `:versions` (default `Version.supported_default/0`)
  sets the supported `A2A-Version`s; `A2A-Version` / `A2A-Extensions` also arrive
  as same-named query parameters when the header is absent. A missing required
  extension (`:extensions` option) answers `400` with `-32008`; activated URIs
  echo in the `a2a-extensions` response header. The JSON body read is capped by `:max_body_bytes`
  (default 1,000,000, mirroring `AshA2A.Transport.Plug`): an over-cap body is
  refused `400` before parse. The `A2A-Version` service parameter arrives as
  an HTTP header per §11.2 and is gated exactly like
  `AshA2A.Transport.Plug.handle_json_rpc/2`: a supported (or absent, `0.3`
  per §3.6.2) version dispatches with the negotiated version echoed in the
  `a2a-version` response header; an unsupported version answers `400` with
  the `VersionNotSupportedError` (-32009) envelope and echoes the rejected
  value (§3.6.2).

  Mount it like `AshA2A.Transport.Plug`:

      plug AshA2A.Transport.HTTPJSON, agent: MyAgent, base_url: "https://x"

  Passing `serve_schemas: true` (with the `:schema_index` capability-index
  source) also mounts the machine-readable schema endpoints
  (`AshA2A.Transport.SchemaEndpoints`): `GET /.well-known/agent-card.schema.json`
  and `GET /.well-known/skills.schema.json`. Default off -- both paths then
  answer `404` like any other unserved path.
  """

  @behaviour Plug

  import Plug.Conn

  alias AshA2A.A2ATransport.{ExtendedCard, PushConfigRPC}
  alias AshA2A.Protocol.JSONRPC.{Error, Request}
  alias AshA2A.Transport.{Principal, Runtime, SafeError}

  @default_max_body_bytes 1_000_000
  @json_ct "application/json"
  @a2a_json_ct "application/a2a+json"
  @subscribe_heartbeat_ms 15_000
  @subscribe_max_idle_ms 300_000
  @tenant_keys ["ash_a2a.tenant", "a2a.tenant"]

  # `/tasks/{id}:cancel` / `/tasks/{id}:subscribe`: the v1.0 REST binding's
  # verb-suffix route shape (`:verb` after the resource id in the final path
  # segment). A binary suffix cannot be matched with `prefix <> ":verb"` (the
  # left operand of `<>` in a match needs a known size), so the suffix is
  # checked in a guard.
  defguardp is_cancel_segment(segment)
            when is_binary(segment) and byte_size(segment) > 7 and
                   binary_part(segment, byte_size(segment) - 7, 7) == ":cancel"

  defguardp is_subscribe_segment(segment)
            when is_binary(segment) and byte_size(segment) > 10 and
                   binary_part(segment, byte_size(segment) - 10, 10) == ":subscribe"

  @typedoc "Pinned init options map produced by `init/1`."
  @type opts :: %{
          required(:agent) => module(),
          required(:base_url) => String.t() | nil,
          required(:agent_card_path) => [String.t(), ...],
          required(:metadata) => map(),
          required(:max_body_bytes) => pos_integer(),
          required(:transport) => atom() | nil,
          required(:push_notifications) => boolean(),
          required(:extended_card) =>
            (map(), map() -> {:ok, map()} | {:error, term()})
            | {module(), atom(), list()}
            | nil,
          required(:content_type) => String.t(),
          required(:versions) => [String.t()],
          required(:extensions) => list(),
          required(:serve_schemas) => boolean(),
          required(:schema_index) =>
            module() | (-> [AshA2A.Skill.t()]) | [AshA2A.Skill.t()] | nil
        }

  @doc "Typed transport refusal codes, classified for S42 totality."
  @spec __sa2a_refusal_codes__() :: %{atom() => atom()}
  def __sa2a_refusal_codes__ do
    %{
      body_too_large: :refused_bounds,
      parse_error: :refused_structure,
      invalid_history_length: :refused_structure
    }
  end

  @impl Plug
  @spec init(keyword()) :: opts()
  # Idempotent: a runner that re-invokes `init/1` on the already-pinned map
  # (Bandit calls `init/1` again on `{plug, opts}` options) passes it through.
  def init(opts) when is_map(opts), do: opts

  def init(opts) do
    %{
      agent: Keyword.fetch!(opts, :agent),
      base_url: Keyword.get(opts, :base_url),
      agent_card_path: Keyword.get(opts, :agent_card_path, [".well-known", "agent-card.json"]),
      metadata: Keyword.get(opts, :metadata, %{}),
      max_body_bytes: Keyword.get(opts, :max_body_bytes, @default_max_body_bytes),
      transport: Keyword.get(opts, :transport),
      push_notifications: Keyword.get(opts, :push_notifications, false),
      extended_card: validate_provider!(Keyword.get(opts, :extended_card)),
      content_type: Keyword.get(opts, :content_type, @json_ct),
      versions: Keyword.get(opts, :versions, AshA2A.Protocol.Version.supported_default()),
      extensions: AshA2A.Protocol.Extension.compile(Keyword.get(opts, :extensions, []))
    }
    |> Map.merge(AshA2A.Transport.SchemaEndpoints.init(opts))
  end

  # Same provider contract as `AshA2A.A2ATransport.Plug` (fail closed at init).
  defp validate_provider!(nil), do: nil
  defp validate_provider!(fun) when is_function(fun, 2), do: fun
  defp validate_provider!({m, f, a} = mfa) when is_atom(m) and is_atom(f) and is_list(a), do: mfa

  defp validate_provider!(other),
    do:
      raise(
        ArgumentError,
        ":extended_card must be a 2-arity fun or {m, f, a}, got #{inspect(other)}"
      )

  @impl Plug
  @spec call(Plug.Conn.t(), opts()) :: Plug.Conn.t()
  def call(conn, opts) do
    conn =
      conn
      |> put_private(:a2a_http_json_ct, response_content_type(conn, opts))
      |> strip_tenant(opts)

    # One request span per HTTP request (W15); `ok?` is false on 4xx/5xx.
    AshA2A.Protocol.Telemetry.request_span(:http_json, %{route: route_label(conn)}, fn ->
      conn = route(conn, opts)
      {conn, is_integer(conn.status) and conn.status < 400}
    end)
  end

  # Low-cardinality route label (ids never appear in telemetry metadata).
  defp route_label(%{method: method, path_info: path}) do
    shape =
      case path do
        ["tasks", id] when is_binary(id) ->
          cond do
            is_cancel_segment(id) -> "/tasks/{id}:cancel"
            is_subscribe_segment(id) -> "/tasks/{id}:subscribe"
            true -> "/tasks/{id}"
          end

        ["tasks", _, c | rest] ->
          "/tasks/{id}/" <> c <> if(rest == [], do: "", else: "/{configId}")

        other ->
          "/" <> Enum.join(other, "/")
      end

    method <> " " <> shape
  end

  # Default `application/json` (TCK-safe); `application/a2a+json` (§14.1.1)
  # when the caller's Accept asks for it, or when the plug is configured with
  # `content_type: "application/a2a+json"`.
  defp response_content_type(conn, opts) do
    accept = conn |> get_req_header("accept") |> Enum.join(",") |> String.downcase()
    if String.contains?(accept, @a2a_json_ct), do: @a2a_json_ct, else: opts.content_type
  end

  # `/{tenant}/<route>`: the leading segment is a tenant only when the whole
  # path is NOT already a known route and the remainder IS one (so `tasks`,
  # `message:send`, `agent`, `extendedAgentCard` as first segments are never
  # swallowed as tenants).
  defp strip_tenant(%{path_info: [tenant | rest]} = conn, opts) when rest != [] do
    if known_route?(conn.path_info, opts) or not known_route?(rest, opts) do
      conn
    else
      a2a = conn.private |> Map.get(:a2a, %{}) |> Map.put(:tenant, tenant)
      conn |> put_private(:a2a, a2a) |> Map.put(:path_info, rest)
    end
  end

  defp strip_tenant(conn, _opts), do: conn

  defp known_route?(["message:send"], _), do: true
  defp known_route?(["message:stream"], _), do: true
  defp known_route?(["message:live"], _), do: true
  defp known_route?(["tasks"], _), do: true
  defp known_route?(["tasks", id], _) when is_binary(id), do: true
  defp known_route?(["tasks", _, c], _) when c in ["pushNotificationConfigs", "pushNotificationConfig"], do: true
  defp known_route?(["tasks", _, c, _], _) when c in ["pushNotificationConfigs", "pushNotificationConfig"], do: true
  defp known_route?(["agent"], _), do: true
  defp known_route?(["extendedAgentCard"], _), do: true
  defp known_route?(path, %{agent_card_path: path}), do: true
  defp known_route?(path, _), do: Enum.member?(AshA2A.Transport.SchemaEndpoints.paths(), path)

  defp route(%{method: "GET", path_info: path} = conn, %{agent_card_path: path} = opts) do
    serve_agent_card(conn, opts)
  end

  defp route(%{path_info: path} = conn, %{agent_card_path: path}) do
    method_not_allowed(conn, "GET")
  end

  # Every non-card route runs behind the §3.6 `A2A-Version` gate, mirroring
  # `AshA2A.Transport.Plug.handle_json_rpc/2`: an unsupported version answers
  # `VersionNotSupportedError` (-32009) with HTTP 400 and still echoes the
  # rejected version (§3.6.2). The version (and extensions) may arrive as the
  # `A2A-Version` / `A2A-Extensions` header or, when the header is absent, as
  # the same-named query parameter (§11.2). Required extensions missing ->
  # -32008 with HTTP 400; activated URIs echo in `a2a-extensions`.
  defp route(conn, opts) do
    alias AshA2A.Protocol.{Extension, Version}
    conn = Plug.Conn.fetch_query_params(conn)
    version = Version.parse_header(service_param(conn, "a2a-version", "A2A-Version"))
    requested = Extension.parse_header(service_param(conn, "a2a-extensions", "A2A-Extensions"))

    with :ok <- Version.validate(version, opts.versions),
         :ok <- Extension.validate_required(opts.extensions, requested),
         {:ok, _acts, uris} <- Extension.activate(opts.extensions, requested, %{conn: conn}) do
      conn = put_resp_header(conn, "a2a-version", version)
      conn = put_negotiated_version(conn, version)
      conn = echo_trace(conn)
      conn = if uris == [], do: conn, else: put_resp_header(conn, "a2a-extensions", Enum.join(uris, ", "))
      dispatch(conn, opts)
    else
      {:error, rejected} when is_binary(rejected) ->
        conn
        |> put_resp_header("a2a-version", rejected)
        |> send_error(400, Error.version_not_supported(rejected))

      {:error, missing} when is_list(missing) ->
        send_error(
          conn,
          400,
          Error.extension_support_required("Client missing required extensions: " <> Enum.join(missing, ", "))
        )

      {:error, %Error{} = err} ->
        send_error(conn, status_for(err), err)
    end
  end

  # The negotiated A2A-Version, kept in `conn.private[:a2a][:version]` so
  # v1.1-only frames (messageUpdate) can be gated per consumer.
  defp put_negotiated_version(conn, version) do
    a2a = conn.private |> Map.get(:a2a, %{}) |> Map.put(:version, version)
    put_private(conn, :a2a, a2a)
  end

  defp v11?(conn) do
    version = conn.private |> Map.get(:a2a, %{}) |> Map.get(:version)
    is_binary(version) and AshA2A.Protocol.Version.at_least?(version, "1.1")
  end

  # W17: a valid inbound traceparent/tracestate is echoed on the response
  # (SSE included: headers go out with `send_chunked/2`).
  defp echo_trace(conn) do
    [] |> AshA2A.Trace.W3C.inject(AshA2A.Trace.W3C.extract(conn))
    |> Enum.reduce(conn, fn {k, v}, conn -> put_resp_header(conn, k, v) end)
  end

  # Header context wins over metadata context (W17); the resolved context is
  # stamped on the message metadata, where the dispatcher reads `traceparent`.
  defp with_trace(%{metadata: md} = message, conn) do
    md = if is_map(md), do: md, else: %{}
    ctx = AshA2A.Trace.W3C.resolve(AshA2A.Trace.W3C.extract(conn), AshA2A.Trace.W3C.from_metadata(md))

    md =
      Enum.reduce(ctx, md, fn {k, v}, acc -> Map.put(acc, Atom.to_string(k), v) end)

    %{message | metadata: md}
  end

  defp service_param(conn, header, query_key) do
    case get_req_header(conn, header) do
      [] ->
        case conn.query_params do
          %{^query_key => value} when is_binary(value) -> value
          _ -> nil
        end

      values ->
        values
    end
  end

  defp dispatch(%{method: "POST", path_info: ["message:send"]} = conn, opts) do
    handle_send(conn, opts)
  end

  defp dispatch(%{path_info: ["message:send"]} = conn, _opts) do
    method_not_allowed(conn, "POST")
  end

  defp dispatch(%{method: "POST", path_info: ["message:stream"]} = conn, opts) do
    handle_stream(conn, opts)
  end

  defp dispatch(%{path_info: ["message:stream"]} = conn, _opts) do
    method_not_allowed(conn, "POST")
  end

  # A2A v1.1 SendLiveMessage (`POST /message:live`, also under `/{tenant}`).
  defp dispatch(%{method: "POST", path_info: ["message:live"]} = conn, opts) do
    handle_live(conn, opts)
  end

  defp dispatch(%{path_info: ["message:live"]} = conn, _opts) do
    method_not_allowed(conn, "POST")
  end

  defp dispatch(%{method: "GET", path_info: ["tasks", id]} = conn, opts)
       when is_binary(id) and byte_size(id) > 0 and not is_cancel_segment(id) and
              not is_subscribe_segment(id) do
    handle_get(conn, opts, id)
  end

  defp dispatch(%{method: "GET", path_info: ["tasks", segment]} = conn, _opts)
       when is_cancel_segment(segment) do
    method_not_allowed(conn, "POST")
  end

  defp dispatch(%{method: "POST", path_info: ["tasks", segment]} = conn, opts)
       when is_cancel_segment(segment) do
    handle_cancel(conn, opts, binary_part(segment, 0, byte_size(segment) - 7))
  end

  defp dispatch(%{method: "GET", path_info: ["tasks"]} = conn, opts) do
    handle_list(conn, opts)
  end

  # §3.1.6/TCK STREAM-SUB-004: a `:subscribe` for an unknown (or foreign) task
  # answers TaskNotFoundError (404). GET is the current verb; POST is the
  # deprecated alias.
  defp dispatch(%{method: method, path_info: ["tasks", segment]} = conn, opts)
       when method in ["GET", "POST"] and is_subscribe_segment(segment) do
    handle_subscribe(conn, opts, binary_part(segment, 0, byte_size(segment) - 10))
  end

  defp dispatch(%{path_info: ["tasks", segment]} = conn, _opts)
       when is_subscribe_segment(segment) do
    method_not_allowed(conn, "GET, POST")
  end

  # A recognized task path hit with the wrong method answers 405 with an
  # `allow` header, not 404.
  defp dispatch(%{path_info: ["tasks", _]} = conn, _opts) do
    method_not_allowed(conn, "GET")
  end

  # -- /tasks/{id}/pushNotificationConfig[/{configId}] --------------------------
  #
  # The v1.0 REST mapping of the `tasks/pushNotificationConfig/*` JSON-RPC
  # methods. All four verbs run through the same `AshA2A.A2ATransport.PushConfigRPC`
  # handlers the JSON-RPC binding uses (identical error envelopes by
  # construction), gated fail-closed on push notifications being enabled: the
  # disabled answer is the -32003 ErrorInfo envelope, never a 404.

  # The push-config CRUD routes serve the §5.3/TCK REST path
  # `pushNotificationConfigs` (plural, the collection resource) and keep the
  # historical singular `pushNotificationConfig` spelling as an alias —
  # `AshA2A.Protocol.Client`'s REST mode and the repo's courts speak the
  # singular form.
  defp dispatch(%{path_info: ["tasks", id, "pushNotificationConfigs"]} = conn, opts)
       when is_binary(id) and byte_size(id) > 0 do
    push_collection(conn, opts, id)
  end

  defp dispatch(%{path_info: ["tasks", id, "pushNotificationConfigs", config_id]} = conn, opts)
       when is_binary(id) and byte_size(id) > 0 and is_binary(config_id) and byte_size(config_id) > 0 do
    push_item(conn, opts, id, config_id)
  end

  defp dispatch(%{path_info: ["tasks", id, "pushNotificationConfig"]} = conn, opts)
       when is_binary(id) and byte_size(id) > 0 do
    push_collection(conn, opts, id)
  end

  defp dispatch(%{path_info: ["tasks", id, "pushNotificationConfig", config_id]} = conn, opts)
       when is_binary(id) and byte_size(id) > 0 and is_binary(config_id) and byte_size(config_id) > 0 do
    push_item(conn, opts, id, config_id)
  end

  # -- POST /agent (authenticated extended agent card) ---------------------------

  defp dispatch(%{method: "GET", path_info: ["extendedAgentCard"]} = conn, opts) do
    handle_extended_card(conn, opts)
  end

  defp dispatch(%{path_info: ["extendedAgentCard"]} = conn, _opts) do
    method_not_allowed(conn, "GET")
  end

  # Legacy alias (pre-`GET /extendedAgentCard` spelling).
  defp dispatch(%{method: "POST", path_info: ["agent"]} = conn, opts) do
    handle_extended_card(conn, opts)
  end

  defp dispatch(%{path_info: ["agent"]} = conn, _opts) do
    method_not_allowed(conn, "POST")
  end

  # Machine-readable schema endpoints (mounted only when `serve_schemas: true`;
  # disabled the helper answers :next and these paths fall through to 404).
  # Membership is tested in the body, not a guard: `SchemaEndpoints.paths/0`
  # is a runtime list, and a guard's `in` right operand must be compile-time.
  defp dispatch(%{path_info: path} = conn, opts) do
    if Enum.member?(AshA2A.Transport.SchemaEndpoints.paths(), path) do
      case AshA2A.Transport.SchemaEndpoints.serve(conn, opts) do
        %Plug.Conn{} = conn -> conn
        :next -> not_found(conn)
      end
    else
      not_found(conn)
    end
  end

  defp dispatch(conn, _opts), do: not_found(conn)

  # -- push-config CRUD ----------------------------------------------------------

  defp push_collection(conn, opts, task_id) do
    unless_push_enabled(conn, opts, fn ->
      case conn.method do
        "POST" ->
          with {:ok, params, conn} <- read_json_body(conn, opts.max_body_bytes) do
            # The body is the TaskPushNotificationConfig resource; the config
            # object itself is also accepted (taskId comes from the path).
            config = push_protocol_version(params["pushNotificationConfig"] || params, params)

            dispatch_push(
              conn,
              opts,
              "tasks/pushNotificationConfig/set",
              %{"taskId" => task_id, "pushNotificationConfig" => config}
            )
          else
            # `read_json_body/2` is this `with`'s only generator, so no
            # `%Error{}` can reach this else (unlike `handle_send/2`, whose
            # `call_agent/3` step produces one); the %Error clause there is
            # live, this one never was.
            {:error, kind} when kind in [:body_too_large, :parse_error] -> body_error(conn, kind)
          end

        "GET" ->
          conn = Plug.Conn.fetch_query_params(conn)

          params =
            conn.query_params
            |> Map.take(["pageSize", "pageToken"])
            |> Map.put("id", task_id)

          dispatch_push(conn, opts, "tasks/pushNotificationConfig/list", params)

        _other ->
          method_not_allowed(conn, "GET, POST")
      end
    end)
  end

  # v1.1: `protocolVersion` on the TaskPushNotificationConfig passes through
  # to the store (a top-level request value fills a config that omits it).
  defp push_protocol_version(%{} = config, %{"protocolVersion" => pv}) when is_binary(pv) do
    if Map.has_key?(config, "protocolVersion"), do: config, else: Map.put(config, "protocolVersion", pv)
  end

  defp push_protocol_version(config, _params), do: config

  defp push_item(conn, opts, task_id, config_id) do
    unless_push_enabled(conn, opts, fn ->
      case conn.method do
        "GET" ->
          dispatch_push(conn, opts, "tasks/pushNotificationConfig/get", %{
            "id" => task_id,
            "pushNotificationConfigId" => config_id
          })

        "DELETE" ->
          dispatch_push(conn, opts, "tasks/pushNotificationConfig/delete", %{
            "id" => task_id,
            "pushNotificationConfigId" => config_id
          })

        _other ->
          method_not_allowed(conn, "GET, DELETE")
      end
    end)
  end

  # Fail closed when push notifications are off: the -32003 envelope for every
  # verb, so the routes' existence is not revealed (W6's pinned finding).
  defp unless_push_enabled(conn, opts, continuation) do
    if push_enabled?(opts) do
      continuation.()
    else
      send_error(conn, 400, Error.push_notification_not_supported())
    end
  end

  # Same gate as `AshA2A.A2ATransport.Plug.push_enabled?/1`: the flag AND a
  # running transport instance (the push store hangs off the transport).
  defp push_enabled?(opts),
    do: opts.push_notifications and AshA2A.A2ATransport.running?(opts.transport)

  # Identical envelopes to the JSON-RPC binding by construction: the handler is
  # the very same `PushConfigRPC.handle/4` call `AshA2A.A2ATransport.Plug`
  # dispatches; only the wrapper differs (REST: the error map is the body with
  # `"data"` renamed `"details"`, paired with the §5.4 HTTP status).
  defp dispatch_push(conn, opts, method, params) do
    case PushConfigRPC.handle(method, params, nil, push_ctx(conn, opts)) do
      %{"result" => result} ->
        send_json(conn, 200, push_result(method, result))

      %{"error" => error} ->
        send_rest_error(conn, error)
    end
  end

  # REST shapes (§5.3): list is `{configs, nextPageToken}`, delete is `{}`.
  # Accepts both the bare-list and the v1 `%{"configs", "nextPageToken"}` shapes.
  defp push_result("tasks/pushNotificationConfig/list", configs) when is_list(configs),
    do: %{"configs" => configs, "nextPageToken" => ""}

  defp push_result("tasks/pushNotificationConfig/list", %{"configs" => configs} = result),
    do: %{"configs" => configs, "nextPageToken" => Map.get(result, "nextPageToken") || ""}

  defp push_result("tasks/pushNotificationConfig/delete", _), do: %{}

  # set echoes the nested legacy shape when the body was nested: flatten to the
  # v1 TaskPushNotificationConfig the other verbs answer.
  defp push_result("tasks/pushNotificationConfig/set", %{"pushNotificationConfig" => %{} = inner} = result),
    do: Map.put(inner, "taskId", result["taskId"])

  defp push_result(_method, result), do: result

  # The same ctx shape `AshA2A.A2ATransport.Plug.ctx/2` builds (read-only reuse).
  defp push_ctx(conn, opts) do
    %{
      agent: opts.agent,
      transport: opts.transport,
      push_opts: AshA2A.A2ATransport.TaskEvents.push_opts(opts.transport),
      principal: caller(conn),
      wire: :v1
    }
  end

  # -- POST /agent ---------------------------------------------------------------

  # The `AshA2A.A2ATransport.ExtendedCard` provider flow, mirrored with the REST
  # envelope: no provider -> -32007; provider but no verified identity -> 401
  # with a Bearer challenge; provider error -> -32007; success is the
  # provider-extended card, stripped of the internal credential keys. The public
  # card is never substituted for a failure.
  defp handle_extended_card(conn, opts) do
    if is_nil(opts.extended_card) do
      send_error(conn, 400, Error.authenticated_extended_card_not_configured())
    else
      case AshA2A.Protocol.Plug.Auth.get_identity(conn) do
        nil ->
          conn
          |> put_resp_header("www-authenticate", "Bearer")
          |> send_error(401, Error.invalid_request("authentication required"))

        identity ->
          base_url = AshA2A.Protocol.Plug.get_base_url(conn) || opts.base_url

          public =
            ExtendedCard.public_card(conn, %{
              a2a: %{base_url: base_url, agent: opts.agent, agent_card_opts: []}
            })

          case invoke_provider(opts.extended_card, identity, public) do
            {:ok, card} when is_map(card) ->
              # Per-caller body: never cacheable by a shared cache (mirrors
              # AshA2A.A2ATransport.ExtendedCard).
              conn
              |> put_resp_header("cache-control", "private, no-store")
              |> send_json(
                200,
                card
                |> strip_internal_keys()
                |> ExtendedCard.resign(%{a2a: %{agent_card_opts: opts[:agent_card_opts] || []}})
              )

            {:error, reason} ->
              send_error(
                conn,
                400,
                Error.authenticated_extended_card_not_configured(inspect(reason))
              )

            other ->
              send_error(
                conn,
                400,
                Error.authenticated_extended_card_not_configured(
                  "provider returned #{inspect(other)}"
                )
              )
          end
      end
    end
  end

  # The ExtendedCard provider contract (read-only reuse): a 2-arity fun, or an
  # `{m, f, a}` resolved through `AshA2A.CallbackRegistry` (a non-member yields
  # `{:error, %{code: :callback_not_permitted}}` without ever running).
  defp invoke_provider(provider, identity, public) do
    do_invoke(provider, identity, public)
  rescue
    e -> {:error, {:provider_raised, Exception.message(e)}}
  end

  defp do_invoke(fun, identity, public) when is_function(fun, 2), do: fun.(identity, public)

  defp do_invoke({m, f, a}, identity, public) when is_atom(m) and is_atom(f) and is_list(a),
    do: AshA2A.CallbackRegistry.invoke(m, f, [identity, public | a])

  defp do_invoke(other, _identity, _public),
    do: {:error, {:invalid_provider, other}}

  # Deep drop of the internal credential keys from every map in the card (the
  # same key set `AshA2A.A2ATransport.Ownership` strips from task payloads, kept
  # in sync by court) -- a provider cannot stream credentials onto the wire by
  # embedding them in skills, nested metadata or any other field.
  @internal_keys ["a2a.auth", "ash_a2a.owner", :stream]

  defp strip_internal_keys(%{} = card),
    do: card |> Map.drop(@internal_keys) |> Map.new(fn {k, v} -> {k, strip_internal_keys(v)} end)

  defp strip_internal_keys(list) when is_list(list), do: Enum.map(list, &strip_internal_keys/1)
  defp strip_internal_keys(other), do: other

  # -- agent card ------------------------------------------------------------

  defp serve_agent_card(conn, opts) do
    base_url = AshA2A.Protocol.Plug.get_base_url(conn) || opts.base_url

    if is_nil(base_url) do
      raise ArgumentError,
            "AshA2A.Transport.HTTPJSON requires :base_url for agent card requests"
    end

    card = GenServer.call(opts.agent, :get_agent_card)

    conn
    |> put_resp_content_type(Map.get(conn.private, :a2a_http_json_ct, @json_ct))
    |> send_resp(200, Jason.encode!(card_json(card, opts, base_url)))
  end

  # Same encode path as the JSON-RPC transport: the vendored encoder via the
  # transport plug's public `agent_card_json/3` (consumed read-only). The
  # capabilities are truthful for THIS binding: push is advertised only when
  # push routes are live, the extended card only when a provider is set.
  defp card_json(card, opts, base_url) do
    AshA2A.Transport.Plug.agent_card_json(
      card,
      %{
        agent_card_opts: [],
        push_notifications: push_enabled?(opts),
        extended_card: not is_nil(opts.extended_card),
        extensions: []
      },
      base_url
    )
  end

  # -- POST /message:send ------------------------------------------------------

  defp handle_send(conn, opts) do
    with {:ok, params, conn} <- read_json_body(conn, opts.max_body_bytes),
         :ok <- validate_message_params("message/send", params),
         {:ok, message} <- decode_message_opt(params),
         {:ok, result, push_config, cfg} <- execute_send(conn, opts, params, message) do
      case result do
        %AshA2A.Protocol.Task{} = task ->
          history = Request.history_length(configuration(params))
          attach_push(conn, opts, task, push_config)
          publish_task(opts, task)
          # v1.0 SendMessageResponse oneof wrapper (`{"task" | "message"}`):
          # the TCK validates the body against the SendMessageResponse schema
          # (additionalProperties: false, task|message keys only), so a bare
          # task at the root fails the matrix's DM-*/CORE-SEND schema class.
          send_json(conn, 200, %{"task" => encode_task(task, history, cfg.timeline_length)})

        %AshA2A.Protocol.Message{} = message ->
          {:ok, encoded} = AshA2A.Protocol.JSON.encode(message)
          send_json(conn, 200, %{"message" => encoded})
      end
    else
      {:error, %Error{} = error} ->
        send_error(conn, status_for(error), error)

      {:error, kind} when kind in [:body_too_large, :parse_error] ->
        body_error(conn, kind)

      {:error, reason} ->
        error = error_for(reason)
        send_error(conn, status_for(error), error)
    end
  end

  # Shared send pipeline for message:send and the live uplink/downlink send:
  # v1.1 configuration (timelineLength / ifGenerationMatch), inline push
  # admission, client `artifactUpdates` (user_artifacts capability gate), the
  # agent call, output-mode validation. `message` may be nil only for an
  # artifact-only request (the task is then named by the first update).
  defp execute_send(conn, opts, params, message, output_modes? \\ true) do
    with {:ok, cfg} <- v11_config(params),
         {:ok, push_config} <- inline_push(params, opts),
         {:ok, updates} <- decode_updates(params, opts),
         message = message && with_trace(message, conn),
         call_opts = call_opts(params, message, conn, opts, cfg),
         {:ok, result} <- run_send(opts.agent, message, updates, call_opts, params, cfg, conn),
         {:ok, result} <- maybe_output_modes(result, call_opts, output_modes?) do
      {:ok, result, push_config, cfg}
    end
  end

  defp maybe_output_modes(result, _call_opts, false), do: {:ok, result}

  defp maybe_output_modes(result, call_opts, true) do
    AshA2A.Protocol.InputModeValidator.apply_output_modes(
      result,
      Keyword.get(call_opts, :accepted_output_modes)
    )
  end

  # A non-negative int64 query/body value (integer or numeric string).
  defp nonneg(nil, _name), do: {:ok, nil}
  defp nonneg(n, _name) when is_integer(n) and n >= 0, do: {:ok, n}

  defp nonneg(s, name) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, Error.invalid_params("\"#{name}\" must be a non-negative integer")}
    end
  end

  defp nonneg(_other, name),
    do: {:error, Error.invalid_params("\"#{name}\" must be a non-negative integer")}

  defp v11_config(params) do
    cfg = configuration(params)

    with {:ok, timeline} <- nonneg(cfg["timelineLength"], "timelineLength"),
         {:ok, if_gen} <- nonneg(cfg["ifGenerationMatch"], "ifGenerationMatch") do
      {:ok, %{timeline_length: timeline, if_generation_match: if_gen}}
    end
  end

  # `artifactUpdates`: refused (-32004 -> 400 UNSUPPORTED_OPERATION) unless the
  # agent card declares `capabilities.user_artifacts`, BEFORE any work starts.
  defp decode_updates(params, opts) do
    case Map.get(params, "artifactUpdates") do
      nil ->
        {:ok, []}

      [] ->
        {:ok, []}

      raw when is_list(raw) ->
        with :ok <- AshA2A.Protocol.ClientArtifacts.check_user_artifacts(agent_card(opts.agent), raw) do
          case AshA2A.Protocol.ClientArtifacts.decode_updates(raw) do
            {:ok, decoded} -> {:ok, decoded}
            {:error, reason} -> {:error, Error.invalid_params("invalid artifactUpdates: " <> inspect(SafeError.redact(reason)))}
          end
        end

      _ ->
        {:error, Error.invalid_params("\"artifactUpdates\" must be an array")}
    end
  end

  defp agent_card(agent) do
    GenServer.call(agent, :get_agent_card)
  catch
    :exit, _ -> nil
  end

  # Message present -> normal call, then client artifacts applied to the
  # resulting task. Message absent (artifact-only) -> generation check against
  # the named, owned task, then the updates alone.
  defp run_send(agent, nil, updates, _call_opts, params, cfg, conn) do
    task_id = artifact_only_task_id(params)

    with true <- is_binary(task_id) or {:error, Error.invalid_params("artifact-only requests must name a taskId")},
         {:ok, task} <- owned_task(agent, scoped_caller(conn), task_id),
         :ok <- AshA2A.Protocol.ClientArtifacts.check_generation(task, cfg.if_generation_match),
         {:ok, task} <- GenServer.call(agent, {:apply_artifact_updates, task_id, updates}) do
      {:ok, task}
    else
      {:error, _} = error -> error
    end
  catch
    :exit, reason -> {:error, SafeError.internal(:internal_error, {:agent_exit, reason})}
  end

  defp run_send(agent, message, updates, call_opts, _params, _cfg, _conn) do
    with {:ok, result} <- call_agent(agent, message, call_opts) do
      apply_client_updates(agent, result, updates)
    end
  end

  defp apply_client_updates(_agent, result, []), do: {:ok, result}

  defp apply_client_updates(agent, %AshA2A.Protocol.Task{id: id}, updates) do
    GenServer.call(agent, {:apply_artifact_updates, id, updates})
  catch
    :exit, reason -> {:error, SafeError.internal(:internal_error, {:agent_exit, reason})}
  end

  defp apply_client_updates(_agent, result, _updates), do: {:ok, result}

  defp artifact_only_task_id(params) do
    case params["artifactUpdates"] do
      [%{"taskId" => id} | _] when is_binary(id) and id != "" -> id
      _ -> if is_binary(params["taskId"]) and params["taskId"] != "", do: params["taskId"]
    end
  end

  # Message is optional only when a non-empty `artifactUpdates` list is present.
  defp decode_message_opt(params) do
    case {params["message"], params["artifactUpdates"]} do
      {nil, [_ | _]} -> {:ok, nil}
      _ -> decode_message(params)
    end
  end

  # `configuration` tolerates non-map input (the schema check below refuses
  # it before any agent call; readers elsewhere must still never crash).
  defp configuration(params) do
    case params["configuration"] do
      %{} = configuration -> configuration
      _ -> %{}
    end
  end

  defp validate_message_params(method, params) do
    with :ok <- Request.validate_params(%Request{jsonrpc: "2.0", method: method, params: params}) do
      case params["configuration"] do
        nil -> :ok
        %{} -> :ok
        _ -> {:error, Error.invalid_params("\"configuration\" must be a JSON object")}
      end
    end
  end

  # Same contract as the JSON-RPC plug: `configuration.pushNotificationConfig`
  # is honored when push is enabled (URL admitted BEFORE any work starts) and
  # refused with -32003 otherwise -- never silently ignored.
  defp inline_push(params, opts) do
    case configuration(params)["pushNotificationConfig"] do
      nil ->
        {:ok, nil}

      config ->
        if push_enabled?(opts) do
          with :ok <- PushConfigRPC.preflight(config, AshA2A.A2ATransport.TaskEvents.push_opts(opts.transport)),
               do: {:ok, config}
        else
          {:error, Error.push_notification_not_supported()}
        end
    end
  end

  defp attach_push(_conn, _opts, _task, nil), do: :ok

  defp attach_push(conn, opts, task, config),
    do: PushConfigRPC.attach_inline(task.id, config, push_ctx(conn, opts))

  # Publishes the task through the shared per-task event log so configured
  # webhooks (and any SSE subscriber) observe REST-created/cancelled tasks
  # exactly like JSON-RPC ones. A no-op when no transport is configured.
  defp publish_task(%{transport: nil}, _task), do: :ok

  defp publish_task(%{transport: transport}, task) do
    if AshA2A.A2ATransport.running?(transport) do
      wire = encode_task(task, nil)
      final? = closed_state?(task.status.state)
      AshA2A.A2ATransport.TaskEvents.publish(transport, task.id, "task", %{"task" => wire}, final?)
    end

    :ok
  end

  # Same closed-state set as AshA2A.A2ATransport.Plug (a paused task is a
  # closed stream segment, not a terminal task).
  defp closed_state?(state),
    do: state in [:completed, :canceled, :cancelled, :failed, :rejected, :input_required, :auth_required]

  # -- POST /message:stream -----------------------------------------------------
  #
  # The §11 streaming binding: `text/event-stream`, one StreamResponse JSON
  # object per `data:` frame (the same `{"task" | "statusUpdate" |
  # "artifactUpdate" | "message"}` discriminator wrapper the codec's
  # `encode_stream_response/1` emits for the JSON-RPC binding's SSE frames,
  # minus the JSON-RPC envelope). The agent-call flow mirrors
  # `AshA2A.Transport.Plug.stream_message/4` (read-only reuse): a task whose
  # metadata carries a `:stream` enum emits its chunks as framed
  # TaskArtifactUpdateEvents sharing one artifactId (`append`/`lastChunk`),
  # a plain task replays task -> artifact events -> final status, a Message
  # answer is a single frame, and every failure before the stream starts is
  # the AIP-193 JSON error envelope.

  defp handle_stream(conn, opts) do
    with {:ok, params, conn} <- read_json_body(conn, opts.max_body_bytes),
         :ok <- validate_message_params("message/stream", params),
         {:ok, message} <- decode_message(params),
         {:ok, result, push_config, _cfg} <- execute_send(conn, opts, params, message, false) do
      conn = start_sse(conn)

      case result do
        %AshA2A.Protocol.Task{metadata: %{stream: enum}} = task ->
          attach_push(conn, opts, task, push_config)
          conn = conn |> send_frame(Runtime.wire_task(task)) |> send_message_updates(task)
          stream_parts(conn, opts, task, enum)

        %AshA2A.Protocol.Message{} = msg ->
          {:ok, encoded} = AshA2A.Protocol.JSON.encode(msg)
          send_raw_frame(conn, %{"message" => encoded})

        %AshA2A.Protocol.Task{} = task ->
          conn = conn |> send_frame(Runtime.wire_task(task)) |> send_message_updates(task)

          conn =
            Enum.reduce(List.wrap(task.artifacts), conn, fn artifact, conn ->
              send_frame(
                conn,
                AshA2A.Protocol.Event.ArtifactUpdate.new(task.id, artifact,
                  context_id: task.context_id,
                  generation: artifact_generation(artifact, task)
                )
              )
            end)

          # A non-streaming task already has its real state: report THAT,
          # never a synthesized :completed.
          final_status(conn, task, task.status)
      end
    else
      {:error, %Error{} = error} ->
        send_error(conn, status_for(error), error)

      {:error, kind} when kind in [:body_too_large, :parse_error] ->
        body_error(conn, kind)

      {:error, reason} ->
        error = error_for(reason)
        send_error(conn, status_for(error), error)
    end
  end

  # Same chunk framing as `AshA2A.Transport.Plug.stream_parts/4`: chunk i's
  # frame is emitted when chunk i+1 arrives (so `append: true` is known), the
  # drain emits the pending final chunk with `lastChunk: true`; all frames of
  # one streamed artifact share the pre-minted `:stream_artifact_id`.
  defp stream_parts(conn, opts, task, enum) do
    artifact_id =
      Map.get(task.metadata, :stream_artifact_id) ||
        AshA2A.Protocol.ID.generate("art")

    {conn, pending} =
      Enum.reduce(enum, {conn, nil}, fn part, {conn, pending} ->
        case pending do
          nil ->
            {conn, {:chunk, part, false}}

          {:chunk, prev_part, append?} ->
            conn = send_chunk_frame(conn, task, artifact_id, prev_part, append_opts(append?))
            {conn, {:chunk, part, true}}
        end
      end)

    conn =
      case pending do
        nil -> conn
        {:chunk, part, append?} -> send_chunk_frame(conn, task, artifact_id, part, append_opts(append?) ++ [last_chunk: true])
      end

    # The agent's stream wrapper records the real post-stream state; this
    # call is ordered after it. Falls back to :completed only when the task
    # cannot be read back.
    case owned_task(opts.agent, :internal, task.id, task) do
      {:ok, done} -> final_status(conn, done, done.status)
      _ -> final_status(conn, task, :completed, nil)
    end
  rescue
    error ->
      %{ref: ref} = SafeError.internal(:internal_error, error, __STACKTRACE__)
      final_status(conn, task, :failed, "Error: internal_error ref=#{ref}")
  end

  # The pump-side read of the task's real state: unscoped (the stream already
  # belongs to this caller), unlike the owner-scoped `owned_task/3`.
  defp owned_task(agent, :internal, task_id, _task) do
    case GenServer.call(agent, {:get_task, task_id}) do
      {:ok, done} -> {:ok, done}
      other -> other
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp append_opts(true), do: [append: true]
  defp append_opts(false), do: []

  defp send_chunk_frame(conn, task, artifact_id, part, opts) do
    artifact =
      [part]
      |> AshA2A.Protocol.Artifact.new()
      |> struct(artifact_id: artifact_id)

    event =
      AshA2A.Protocol.Event.ArtifactUpdate.new(
        task.id,
        artifact,
        [context_id: task.context_id, generation: AshA2A.Protocol.Task.Generation.generation_of(task)] ++ opts
      )

    send_frame(conn, event)
  end

  # Event generation of an artifact frame: the artifact's own stamp
  # (end_generation, else start_generation), falling back to the task's.
  defp artifact_generation(artifact, task) do
    Map.get(artifact, :end_generation) || Map.get(artifact, :start_generation) ||
      AshA2A.Protocol.Task.Generation.generation_of(task)
  end

  # v1.1 messageUpdate frames: one per client message on the task timeline,
  # sent ONLY to consumers that negotiated A2A-Version >= 1.1.
  defp send_message_updates(conn, task) do
    if v11?(conn) do
      task.timeline
      |> List.wrap()
      |> Enum.reduce(conn, fn
        %AshA2A.Protocol.TimelineEntry{entry: {:message, message}, generation: gen}, conn ->
          send_frame(
            conn,
            AshA2A.Protocol.Event.MessageUpdate.new(task.id, message, context_id: task.context_id, generation: gen)
          )

        _other, conn ->
          conn
      end)
    else
      conn
    end
  end

  defp final_status(conn, task, state, text) do
    message = if text, do: AshA2A.Protocol.Message.new_agent(text)
    final_status(conn, task, AshA2A.Protocol.Task.Status.new(state, message))
  end

  defp final_status(conn, task, %AshA2A.Protocol.Task.Status{} = status) do
    event =
      AshA2A.Protocol.Event.StatusUpdate.new(task.id, status,
        context_id: task.context_id,
        final: true,
        generation: AshA2A.Protocol.Task.Generation.generation_of(task)
      )

    send_frame(conn, event)
  end

  defp start_sse(conn) do
    conn
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> send_chunked(200)
  end

  defp send_frame(conn, struct) do
    {:ok, encoded} = AshA2A.Protocol.JSON.encode_stream_response(struct)
    send_raw_frame(conn, encoded)
  end

  defp send_raw_frame(conn, encoded) do
    case AshA2A.Protocol.DowngradeWire.frame(conn, encoded) do
      :drop ->
        conn

      {:ok, encoded} ->
        data = "data: " <> Jason.encode!(encoded) <> "\n\n"

        case chunk(conn, data) do
          {:ok, conn} -> conn
          {:error, _closed} -> conn
        end
    end
  end

  # `AshA2A.Protocol.JSON.decode(nil, :message)` raises on the missing
  # required `messageId`, so the presence check happens here, at the
  # transport boundary, and answers the spec's 400 not a 500.
  defp decode_message(params) do
    case params["message"] do
      %{} = message_map ->
        case AshA2A.Protocol.JSON.decode(message_map, :message) do
          {:ok, _message} = ok -> ok
          {:error, reason} ->
            {:error, Error.invalid_params(reason |> SafeError.redact() |> inspect())}
        end

      _ ->
        {:error, Error.invalid_params("\"message\" is required")}
    end
  end

  # Metadata layers, later wins: init -> put_metadata -> body "metadata" ->
  # verified auth. The verified auth is last so no caller field can forge it
  # (same layering as `AshA2A.Transport.Plug.call_opts/3`).
  defp call_opts(params, message, conn, opts, cfg) do
    message_metadata = if message, do: message.metadata, else: %{}

    conn_metadata = AshA2A.Protocol.Plug.get_metadata(conn) || %{}

    params_metadata =
      case params["metadata"] do
        %{} = m -> Map.drop(m, ["a2a.auth", Runtime.owner_key()] ++ @tenant_keys)
        _ -> %{}
      end

    metadata = opts.metadata |> Map.merge(conn_metadata) |> Map.merge(params_metadata)
    metadata = if auth = auth(conn), do: Map.put(metadata, "a2a.auth", auth), else: metadata

    # W12: the path tenant is bound AFTER any client-supplied tenant is dropped.
    metadata =
      case tenant(conn) do
        nil -> metadata
        tenant -> metadata |> Map.drop(@tenant_keys) |> Map.put("ash_a2a.tenant", tenant)
      end

    # W17: the resolved trace context (already stamped on the message).
    metadata =
      Enum.reduce(AshA2A.Trace.W3C.from_metadata(message_metadata), metadata, fn {k, v}, acc ->
        Map.put(acc, Atom.to_string(k), v)
      end)

    configuration = configuration(params)

    []
    |> put_opt(:return_immediately, Request.return_immediately(configuration))
    |> put_opt(:accepted_output_modes, Request.accepted_output_modes(configuration))
    |> put_opt(:principal, scoped_caller(conn))
    |> put_opt(:task_id, message && message.task_id)
    |> put_opt(:context_id, message && message.context_id)
    |> put_opt(:if_generation_match, cfg.if_generation_match)
    |> put_opt(:metadata, if(metadata == %{}, do: nil, else: metadata))
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: [{key, value} | opts]

  defp call_agent(agent, message, call_opts) do
    AshA2A.Protocol.call(agent, message, call_opts)
  catch
    :exit, reason -> {:error, SafeError.internal(:internal_error, {:agent_exit, reason})}
  end

  # -- GET /tasks/{id} ---------------------------------------------------------

  defp handle_get(conn, opts, task_id) do
    conn = Plug.Conn.fetch_query_params(conn)
    history = history_param(conn.query_params)

    with false <- match?({:error, _}, history),
         {:ok, timeline} <- nonneg(conn.query_params["timelineLength"], "timelineLength"),
         {:ok, current_gen} <- nonneg(conn.query_params["currentGeneration"], "currentGeneration") do
      principal = scoped_caller(conn)

      with {:ok, task} <- owned_task(opts.agent, principal, task_id),
           {:ok, task} <- long_poll(opts.agent, principal, task, current_gen) do
        send_json(conn, 200, encode_task(task, history, timeline))
      else
        {:error, _} -> send_error(conn, 404, Error.task_not_found())
      end
    else
      true ->
        {:error, %Error{} = error} = history
        send_error(conn, status_for(error), error)

      {:error, %Error{} = error} ->
        send_error(conn, status_for(error), error)
    end
  end

  # v1.1 long-poll (spec 3.2.7): `currentGeneration` set and the task's
  # generation not yet greater -> hold the request until it advances, the task
  # is terminal, or `config :ash_a2a, :long_poll_timeout_ms` elapses (then the
  # current state is answered). Bandit does not bound a running handler, so
  # the hold is limited only by that deadline. Subscribing first and re-reading
  # closes the register/mutate race.
  defp long_poll(_agent, _principal, task, nil), do: {:ok, task}

  defp long_poll(agent, principal, task, current_gen) do
    if advanced?(task, current_gen) do
      {:ok, task}
    else
      deadline = System.monotonic_time(:millisecond) + AshA2A.Protocol.ClientArtifacts.long_poll_timeout_ms()

      case subscribe_agent(agent, task.id) do
        {:ok, _snapshot} ->
          with {:ok, fresh} <- owned_task(agent, principal, task.id) do
            wait_generation(agent, principal, fresh, current_gen, deadline)
          end

        _terminal_or_error ->
          {:ok, task}
      end
    end
  end

  defp advanced?(task, current_gen),
    do: AshA2A.Protocol.Task.Generation.generation_of(task) > current_gen or AshA2A.Protocol.Task.terminal?(task)

  defp wait_generation(agent, principal, task, current_gen, deadline) do
    if advanced?(task, current_gen) do
      {:ok, task}
    else
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)
      task_id = task.id

      receive do
        {:a2a_task_event, ^task_id, _snapshot} ->
          with {:ok, fresh} <- owned_task(agent, principal, task_id) do
            wait_generation(agent, principal, fresh, current_gen, deadline)
          end
      after
        remaining -> {:ok, task}
      end
    end
  end

  # §11.5: request parameters arrive as query parameters on the REST binding.
  defp history_param(query_params) do
    case Request.history_length(query_params) do
      nil ->
        nil

      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {n, ""} when n >= 0 -> n
          _ -> {:error, Error.invalid_params("\"historyLength\" must be a non-negative integer")}
        end

      _other ->
        {:error, Error.invalid_params("\"historyLength\" must be a non-negative integer")}
    end
  end

  # -- GET /tasks ---------------------------------------------------------------

  # §5.3 tasks/list over REST. Per §11.5 the request parameters arrive as
  # query parameters, so the string-typed query values are coerced into the
  # JSON-RPC `tasks/list` params shapes and then validated by the very same
  # `Request.validate_params/1` clause the JSON-RPC binding runs (read-only
  # reuse); a value that cannot be coerced stays a binary and fails that
  # validation, so both bindings reject the same values. The listing is
  # owner-scoped through the same `{:ash_a2a_list_tasks, principal, params}`
  # GenServer call `AshA2A.Transport.Plug.handle_list/2` makes, whose runtime
  # (`AshA2A.Transport.Runtime.list_tasks_for/3`) applies the real
  # `AshA2A.Protocol.Task.Filter` semantics (sort -> filter -> paginate) over
  # only the verified caller's tasks.
  defp handle_list(conn, opts) do
    conn = Plug.Conn.fetch_query_params(conn)
    params = list_params(conn.query_params)

    with :ok <- Request.validate_params(%Request{jsonrpc: "2.0", method: "tasks/list", params: params}),
         {:ok, %{tasks: tasks} = result} <- list_tasks(opts.agent, scoped_caller(conn), params) do
      send_json(conn, 200, %{
        "tasks" =>
          Enum.map(tasks, &encode_task(&1, nil, if(is_integer(params["timelineLength"]), do: params["timelineLength"]))),
        "totalSize" => result.total_size,
        "pageSize" => result.page_size,
        "nextPageToken" => result.next_page_token
      })
    else
      {:error, %Error{} = error} ->
        send_error(conn, status_for(error), error)

      {:error, :invalid_page_token} ->
        send_error(conn, 400, Error.invalid_params("\"pageToken\" is invalid"))

      {:error, reason} ->
        error = error_for(reason)
        send_error(conn, status_for(error), error)
    end
  end

  defp list_params(query_params) do
    query_params
    |> Map.take([
      "pageSize",
      "pageToken",
      "status",
      "contextId",
      "statusTimestampAfter",
      "historyLength",
      "timelineLength",
      "includeArtifacts"
    ])
    |> Map.new(fn
      {"pageSize", value} -> {"pageSize", integer_param(value)}
      {"timelineLength", value} -> {"timelineLength", integer_param(value)}
      {"historyLength", value} -> {"historyLength", integer_param(value)}
      {"includeArtifacts", value} -> {"includeArtifacts", value in ["true", "1"]}
      {key, value} -> {key, value}
    end)
  end

  defp integer_param(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> value
    end
  end

  defp integer_param(value), do: value

  defp list_tasks(agent, principal, params) do
    GenServer.call(agent, {:ash_a2a_list_tasks, principal, params})
  catch
    :exit, reason -> {:error, SafeError.internal(:internal_error, {:agent_exit, reason})}
  end

  # -- GET /tasks/{id}:subscribe ------------------------------------------------
  #
  # Snapshot first (`{"task": ...}` frame), then the transport's logged
  # backlog and live events (when a `:transport` is running) plus the agent's
  # own subscriber fan-out, until a final event. A TERMINAL task has nothing
  # left to follow and answers 400 UNSUPPORTED_OPERATION (§3.1.6,
  # STREAM-SUB-003). Unknown/foreign task -> 404.
  #
  # v1.1: `?lastSeenGeneration=N` resumes WITHOUT the snapshot frame (the
  # client already holds the task through generation N); events at or below N
  # are suppressed, and a task already past N with no logged backlog gets one
  # catch-up statusUpdate. Absent, the snapshot is sent first as before.
  defp handle_subscribe(conn, opts, task_id) do
    conn = Plug.Conn.fetch_query_params(conn)

    with {:ok, last_seen} <- nonneg(conn.query_params["lastSeenGeneration"], "lastSeenGeneration") do
      case owned_task(opts.agent, scoped_caller(conn), task_id) do
        {:ok, task} ->
          if AshA2A.Protocol.Task.terminal?(task) do
            send_error(conn, 400, Error.unsupported_operation("tasks:subscribe"))
          else
            stream_subscription(conn, opts, task, last_seen)
          end

        {:error, _} ->
          send_error(conn, 404, Error.task_not_found())
      end
    else
      {:error, %Error{} = error} -> send_error(conn, status_for(error), error)
    end
  end

  defp stream_subscription(conn, opts, task, last_seen) do
    transport = opts.transport
    transport? = transport != nil and AshA2A.A2ATransport.running?(transport)
    gen = AshA2A.Protocol.Task.Generation.generation_of(task)

    backlog =
      if transport?,
        do: transport |> AshA2A.A2ATransport.TaskEvents.subscribe(task.id) |> Enum.reject(fn {_, k, _, _} -> k == "task" end),
        else: []

    st = %{floor: last_seen, seen: last_seen || gen, v11?: v11?(conn)}

    conn = start_sse_once(conn)

    # Register with the agent fan-out BEFORE the snapshot goes out. Events
    # racing the snapshot queue in the mailbox and follow it in order.
    _ = subscribe_agent(opts.agent, task.id)
    conn = if last_seen == nil, do: send_frame(conn, Runtime.wire_task(task)), else: conn

    {conn, last, final?} =
      Enum.reduce_while(backlog, {conn, 0, false}, fn {seq, _kind, payload, final?}, {conn, _last, _} ->
        conn = if frame_allowed?(payload, st), do: send_raw_frame(conn, payload), else: conn
        if final?, do: {:halt, {conn, seq, true}}, else: {:cont, {conn, seq, false}}
      end)

    {conn, st} =
      if is_integer(last_seen) and gen > last_seen and backlog == [] do
        event =
          AshA2A.Protocol.Event.StatusUpdate.new(task.id, task.status,
            context_id: task.context_id,
            final: false,
            generation: gen
          )

        {send_frame(conn, event), %{st | floor: gen, seen: gen}}
      else
        {conn, st}
      end

    conn = if final?, do: conn, else: follow_subscription(conn, task.id, last, 0, st)
    if transport?, do: AshA2A.A2ATransport.TaskEvents.unsubscribe(transport, task.id)
    conn
  end

  # The SSE response is started once.
  defp start_sse_once(%Plug.Conn{state: :chunked} = conn), do: conn
  defp start_sse_once(conn), do: start_sse(conn)

  # messageUpdate frames never reach pre-1.1 consumers; with a resume floor,
  # frames at or below it are suppressed.
  defp frame_allowed?(%{"messageUpdate" => _}, %{v11?: false}), do: false

  defp frame_allowed?(payload, %{floor: floor}) when is_integer(floor) do
    case payload_generation(payload) do
      nil -> true
      gen -> gen > floor
    end
  end

  defp frame_allowed?(_payload, _st), do: true

  defp payload_generation(%{} = payload) do
    Enum.find_value(["statusUpdate", "artifactUpdate", "messageUpdate"], fn key ->
      with %{"generation" => g} <- Map.get(payload, key),
           {n, ""} <- g |> to_string() |> Integer.parse() do
        n
      else
        _ -> nil
      end
    end)
  end

  defp payload_generation(_other), do: nil

  defp subscribe_agent(agent, task_id) do
    GenServer.call(agent, {:subscribe, task_id}, 5_000)
  catch
    :exit, _ -> :error
  end

  # `st`: %{floor: resume floor | nil, seen: highest generation already sent,
  # v11?: negotiated >= 1.1}. Every statusUpdate frame carries the task's
  # generation; client messages new since `seen` go out as messageUpdate
  # frames (v1.1 consumers only).
  defp follow_subscription(conn, task_id, last, idle, st) do
    receive do
      {:a2a_task_event, ^task_id, seq, _kind, _payload, _final?} when is_integer(seq) and seq <= last ->
        follow_subscription(conn, task_id, last, idle, st)

      {:a2a_task_event, ^task_id, seq, _kind, payload, final?} when is_integer(seq) ->
        conn = if frame_allowed?(payload, st), do: send_raw_frame(conn, payload), else: conn
        if final?, do: conn, else: follow_subscription(conn, task_id, seq, 0, st)

      {:a2a_task_event, ^task_id, %AshA2A.Protocol.Task{} = task} ->
        terminal? = AshA2A.Protocol.Task.terminal?(task)
        gen = AshA2A.Protocol.Task.Generation.generation_of(task)

        if is_integer(st.floor) and gen <= st.floor and not terminal? do
          follow_subscription(conn, task_id, last, 0, st)
        else
          conn = send_new_messages(conn, task, st)

          event =
            AshA2A.Protocol.Event.StatusUpdate.new(task.id, task.status,
              context_id: task.context_id,
              final: terminal?,
              generation: gen
            )

          conn = send_frame(conn, event)
          st = %{st | seen: max(st.seen, gen), floor: if(is_integer(st.floor), do: max(st.floor, gen))}
          if terminal?, do: conn, else: follow_subscription(conn, task_id, last, 0, st)
        end
    after
      @subscribe_heartbeat_ms ->
        idle = idle + @subscribe_heartbeat_ms

        with true <- idle < @subscribe_max_idle_ms,
             {:ok, conn} <- chunk(conn, ": keepalive\n\n") do
          follow_subscription(conn, task_id, last, idle, st)
        else
          _ -> conn
        end
    end
  end

  defp send_new_messages(conn, task, %{v11?: true, seen: seen}) do
    task.timeline
    |> List.wrap()
    |> Enum.reduce(conn, fn
      %AshA2A.Protocol.TimelineEntry{entry: {:message, message}, generation: gen}, conn when gen > seen ->
        send_frame(
          conn,
          AshA2A.Protocol.Event.MessageUpdate.new(task.id, message, context_id: task.context_id, generation: gen)
        )

      _other, conn ->
        conn
    end)
  end

  defp send_new_messages(conn, _task, _st), do: conn

  # -- POST /message:live ------------------------------------------------------
  #
  # A2A v1.1 SendLiveMessage over HTTP+JSON (spec 3.1.12), bound to the
  # transport-independent `AshA2A.Transport.Live` core (the same one the gRPC
  # bidi binding uses). The invoking call's response IS the downlink SSE: the
  # handler process is the session's downlink pid, the first request body is
  # fed with `Live.uplink/2`, and every `{:a2a_live, sid, event}` is written
  # as a `Live.encode/1` frame (messageUpdate only for A2A-Version >= 1.1).
  # The session id travels in the `a2a-live-session-id` response header.
  #
  # While a downlink is open, further short-lived POSTs to the same operation
  # are UPLINKS: they carry the session id (`a2a-live-session-id` header,
  # `live_session_id` query/body key) or name a task an open session of the
  # same principal is bound to. They go through `Live.uplink_call/4` and answer
  # 200 with the ack Task JSON ONLY -- events travel on the downlink. Request
  # level problems on the downlink (unknown payload, unknown task) are
  # StreamError frames, never a transport failure.

  defp handle_live(conn, opts) do
    card = agent_card(opts.agent)

    with :ok <- require_streaming(card),
         {:ok, body, conn} <- read_json_body(conn, opts.max_body_bytes) do
      conn = Plug.Conn.fetch_query_params(conn)
      sid = live_sid(conn, body)
      request = Map.delete(body, "live_session_id")

      if live_uplink?(opts, conn, sid, request) do
        live_uplink(conn, opts, request, sid)
      else
        live_downlink(conn, opts, request)
      end
    else
      {:error, %Error{} = error} -> send_error(conn, status_for(error), error)
      {:error, kind} when kind in [:body_too_large, :parse_error] -> body_error(conn, kind)
    end
  end

  defp require_streaming(card) do
    if AshA2A.Transport.Live.capability?(card, :streaming),
      do: :ok,
      else: {:error, Error.unsupported_operation("message:live requires capabilities.streaming")}
  end

  defp live_sid(conn, body) do
    sid =
      List.first(get_req_header(conn, "a2a-live-session-id")) ||
        conn.query_params["live_session_id"] || body["live_session_id"]

    if is_binary(sid) and sid != "", do: sid
  end

  # An uplink names a session, or a task an open session of this principal is
  # bound to (same registry key `Live.uplink_call/4` routes by).
  defp live_uplink?(_opts, _conn, sid, _request) when is_binary(sid), do: true

  defp live_uplink?(opts, conn, nil, request) do
    with id when is_binary(id) <- body_task_id(request),
         registry = AshA2A.Transport.Live.registry(),
         pid when is_pid(pid) <- Process.whereis(registry),
         [_ | _] = entries <- Registry.lookup(registry, {:task, opts.agent, id}) do
      owner = caller(conn)
      Enum.any?(entries, fn {_pid, entry_owner} -> entry_owner == owner end)
    else
      _ -> false
    end
  end

  defp body_task_id(%{"sendMessage" => %{"message" => %{"taskId" => id}}}) when is_binary(id) and id != "", do: id
  defp body_task_id(_), do: nil

  # Call context for the Live core: metadata layered like `call_opts/5`
  # (verified auth last, path tenant bound after dropping client tenants).
  defp live_ctx(conn, opts) do
    conn_metadata = AshA2A.Protocol.Plug.get_metadata(conn) || %{}

    metadata =
      opts.metadata
      |> Map.merge(conn_metadata)
      |> Map.drop(["a2a.auth", Runtime.owner_key()])

    metadata = if auth = auth(conn), do: Map.put(metadata, "a2a.auth", auth), else: metadata

    metadata =
      case tenant(conn) do
        nil -> metadata
        tenant -> metadata |> Map.drop(@tenant_keys) |> Map.put("ash_a2a.tenant", tenant)
      end

    %{metadata: metadata, principal: caller(conn)}
  end

  defp live_downlink(conn, opts, request) do
    case AshA2A.Transport.Live.open(opts.agent, live_ctx(conn, opts), self()) do
      {:ok, session} ->
        sid = AshA2A.Transport.Live.session_id(session)
        conn = conn |> put_resp_header("a2a-live-session-id", sid) |> start_sse()

        try do
          live_first_request(conn, session, request)
        after
          AshA2A.Transport.Live.close(session)
        end

      {:error, :unsupported_operation} ->
        send_error(conn, 400, Error.unsupported_operation("message:live requires capabilities.streaming"))

      {:error, _unavailable} ->
        send_error(conn, 503, %Error{code: -32_000, message: "agent unavailable"})
    end
  end

  defp live_first_request(conn, session, request) do
    case AshA2A.Protocol.StreamRequest.decode(request) do
      {:error, reason} ->
        send_frame(conn, decode_stream_error(reason))

      {:ok, %{payload: payload}} ->
        case AshA2A.Transport.Live.uplink(session, request) do
          :ok ->
            live_loop(conn, v11?(conn), 0)

          {:error, :not_found} ->
            send_frame(conn, task_not_found_stream_error(Map.get(payload, :task_id)))

          {:error, _other} ->
            send_frame(conn, %AshA2A.Protocol.StreamError{code: "INTERNAL", message: "live session closed"})
        end
    end
  end

  # Writes downlink events until the session closes; keepalive comments while
  # idle, bounded by the same idle cap as `:subscribe`.
  defp live_loop(conn, v11?, idle) do
    receive do
      {:a2a_live, _sid, %AshA2A.Protocol.Event.MessageUpdate{}} when not v11? ->
        live_loop(conn, v11?, 0)

      {:a2a_live, _sid, event} ->
        conn |> send_raw_frame(AshA2A.Transport.Live.encode(event)) |> live_loop(v11?, 0)

      {:a2a_live_closed, _sid, _reason} ->
        conn
    after
      @subscribe_heartbeat_ms ->
        idle = idle + @subscribe_heartbeat_ms

        with true <- idle < @subscribe_max_idle_ms,
             {:ok, conn} <- chunk(conn, ": keepalive\n\n") do
          live_loop(conn, v11?, idle)
        else
          _ -> conn
        end
    end
  end

  # Short-lived uplink call: the answer is the ack Task only.
  defp live_uplink(conn, opts, request, sid) do
    call_opts = if sid, do: [live_session_id: sid], else: []

    case AshA2A.Transport.Live.uplink_call(opts.agent, live_ctx(conn, opts), request, call_opts) do
      {:ack, %AshA2A.Protocol.Task{id: id} = task} ->
        if live_task_mismatch?(request, id) do
          send_error(conn, 400, Error.invalid_params("message taskId does not match the live session's task"))
        else
          send_json(conn, 200, AshA2A.Protocol.JSON.encode!(task))
        end

      {:ack, %AshA2A.Protocol.Message{} = message} ->
        {:ok, encoded} = AshA2A.Protocol.JSON.encode(message)
        send_json(conn, 200, %{"message" => encoded})

      {:ack, _none} ->
        send_json(conn, 200, %{})

      {:error, :not_found} ->
        send_error(conn, 404, Error.task_not_found())

      {:error, :unknown_session} ->
        send_error(conn, 400, Error.invalid_params("unknown or expired live session"))

      {:error, :unsupported_operation} ->
        send_error(conn, 400, Error.unsupported_operation("message:live requires capabilities.streaming"))

      {:error, :unavailable} ->
        send_error(conn, 503, %Error{code: -32_000, message: "agent unavailable"})

      {:error, %AshA2A.Protocol.StreamError{} = stream_error} ->
        error = stream_error_to_error(stream_error)
        send_error(conn, status_for(error), error)

      {:error, reason} ->
        error = error_for(reason)
        send_error(conn, status_for(error), error)
    end
  end

  # The session rejected a request naming a different task than the one it is
  # bound to (a StreamError went to the downlink); the uplink answers 400.
  defp live_task_mismatch?(request, ack_task_id) do
    case AshA2A.Protocol.StreamRequest.decode(request) do
      {:ok, %{kind: :send_message, payload: %{task_id: id}}} when is_binary(id) -> id != ack_task_id
      _ -> false
    end
  end

  # StreamError code -> REST error: INVALID_ARGUMENT/UNKNOWN_PAYLOAD -> 400,
  # ABORTED -> 409, UNAVAILABLE -> 503.
  defp stream_error_to_error(%AshA2A.Protocol.StreamError{code: code, message: message}) do
    case code do
      "ABORTED" -> Error.task_generation_mismatch()
      "UNAVAILABLE" -> %Error{code: -32_000, message: message || "unavailable"}
      "UNSUPPORTED_OPERATION" -> Error.unsupported_operation(message || "unsupported operation")
      "NOT_FOUND" -> Error.task_not_found()
      "TASK_NOT_FOUND" -> Error.task_not_found()
      "INTERNAL" -> Error.internal_error(%{"code" => "internal_error"})
      _other -> Error.invalid_params(message || "invalid live request")
    end
  end

  defp decode_stream_error({:unknown_payload, keys}) do
    %AshA2A.Protocol.StreamError{
      code: "UNKNOWN_PAYLOAD",
      message: "unrecognized StreamRequest payload: " <> Enum.map_join(keys, ", ", &to_string/1)
    }
  end

  defp decode_stream_error({:invalid, detail, reference_id}) do
    %AshA2A.Protocol.StreamError{code: "INVALID_ARGUMENT", message: detail, reference_id: reference_id}
  end

  defp decode_stream_error(_other),
    do: %AshA2A.Protocol.StreamError{code: "INVALID_ARGUMENT", message: "invalid StreamRequest"}

  defp task_not_found_stream_error(task_id),
    do: %AshA2A.Protocol.StreamError{code: "TASK_NOT_FOUND", task_id: task_id, message: "Task not found"}

  # -- POST /tasks/{id}:cancel -------------------------------------------------

  defp handle_cancel(conn, opts, task_id) do
    principal = scoped_caller(conn)

    with {:ok, _task} <- owned_task(opts.agent, principal, task_id),
         :ok <- cancel_agent(opts.agent, task_id),
         {:ok, task} <- owned_task(opts.agent, principal, task_id) do
      publish_task(opts, task)
      send_json(conn, 200, encode_task(task, nil))
    else
      {:error, :not_cancelable} ->
        error = Error.task_not_cancelable()
        send_error(conn, status_for(error), error)

      {:error, :not_found} -> send_error(conn, 404, Error.task_not_found())
      {:error, %Error{} = error} -> send_error(conn, status_for(error), error)
      {:error, reason} -> send_error(conn, status_for(error_for(reason)), error_for(reason))
    end
  end

  defp cancel_agent(agent, task_id) do
    GenServer.call(agent, {:cancel, task_id})
  catch
    :exit, reason -> {:error, SafeError.internal(:internal_error, {:agent_exit, reason})}
  end

  # -- shared helpers ----------------------------------------------------------

  defp owned_task(agent, principal, task_id) do
    GenServer.call(agent, {:ash_a2a_get_task, principal, task_id})
  catch
    :exit, reason -> {:error, SafeError.internal(:internal_error, {:agent_exit, reason})}
  end

  defp encode_task(task, history_length, timeline_length \\ nil) do
    task
    |> Runtime.wire_task()
    |> AshA2A.Protocol.Task.strip_stream_metadata()
    |> AshA2A.Protocol.Task.truncate_history(history_length)
    |> AshA2A.Protocol.Task.truncate_timeline(timeline_length)
    |> AshA2A.Protocol.JSON.encode!()
  end

  defp auth(conn), do: conn.private |> Map.get(:a2a, %{}) |> Map.get(:auth)

  defp tenant(conn), do: conn.private |> Map.get(:a2a, %{}) |> Map.get(:tenant)

  # Owner key narrowed by the path tenant (W12): `{key, tenant}` when tenanted.
  defp scoped_caller(conn), do: Principal.scope(caller(conn), tenant(conn))

  defp caller(conn) do
    case auth(conn) do
      %{identity: identity} -> Principal.key(identity)
      _ -> :anonymous
    end
  end

  # -- error mapping ------------------------------------------------------------

  # §3.3.2/§5.4: validation -> 400, not found -> 404, state conflict
  # (TaskNotCancelable) -> 409, system -> 500/503.
  # Bodies stay inline (no delegator): the error-registry court extracts
  # status_for/1 clauses structurally and asserts every body is a
  # compile-time literal (traceability of the mapping).
  @spec status_for(Error.t()) :: non_neg_integer()
  defp status_for(%Error{code: -32_001}), do: 404
  defp status_for(%Error{code: -32_006}), do: 500
  defp status_for(%Error{code: code})
       when code in [
              -32_600,
              -32_601,
              -32_602,
              -32_700,
              -32_003,
              -32_004,
              -32_005,
              -32_007,
              -32_008,
              -32_009
            ],
       do: 400
  # v1.1 TaskGenerationMismatch (-32010): optimistic-concurrency conflict, ABORTED.
  defp status_for(%Error{code: -32_010}), do: 409
  # TaskNotCancelable (-32002): state conflict -> 409 (pinned TCK CORE-CANCEL-002).
  defp status_for(%Error{code: -32_002}), do: 409
  defp status_for(%Error{code: -32_000}), do: 503
  defp status_for(%Error{code: _code}), do: 500

  # Raw-code variant for paths holding a bare integer code (send_rest_error):
  # one table, via status_for/1.
  defp status_code(code), do: status_for(%Error{code: code, message: ""})

  # The REST wrapper around the shared `Error.to_map/1` envelope, fed the
  # already-serialized wire map the `PushConfigRPC` handlers return.
  defp send_rest_error(conn, error_map) do
    status = status_code(error_map["code"])
    send_json(conn, status, aip193_body(status, error_map))
  end

  # Typed refusals of the underlying runtime, mapped to the same Error
  # payloads `AshA2A.Transport.Plug.wire_error/1` produces (read-only reuse),
  # paired with the HTTP status the spec assigns each class.
  defp error_for(:not_found), do: Error.task_not_found()
  defp error_for(:not_continuable), do: Error.unsupported_operation("task is terminal")
  defp error_for(:context_mismatch), do: Error.invalid_params("contextId does not match task")
  defp error_for(:generation_mismatch), do: Error.task_generation_mismatch()

  defp error_for({:unsupported_operation, :user_artifacts}),
    do: Error.unsupported_operation("userArtifacts capability is not declared")

  defp error_for({:content_type_not_supported, _data} = refusal),
    do: AshA2A.Protocol.InputModeValidator.to_error(refusal)

  defp error_for(%{code: code}) when code in [:server_busy, :rate_limited] do
    # -32000 is the JSON-RPC server-error code (not one of the Error module's
    # A2A-specific constructors), pinned by transport court tests; error.ex is
    # another lane's file, hence the one literal here.
    %Error{code: -32_000, message: "Server busy", data: %{"reason" => Atom.to_string(code)}}
  end

  defp error_for(%{code: _} = reason) do
    data =
      reason
      |> SafeError.redact()
      |> Map.take([:code, :ref])
      |> Map.new(fn {k, v} -> {Atom.to_string(k), to_string(v)} end)

    Error.internal_error(data)
  end

  defp error_for(reason) do
    %{ref: ref} = SafeError.internal(:internal_error, reason)
    Error.internal_error(%{"code" => "internal_error", "ref" => ref})
  end

  # §3.3.2/§11.6 error body: the AIP-193 envelope `{"error": {...}}` with
  # `error.code` pinned to the HTTP status (TCK HTTP_JSON-ERR-001 pins
  # `error.code == HTTP status`), the canonical gRPC status name, the shared
  # `Error.to_map/1` message, and `Error.to_map/1`'s `google.rpc.ErrorInfo`
  # `data` list as `details` (TCK HTTP_JSON-ERR-002). `Error.to_map/1` is
  # consumed read-only: the A2A code still travels inside the ErrorInfo, the
  # JSON-RPC `"data"` key is renamed `"details"`.
  defp send_error(conn, status, %Error{} = error) do
    send_json(conn, status, aip193_body(status, Error.to_map(error)))
  end

  defp aip193_body(status, error_map) do
    error_object =
      %{
        "code" => status,
        "status" => Error.status_name_for_code(error_map["code"]) || grpc_status_name(status),
        "message" => Map.get(error_map, "message")
      }
      |> put_details(Map.get(error_map, "data"))

    %{"error" => error_object}
  end

  defp put_details(map, nil), do: map
  defp put_details(map, details), do: Map.put(map, "details", details)

  # Canonical gRPC status names for the statuses this binding answers
  # (AIP-193 §representation: `status` is the gRPC code string).
  defp grpc_status_name(400), do: "INVALID_ARGUMENT"
  defp grpc_status_name(401), do: "UNAUTHENTICATED"
  defp grpc_status_name(403), do: "PERMISSION_DENIED"
  defp grpc_status_name(404), do: "NOT_FOUND"
  defp grpc_status_name(405), do: "UNIMPLEMENTED"
  defp grpc_status_name(409), do: "ABORTED"
  defp grpc_status_name(413), do: "INVALID_ARGUMENT"
  defp grpc_status_name(415), do: "INVALID_ARGUMENT"
  defp grpc_status_name(422), do: "INVALID_ARGUMENT"
  defp grpc_status_name(429), do: "RESOURCE_EXHAUSTED"
  defp grpc_status_name(500), do: "INTERNAL"
  defp grpc_status_name(502), do: "INTERNAL"
  defp grpc_status_name(503), do: "UNAVAILABLE"
  defp grpc_status_name(_other), do: "UNKNOWN"

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type(Map.get(conn.private, :a2a_http_json_ct, @json_ct))
    |> send_resp(status, Jason.encode!(AshA2A.Protocol.DowngradeWire.body(conn, body)))
  end

  # AIP-193 JSON envelopes (not text/plain) so a client parsing every error
  # body as JSON never chokes on a routing miss.
  defp method_not_allowed(conn, allow) do
    conn
    |> put_resp_header("allow", allow)
    |> send_json(405, aip193_body(405, %{"message" => "Method Not Allowed"}))
  end

  defp not_found(conn),
    do: send_json(conn, 404, aip193_body(404, %{"message" => "Not Found"}))

  # Body read failures: an over-cap body is 413 (Payload Too Large), not 400.
  defp body_error(conn, :body_too_large),
    do: send_error(conn, 413, Error.invalid_request("Body too large"))

  defp body_error(conn, :parse_error), do: send_error(conn, 400, Error.parse_error())

  defp read_json_body(%{body_params: %Plug.Conn.Unfetched{}} = conn, max) do
    case read_body(conn, length: max) do
      {:ok, body, conn} ->
        case Jason.decode(body) do
          {:ok, decoded} when is_map(decoded) -> {:ok, decoded, conn}
          _ -> {:error, :parse_error}
        end

      {:more, _partial, _conn} ->
        {:error, :body_too_large}

      {:error, _reason} ->
        {:error, :parse_error}
    end
  end

  defp read_json_body(%{body_params: %{} = params} = conn, _max), do: {:ok, params, conn}
end
