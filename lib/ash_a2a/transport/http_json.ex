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
      | Subscribe to task | `POST /tasks/{id}:subscribe` |

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
      POST /tasks/{id}:subscribe          unknown/foreign task -> 404
                                          TaskNotFound; owned task -> 400
                                          UnsupportedOperation (no resubscribe
                                          stream, mirroring
                                          AshA2A.Transport.Plug.resubscribe/4)

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
  `refused_webhook_*` detail, missing config -> `-32602` with the
  "push notification config not found" detail. When push notifications are not
  enabled (`:push_notifications` false, the default, or no running `:transport`)
  every push route answers `400` with the `-32003`
  `PUSH_NOTIFICATION_NOT_SUPPORTED` `ErrorInfo` -- never a 404, so the routes'
  existence is not disclosed while the feature is off.

      POST /agent                        authenticated extended agent card: the
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

  Recognized-but-unsupported v1.0 REST routes (`POST /tasks/{id}:subscribe`
  on an owned task) answer `400` with an `UNSUPPORTED_OPERATION` `ErrorInfo`;
  on an unknown or foreign task the same route answers `404` with
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

  Responses are `application/json` (the spec registers
  `application/a2a+json` at §14.1.1; the repo's other transports already
  serve `application/json`, so this binding matches that surface and accepts
  any `Accept` header). The JSON body read is capped by `:max_body_bytes`
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
      extended_card: validate_provider!(Keyword.get(opts, :extended_card))
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
  def call(%{method: "GET", path_info: path} = conn, %{agent_card_path: path} = opts) do
    serve_agent_card(conn, opts)
  end

  def call(%{path_info: path} = conn, %{agent_card_path: path}) do
    method_not_allowed(conn, "GET")
  end

  # Every non-card route runs behind the §3.6 `A2A-Version` gate, mirroring
  # `AshA2A.Transport.Plug.handle_json_rpc/2` (lib/ash_a2a/transport/plug.ex):
  # an unsupported version answers `VersionNotSupportedError` (-32009) with
  # HTTP 400 (spec §5.4 / TCK VER-SERVER-002, HTTP_JSON-STATUS-001) and still
  # echoes the rejected version in the response header (§3.6.2); a supported
  # or absent version (absent -> "0.3" per §3.6.2) dispatches with the
  # negotiated version echoed back.
  def call(conn, opts) do
    version = AshA2A.Protocol.Version.parse_header(get_req_header(conn, "a2a-version"))

    case AshA2A.Protocol.Version.validate(version, AshA2A.Protocol.Version.supported_default()) do
      :ok ->
        conn |> put_resp_header("a2a-version", version) |> dispatch(opts)

      {:error, rejected} when is_binary(rejected) ->
        conn
        |> put_resp_header("a2a-version", rejected)
        |> send_error(400, Error.version_not_supported(rejected))
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

  defp dispatch(%{method: "GET", path_info: ["tasks", id]} = conn, opts)
       when is_binary(id) and byte_size(id) > 0 and not is_cancel_segment(id) do
    handle_get(conn, opts, id)
  end

  defp dispatch(%{method: "GET", path_info: ["tasks", segment]} = conn, _opts)
       when is_cancel_segment(segment) do
    conn |> put_resp_header("allow", "POST") |> send_resp(405, "Method Not Allowed")
  end

  defp dispatch(%{method: "POST", path_info: ["tasks", segment]} = conn, opts)
       when is_cancel_segment(segment) do
    handle_cancel(conn, opts, binary_part(segment, 0, byte_size(segment) - 7))
  end

  defp dispatch(%{method: "GET", path_info: ["tasks"]} = conn, opts) do
    handle_list(conn, opts)
  end

  # §3.1.6/TCK STREAM-SUB-004: a `:subscribe` for an unknown (or foreign) task
  # MUST answer TaskNotFoundError — 404 on the REST binding (§5.4) — never the
  # 400 UNSUPPORTED_OPERATION an owned task gets. An owned task mirrors
  # `AshA2A.Transport.Plug.resubscribe/4` (lib/ash_a2a/transport/plug.ex):
  # this binding attaches no resubscribe stream, so the owned answer is the
  # UnsupportedOperationError (-32004) envelope.
  defp dispatch(%{method: "POST", path_info: ["tasks", segment]} = conn, opts)
       when is_subscribe_segment(segment) do
    task_id = binary_part(segment, 0, byte_size(segment) - 10)

    case owned_task(opts.agent, caller(conn), task_id) do
      {:ok, _task} ->
        send_error(conn, 400, Error.unsupported_operation("tasks:subscribe"))

      {:error, _} ->
        send_error(conn, 404, Error.task_not_found())
    end
  end

  # A recognized task path hit with the wrong method answers 405 with an
  # `allow` header, not 404, so a client can discover the verb instead of
  # concluding the resource does not exist.
  defp dispatch(%{path_info: ["tasks", _]} = conn, _opts) do
    method_not_allowed(conn, "GET, POST")
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
        :next -> send_resp(conn, 404, "Not Found")
      end
    else
      send_resp(conn, 404, "Not Found")
    end
  end

  defp dispatch(conn, _opts), do: send_resp(conn, 404, "Not Found")

  # -- push-config CRUD ----------------------------------------------------------

  defp push_collection(conn, opts, task_id) do
    unless_push_enabled(conn, opts, fn ->
      case conn.method do
        "POST" ->
          with {:ok, params, conn} <- read_json_body(conn, opts.max_body_bytes) do
            # The body is the TaskPushNotificationConfig resource; the config
            # object itself is also accepted (taskId comes from the path).
            config = params["pushNotificationConfig"] || params

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
            {:error, :body_too_large} -> send_error(conn, 400, Error.invalid_request("Body too large"))
            {:error, :parse_error} -> send_error(conn, 400, Error.parse_error())
          end

        "GET" ->
          dispatch_push(conn, opts, "tasks/pushNotificationConfig/list", %{"id" => task_id})

        _other ->
          method_not_allowed(conn, "GET, POST")
      end
    end)
  end

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
        send_json(conn, 200, result)

      %{"error" => error} ->
        send_rest_error(conn, error)
    end
  end

  # The same ctx shape `AshA2A.A2ATransport.Plug.ctx/2` builds (read-only reuse).
  defp push_ctx(conn, opts) do
    %{
      agent: opts.agent,
      transport: opts.transport,
      push_opts: AshA2A.A2ATransport.TaskEvents.push_opts(opts.transport),
      principal: caller(conn)
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
              send_json(conn, 200, strip_internal_keys(card))

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
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(card_json(card, opts, base_url)))
  end

  # Same encode path as the JSON-RPC transport: the vendored encoder via the
  # transport plug's public `agent_card_json/3` (consumed read-only).
  defp card_json(card, _opts, base_url) do
    AshA2A.Transport.Plug.agent_card_json(card, %{agent_card_opts: [], push_notifications: false, extensions: []}, base_url)
  end

  # -- POST /message:send ------------------------------------------------------

  defp handle_send(conn, opts) do
    with {:ok, params, conn} <- read_json_body(conn, opts.max_body_bytes),
         {:ok, message} <- decode_message(params),
         call_opts = call_opts(params, message, conn, opts),
         {:ok, result} <- call_agent(opts.agent, message, call_opts) do
      case result do
        %AshA2A.Protocol.Task{} = task ->
          history = Request.history_length(params["configuration"] || %{})
          # v1.0 SendMessageResponse oneof wrapper (`{"task" | "message"}`):
          # the TCK validates the body against the SendMessageResponse schema
          # (additionalProperties: false, task|message keys only), so a bare
          # task at the root fails the matrix's DM-*/CORE-SEND schema class.
          send_json(conn, 200, %{"task" => encode_task(task, history)})

        %AshA2A.Protocol.Message{} = message ->
          {:ok, encoded} = AshA2A.Protocol.JSON.encode(message)
          send_json(conn, 200, %{"message" => encoded})
      end
    else
      {:error, %Error{} = error} ->
        send_error(conn, status_for(error), error)

      {:error, :body_too_large} ->
        send_error(conn, 400, Error.invalid_request("Body too large"))

      {:error, :parse_error} ->
        send_error(conn, 400, Error.parse_error())

      {:error, reason} ->
        error = error_for(reason)
        send_error(conn, status_for(error), error)
    end
  end

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
         {:ok, message} <- decode_message(params),
         call_opts = call_opts(params, message, conn, opts),
         {:ok, result} <- call_agent(opts.agent, message, call_opts) do
      conn = start_sse(conn)

      case result do
        %AshA2A.Protocol.Task{metadata: %{stream: enum}} = task ->
          conn = send_frame(conn, Runtime.wire_task(task))
          stream_parts(conn, task, enum)

        %AshA2A.Protocol.Message{} = msg ->
          {:ok, encoded} = AshA2A.Protocol.JSON.encode(msg)
          send_raw_frame(conn, %{"message" => encoded})

        %AshA2A.Protocol.Task{} = task ->
          conn = send_frame(conn, Runtime.wire_task(task))

          conn =
            Enum.reduce(List.wrap(task.artifacts), conn, fn artifact, conn ->
              send_frame(
                conn,
                AshA2A.Protocol.Event.ArtifactUpdate.new(task.id, artifact,
                  context_id: task.context_id
                )
              )
            end)

          final_status(conn, task, :completed, nil)
      end
    else
      {:error, %Error{} = error} ->
        send_error(conn, status_for(error), error)

      {:error, :body_too_large} ->
        send_error(conn, 400, Error.invalid_request("Body too large"))

      {:error, :parse_error} ->
        send_error(conn, 400, Error.parse_error())

      {:error, reason} ->
        error = error_for(reason)
        send_error(conn, status_for(error), error)
    end
  end

  # Same chunk framing as `AshA2A.Transport.Plug.stream_parts/4`: chunk i's
  # frame is emitted when chunk i+1 arrives (so `append: true` is known), the
  # drain emits the pending final chunk with `lastChunk: true`; all frames of
  # one streamed artifact share the pre-minted `:stream_artifact_id`.
  defp stream_parts(conn, task, enum) do
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

    final_status(conn, task, :completed, nil)
  rescue
    error ->
      %{ref: ref} = SafeError.internal(:internal_error, error, __STACKTRACE__)
      final_status(conn, task, :failed, "Error: internal_error ref=#{ref}")
  end

  defp append_opts(true), do: [append: true]
  defp append_opts(false), do: []

  defp send_chunk_frame(conn, task, artifact_id, part, opts) do
    artifact =
      [part]
      |> AshA2A.Protocol.Artifact.new()
      |> struct(artifact_id: artifact_id)

    event =
      AshA2A.Protocol.Event.ArtifactUpdate.new(task.id, artifact, [context_id: task.context_id] ++ opts)

    send_frame(conn, event)
  end

  defp final_status(conn, task, state, text) do
    message = if text, do: AshA2A.Protocol.Message.new_agent(text)
    status = AshA2A.Protocol.Task.Status.new(state, message)

    event =
      AshA2A.Protocol.Event.StatusUpdate.new(task.id, status,
        context_id: task.context_id,
        final: true
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
    data = "data: " <> Jason.encode!(encoded) <> "\n\n"

    case chunk(conn, data) do
      {:ok, conn} -> conn
      {:error, _closed} -> conn
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
          {:error, reason} -> {:error, Error.invalid_params(inspect(reason))}
        end

      _ ->
        {:error, Error.invalid_params("\"message\" is required")}
    end
  end

  # Metadata layers, later wins: init -> put_metadata -> body "metadata" ->
  # verified auth. The verified auth is last so no caller field can forge it
  # (same layering as `AshA2A.Transport.Plug.call_opts/3`).
  defp call_opts(params, message, conn, opts) do
    conn_metadata = AshA2A.Protocol.Plug.get_metadata(conn) || %{}

    params_metadata =
      case params["metadata"] do
        %{} = m -> Map.drop(m, ["a2a.auth", Runtime.owner_key()])
        _ -> %{}
      end

    metadata = opts.metadata |> Map.merge(conn_metadata) |> Map.merge(params_metadata)
    metadata = if auth = auth(conn), do: Map.put(metadata, "a2a.auth", auth), else: metadata

    []
    |> put_opt(:task_id, message.task_id)
    |> put_opt(:context_id, message.context_id)
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

    case history do
      {:error, %Error{} = error} ->
        send_error(conn, status_for(error), error)

      history ->
        case owned_task(opts.agent, caller(conn), task_id) do
          {:ok, task} -> send_json(conn, 200, encode_task(task, history))
          {:error, _} -> send_error(conn, 404, Error.task_not_found())
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
         {:ok, %{tasks: tasks} = result} <- list_tasks(opts.agent, caller(conn), params) do
      send_json(conn, 200, %{
        "tasks" => Enum.map(tasks, &encode_task(&1, nil)),
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
      "includeArtifacts"
    ])
    |> Map.new(fn
      {"pageSize", value} -> {"pageSize", integer_param(value)}
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

  # -- POST /tasks/{id}:cancel -------------------------------------------------

  defp handle_cancel(conn, opts, task_id) do
    principal = caller(conn)

    with {:ok, _task} <- owned_task(opts.agent, principal, task_id),
         :ok <- cancel_agent(opts.agent, task_id),
         {:ok, task} <- owned_task(opts.agent, principal, task_id) do
      send_json(conn, 200, encode_task(task, nil))
    else
      {:error, :not_cancelable} -> send_error(conn, 409, Error.task_not_cancelable())
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

  defp encode_task(task, history_length) do
    task
    |> Runtime.wire_task()
    |> AshA2A.Protocol.Task.strip_stream_metadata()
    |> AshA2A.Protocol.Task.truncate_history(history_length)
    |> AshA2A.Protocol.JSON.encode!()
  end

  defp auth(conn), do: conn.private |> Map.get(:a2a, %{}) |> Map.get(:auth)

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
  defp status_for(%Error{code: -32_002}), do: 409
  defp status_for(%Error{code: code})
       when code in [-32_600, -32_601, -32_602, -32_700, -32_003, -32_004, -32_007, -32_008],
       do: 400
  defp status_for(%Error{code: -32_000}), do: 503
  defp status_for(%Error{code: _code}), do: 500

  # Raw-code variant for paths holding a bare integer code (send_rest_error).
  # Kept separate from status_for/1 so the court's structural literal check
  # on status_for/1 stays clean.
  defp status_code(-32_001), do: 404

  defp status_code(code)
       when code in [-32_600, -32_601, -32_602, -32_700, -32_002, -32_004, -32_003, -32_007],
       do: 400

  defp status_code(-32_000), do: 503
  defp status_code(_code), do: 500

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
  defp error_for(:not_continuable), do: Error.invalid_params("task is terminal")

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
        "status" => grpc_status_name(status),
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
  defp grpc_status_name(404), do: "NOT_FOUND"
  defp grpc_status_name(409), do: "ABORTED"
  defp grpc_status_name(500), do: "INTERNAL"
  defp grpc_status_name(_other), do: "UNKNOWN"

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp method_not_allowed(conn, allow) do
    conn
    |> put_resp_header("allow", allow)
    |> send_resp(405, "Method Not Allowed")
  end

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
