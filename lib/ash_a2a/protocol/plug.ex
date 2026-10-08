if Code.ensure_loaded?(Plug) do
  defmodule AshA2A.Protocol.Plug do
    @moduledoc """
    Plug for serving A2A agents over HTTP.

    Handles agent card discovery (GET), JSON-RPC dispatch (POST), and SSE
    streaming. Works standalone with Bandit or mounted inside Phoenix via
    `forward`.

    ## Usage

        # In a Phoenix router:
        forward "/a2a", AshA2A.Protocol.Plug, agent: MyAgent, base_url: "http://localhost:4000/a2a"

        # Standalone with Bandit:
        Bandit.start_link(plug: {AshA2A.Protocol.Plug, agent: MyAgent, base_url: "http://localhost:4000"})

    ## Options

    - `:agent` — GenServer name or pid of the agent (required)
    - `:base_url` — the public URL of the agent endpoint. Required unless
      always provided at runtime via `put_base_url/2`. When `nil`, agent
      card requests raise `ArgumentError`.
    - `:agent_card_path` — path segments for the agent card endpoint
      (default: `[".well-known", "agent-card.json"]`). Set to `false` to
      disable built-in agent card serving — useful when you want to serve
      the card from a custom route using `AshA2A.Protocol.get_agent_card/2`.
    - `:json_rpc_path` — path segments for the JSON-RPC endpoint
      (default: `[]`)
    - `:agent_card_opts` — keyword options forwarded to
      `AshA2A.Protocol.JSON.encode_agent_card/2`
    - `:last_modified` — `DateTime` served as the agent card's
      `Last-Modified` header (default: `DateTime.utc_now()` at `init/1`).
      Under Phoenix's `plug` macro `init/1` runs at compile time, so the
      default is the build time — which is accurate, since the card is
      itself a compile-time literal. Called directly, it is boot time.
      The card also carries a `sha256` `ETag` and
      `Cache-Control: public, max-age=300`.
    - `:metadata` — static metadata merged into every JSON-RPC call
      (default: `%{}`). Useful for deployment-level metadata like
      `%{"env" => "prod"}`. Overridden per-request by `put_metadata/2`.
    - `:resubscribe_timeout` — how long a `tasks/resubscribe` stream waits
      without an event before closing, in ms (default: `60_000`). A task that
      never reaches a terminal state would otherwise hold its connection
      process open indefinitely.
    - `:authorize_task` — optional authorization callback for task-scoped
      operations. Called as `(operation, task, context)` before returning,
      canceling, or listing tasks, and before any push notification config
      operation. `operation` is one of `:get`, `:cancel`, `:list`,
      `:resubscribe`, `:push_set`, `:push_get`, `:push_list`, or
      `:push_delete` — the push
      operations are distinct so an authorizer can grant read access to a
      task without also granting the ability to rewrite its webhooks.
      Denied requests return `TaskNotFoundError` so task IDs are not leaked.
    - `:extensions` — list of `AshA2A.Protocol.Extension` modules (or `{module, opts}`
      tuples) declaring protocol extensions this server supports. Required
      extensions are validated against the client's `A2A-Extensions`
      request header; missing required extensions return
      `ExtensionSupportRequiredError` (-32008). The server sets the
      `A2A-Extensions` response header to the URIs that were activated.
      Declarations are merged into `capabilities.extensions` on the
      served agent card.
    - `:transport` — optional `AshA2A.A2ATransport` instance name. When set
      **and running**, `message/stream` and `tasks/resubscribe` are served
      through the transport's per-task, sequence-numbered event log
      (`AshA2A.A2ATransport.TaskEvents`): multi-subscriber fan-out,
      `Last-Event-ID` replay, and a supervised pump so a client disconnect
      never truncates the task. When unset or not running, the legacy
      connection-consumed streaming path is used. Default `nil`.
    - `:versions` — list of supported A2A protocol versions as
      `Major.Minor` strings (default: `AshA2A.Protocol.Version.supported_default/0`,
      currently `["0.3", "1.0"]`). The client's `A2A-Version` header is
      normalized to `Major.Minor` and validated against this list;
      unsupported versions return `VersionNotSupportedError` (-32009).
      Missing/empty headers are treated as `"0.3"` (spec §3.6.2). The
      negotiated version is echoed in the `A2A-Version` response header.

    ## Per-Request Overrides

    Use `put_base_url/2` and `put_metadata/2` in an upstream plug or
    Phoenix pipeline to set per-request values. These are stored in
    `conn.private[:a2a]` following the Ash/Absinthe convention.

        plug :set_tenant_a2a

        defp set_tenant_a2a(conn, _opts) do
          conn
          |> AshA2A.Protocol.Plug.put_base_url("https://\#{conn.host}/a2a")
          |> AshA2A.Protocol.Plug.put_metadata(%{"tenant_id" => conn.assigns.tenant_id})
        end

    ## Metadata Merge Order

    Metadata is merged in three layers (later wins):

    1. `:metadata` from `init/1` (static defaults)
    2. `put_metadata/2` on conn (per-request)
    3. `"metadata"` from JSON-RPC params (per-call from client)
    """

    @behaviour Plug
    @behaviour AshA2A.Protocol.JSONRPC

    import Plug.Conn

    alias AshA2A.Protocol.JSONRPC.{Error, Response}

    # -- Public helpers for per-request overrides ------------------------------

    @doc """
    Stores a per-request base URL in `conn.private[:a2a]`.

    Use this in an upstream plug or Phoenix pipeline to override the
    `base_url` configured at init time.
    """
    @spec put_base_url(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
    def put_base_url(conn, url) when is_binary(url) do
      a2a = Map.get(conn.private, :a2a, %{})
      put_private(conn, :a2a, Map.put(a2a, :base_url, url))
    end

    @doc """
    Returns the per-request base URL, or `nil` if not set.
    """
    @spec get_base_url(Plug.Conn.t()) :: String.t() | nil
    def get_base_url(conn) do
      conn.private |> Map.get(:a2a, %{}) |> Map.get(:base_url)
    end

    @doc """
    Stores per-request metadata in `conn.private[:a2a]`.

    This metadata is merged between the init-time `:metadata` and the
    per-call JSON-RPC `"metadata"` field.
    """
    @spec put_metadata(Plug.Conn.t(), map()) :: Plug.Conn.t()
    def put_metadata(conn, metadata) when is_map(metadata) do
      a2a = Map.get(conn.private, :a2a, %{})
      put_private(conn, :a2a, Map.put(a2a, :metadata, metadata))
    end

    @doc """
    Returns the per-request metadata, or `nil` if not set.
    """
    @spec get_metadata(Plug.Conn.t()) :: map() | nil
    def get_metadata(conn) do
      conn.private |> Map.get(:a2a, %{}) |> Map.get(:metadata)
    end

    # -- Plug callbacks --------------------------------------------------------

    @impl Plug
    @spec init(keyword()) :: map()
    def init(opts) do
      %{
        agent: Keyword.fetch!(opts, :agent),
        base_url: Keyword.get(opts, :base_url),
        agent_card_path: Keyword.get(opts, :agent_card_path, [".well-known", "agent-card.json"]),
        json_rpc_path: Keyword.get(opts, :json_rpc_path, []),
        jwks_path: Keyword.get(opts, :jwks_path, [".well-known", "jwks.json"]),
        jwks_keys: Keyword.get(opts, :jwks_keys),
        agent_card_opts: Keyword.get(opts, :agent_card_opts, []),
        last_modified: Keyword.get(opts, :last_modified, DateTime.utc_now()),
        metadata: Keyword.get(opts, :metadata, %{}),
        authorize_task: Keyword.get(opts, :authorize_task),
        extensions: AshA2A.Protocol.Extension.compile(Keyword.get(opts, :extensions, [])),
        versions: Keyword.get(opts, :versions, AshA2A.Protocol.Version.supported_default()),
        resubscribe_timeout: Keyword.get(opts, :resubscribe_timeout, 60_000),
        transport: Keyword.get(opts, :transport, nil)
      }
    end

    @impl Plug
    @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
    def call(%{method: "GET", path_info: path} = conn, %{agent_card_path: path} = opts) do
      resolved = resolve_opts(conn, opts)
      serve_agent_card(conn, resolved)
    end

    def call(%{method: "POST", path_info: path} = conn, %{json_rpc_path: path} = opts) do
      resolved = resolve_opts(conn, opts)
      handle_json_rpc(conn, resolved)
    end

    def call(%{method: "GET", path_info: path} = conn,
             %{jwks_path: path, jwks_keys: jwks_keys} = opts)
        when not is_nil(jwks_keys) do
      serve_jwks(conn, opts)
    end

    def call(%{path_info: path} = conn, %{agent_card_path: path}) do
      conn
      |> put_resp_header("allow", "GET")
      |> send_resp(405, "Method Not Allowed")
    end

    def call(conn, _opts) do
      send_resp(conn, 404, "Not Found")
    end

    # -- JWKS publication ------------------------------------------------------

    # Serves the public keys backing card signatures as a JWKS document
    # (RFC 7517). Verifiers resolve the `kid` from a signature's PROTECTED
    # header against this document; key rotation publishes the old and new
    # generations side by side during the rotation window. Unconfigured
    # (`:jwks_keys` not set) the path 404s — a JWKS endpoint that silently
    # serves an empty key set would be a vacuous admission surface.
    defp serve_jwks(conn, opts) do
      json = AshA2A.Protocol.CardSigning.jwks(opts.jwks_keys) |> Jason.encode!()

      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "public, max-age=300")
      |> send_resp(200, json)
    end

    # -- Option resolution -----------------------------------------------------

    defp resolve_opts(conn, opts) do
      overrides = Map.get(conn.private, :a2a, %{})

      base_url = Map.get(overrides, :base_url, opts.base_url)
      conn_metadata = Map.get(overrides, :metadata)

      metadata =
        if conn_metadata,
          do: Map.merge(opts.metadata, conn_metadata),
          else: opts.metadata

      auth = Map.get(overrides, :auth)
      metadata = if auth, do: Map.put(metadata, "a2a.auth", auth), else: metadata

      %{opts | base_url: base_url, metadata: metadata}
    end

    # -- Agent card ------------------------------------------------------------

    defp serve_agent_card(_conn, %{base_url: nil}) do
      raise ArgumentError,
            "AshA2A.Protocol.Plug requires a base_url for agent card requests. " <>
              "Set it via init option :base_url or AshA2A.Protocol.Plug.put_base_url/2."
    end

    defp serve_agent_card(conn, opts) do
      card = GenServer.call(opts.agent, :get_agent_card)
      agent_card_opts = merge_extension_declarations(card, opts.agent_card_opts, opts.extensions)

      json =
        AshA2A.Protocol.JSON.encode_agent_card(
          card,
          [url: opts.base_url] ++ agent_card_opts
        )

      # Hash the body actually sent: `base_url` can be overridden per request via
      # put_base_url/2, so the encoded card is not constant across requests.
      body = Jason.encode!(json)

      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("etag", etag(body))
      |> put_resp_header("last-modified", http_date(opts.last_modified))
      # Plug defaults every response to "max-age=0, private, must-revalidate",
      # which is wrong for a public, shareable agent card.
      |> put_resp_header("cache-control", "public, max-age=300")
      |> send_resp(200, body)
    end

    defp etag(body) do
      digest = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
      ~s("#{digest}")
    end

    # RFC 7231 IMF-fixdate. Neither Plug nor Bandit exposes a public formatter.
    # Round-tripping through Unix time normalizes any zone to UTC without
    # needing a timezone database.
    defp http_date(%DateTime{} = dt) do
      dt
      |> DateTime.to_unix()
      |> DateTime.from_unix!()
      |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")
    end

    defp merge_extension_declarations(_card, agent_card_opts, []), do: agent_card_opts

    # Seeds from the card's own capabilities when the opts carry none (a bare
    # `%{}` seed silently dropped the capability index's default capabilities —
    # streaming/push/extendedAgentCard — whenever `:extensions` was set).
    # `existing` is normalized through List.wrap/1 so a single struct (or nil)
    # can never reach MapSet.new/2, which would Enumerable-crash.
    defp merge_extension_declarations(card, agent_card_opts, compiled) do
      caps =
        case Keyword.fetch(agent_card_opts, :capabilities) do
          {:ok, caps} -> caps
          :error -> Map.get(card, :capabilities, %{})
        end

      existing = caps |> Map.get(:extensions, []) |> List.wrap()
      existing_uris = MapSet.new(existing, & &1.uri)

      new =
        compiled
        |> AshA2A.Protocol.Extension.declarations()
        |> Enum.reject(&MapSet.member?(existing_uris, &1.uri))

      caps = Map.put(caps, :extensions, existing ++ new)
      Keyword.put(agent_card_opts, :capabilities, caps)
    end

    # Reads the raw agent_card_opts rather than the extension-merged form: only
    # `:extensions` is injected there, and that is a card concern, not a gate.
    defp streaming_declared?(opts) do
      opts.agent_card_opts
      |> Keyword.get(:capabilities, %{})
      |> Map.get(:streaming, false)
    end

    # Transport-backed streaming is used only when a transport instance is
    # both configured and actually running — a stale option value (e.g. a
    # transport that was stopped) falls back to the legacy path rather than
    # erroring.
    defp transport_streaming?(opts) do
      opts.transport && AshA2A.A2ATransport.running?(opts.transport)
    end

    # After-response event-log publishing for non-streaming task replies
    # (message/send, tasks/cancel): mirrors AshA2A.A2ATransport.Plug's
    # publish_result so a LIVE subscriber of a task created/updated through
    # the bare Protocol.Plug still observes the transition (STREAM-SUB-002).
    # The inner plug under AshA2A.A2ATransport.Plug runs without a :transport
    # option, so the two never double-publish.
    defp publish_result(conn, opts) do
      with 200 <- conn.status,
           {:ok, %{"result" => %{"id" => task_id} = task}} <-
             Jason.decode(IO.iodata_to_binary(conn.resp_body || "")),
           %{"status" => %{"state" => state}} when is_binary(state) <- task do
        final? = closed_wire_state?(state)

        AshA2A.A2ATransport.TaskEvents.publish(
          opts.transport,
          task_id,
          "task",
          %{"task" => AshA2A.A2ATransport.Ownership.strip_wire(task)},
          final?
        )
      else
        _ -> :ok
      end

      conn
    end

    defp closed_wire_state?(state) when is_binary(state) do
      state
      |> String.downcase()
      |> String.replace_prefix("task_state_", "")
      |> then(& &1 in ~w(completed canceled cancelled failed rejected input-required input_required auth-required auth_required))
    end

    defp closed_wire_state?(_), do: false

    # A client may register a webhook on the initial send rather than through
    # the CRUD methods, which is how the spec's delivery flow reads and how the
    # compliance suite drives it. The task does not exist until the call
    # returns, so the config can only be attached to it afterwards.
    defp register_inline_push_config(agent, %AshA2A.Protocol.Task{} = task, params, plug_opts) do
      with true <- push_notifications_declared?(plug_opts),
           %{"taskPushNotificationConfig" => raw} when is_map(raw) <-
             Map.get(params, "configuration"),
           {:ok, config} <- AshA2A.Protocol.JSON.decode(raw, :push_notification_config),
           # The task is in hand, so this authorizes the same `:push_set`
           # operation the CRUD method does rather than skipping the hook.
           {:ok, _task} <- authorize_task(:push_set, task, params, plug_opts) do
        config = %{
          config
          | task_id: task.id,
            id: config.id || AshA2A.Protocol.ID.generate("pcfg")
        }

        {:ok, _stored} = GenServer.call(agent, {:set_push_config, config})

        # Every state change this task had happened while the webhook was
        # still unregistered — a task that finishes in one turn would
        # otherwise never see a delivery, though the spec requires at least
        # one per configured webhook.
        GenServer.cast(agent, {:deliver_push, task.id})
      end

      :ok
    end

    defp register_inline_push_config(_agent, _result, _params, _plug_opts), do: :ok

    defp push_notifications_declared?(opts) do
      opts.agent_card_opts
      |> Keyword.get(:capabilities, %{})
      |> Map.get(:push_notifications, false)
    end

    # -- JSON-RPC dispatch -----------------------------------------------------

    defp handle_json_rpc(conn, opts) do
      version = AshA2A.Protocol.Version.parse_header(get_req_header(conn, "a2a-version"))
      requested = AshA2A.Protocol.Extension.parse_header(get_req_header(conn, "a2a-extensions"))

      with :ok <- AshA2A.Protocol.Version.validate(version, opts.versions),
           :ok <- AshA2A.Protocol.Extension.validate_required(opts.extensions, requested),
           {:ok, activations, activated_uris} <-
             AshA2A.Protocol.Extension.activate(opts.extensions, requested, %{conn: conn}) do
        conn =
          conn
          |> put_resp_header("a2a-version", version)
          |> put_extensions_response_header(activated_uris)

        dispatch_json_rpc(conn, opts, activations)
      else
        {:error, rejected} when is_binary(rejected) ->
          send_json(
            conn,
            Response.error(nil, Error.version_not_supported(rejected))
          )

        {:error, missing} when is_list(missing) ->
          send_json(
            conn,
            Response.error(
              nil,
              Error.extension_support_required(
                "Client missing required extensions: " <> Enum.join(missing, ", ")
              )
            )
          )

        {:error, %Error{} = err} ->
          send_json(conn, Response.error(nil, err))
      end
    end

    defp dispatch_json_rpc(conn, opts, activations) do
      case read_json_body(conn) do
        {:ok, decoded, conn} ->
          context = %{
            agent: opts.agent,
            opts: opts,
            extensions: activations
          }

          case AshA2A.Protocol.JSONRPC.handle(decoded, __MODULE__, context) do
            {:reply, response} ->
              conn =
                if transport_streaming?(opts),
                  do: register_before_send(conn, &publish_result(&1, opts)),
                  else: conn

              send_json(conn, response)

            {:stream, "message/stream", params, id} ->
              if streaming_declared?(opts) do
                message = params["message"]

                call_opts =
                  params
                  |> build_call_opts(opts)
                  |> maybe_put_fallback(:task_id, message.task_id)
                  |> maybe_put_fallback(:context_id, message.context_id)
                  |> Keyword.put(:extensions, AshA2A.Protocol.Extension.to_context_map(activations))

                if transport_streaming?(opts) do
                  AshA2A.A2ATransport.SSE.stream_message(
                    conn,
                    opts.transport,
                    opts.agent,
                    message,
                    id,
                    call_opts,
                    []
                  )
                else
                  AshA2A.Protocol.Plug.SSE.stream_message(conn, opts.agent, message, id, call_opts)
                end
              else
                send_json(conn, Response.error(id, Error.unsupported_operation()))
              end

            {:stream, "tasks/resubscribe", params, id} ->
              # Ordered so each rejection carries the code the spec asks for:
              # an undeclared capability and a terminal task are both
              # unsupported operations, but an unknown task is not found.
              with true <- streaming_declared?(opts),
                   {:ok, task} <-
                     authorized_task(opts.agent, params["id"], :resubscribe, params, opts) do
                if transport_streaming?(opts) do
                  AshA2A.A2ATransport.SSE.resubscribe(
                    conn,
                    opts.transport,
                    opts.agent,
                    %{"id" => task.id},
                    id,
                    []
                  )
                else
                  AshA2A.Protocol.Plug.SSE.subscribe_task(
                    conn,
                    opts.agent,
                    task.id,
                    id,
                    opts.resubscribe_timeout
                  )
                end
              else
                false -> send_json(conn, Response.error(id, Error.unsupported_operation()))
                {:error, error} -> send_json(conn, Response.error(id, error))
              end
          end

        {:error, :parse_error} ->
          send_json(conn, Response.error(nil, Error.parse_error()))

        {:error, :body_too_large} ->
          send_json(conn, Response.error(nil, Error.parse_error("Body too large")))

        {:error, reason} ->
          send_json(conn, Response.error(nil, internal_error(reason)))
      end
    end

    defp put_extensions_response_header(conn, []), do: conn

    defp put_extensions_response_header(conn, uris) do
      put_resp_header(conn, "a2a-extensions", Enum.join(uris, ", "))
    end

    # Returns the decoded JSON body, handling both pre-parsed (Phoenix with
    # Plug.Parsers) and raw (standalone Bandit) request bodies.
    defp read_json_body(%{body_params: %Plug.Conn.Unfetched{}} = conn) do
      case read_body(conn) do
        {:ok, body, conn} ->
          case Jason.decode(body) do
            {:ok, decoded} -> {:ok, decoded, conn}
            {:error, %Jason.DecodeError{}} -> {:error, :parse_error}
          end

        {:more, _partial, _conn} ->
          {:error, :body_too_large}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp read_json_body(%{body_params: %{} = params} = conn) do
      {:ok, params, conn}
    end

    defp send_json(conn, response) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(response))
    end

    # -- JSONRPC behaviour callbacks -------------------------------------------

    @impl AshA2A.Protocol.JSONRPC
    def handle_send(message, params, ctx) do
      %{agent: agent, opts: plug_opts} = ctx
      activations = Map.get(ctx, :extensions, [])

      with {:ok, message, params, activations} <-
             AshA2A.Protocol.Extension.run_request(activations, message, params) do
        call_opts =
          params
          |> build_call_opts(plug_opts)
          |> maybe_put_fallback(:task_id, message.task_id)
          |> maybe_put_fallback(:context_id, message.context_id)
          |> Keyword.put(:extensions, AshA2A.Protocol.Extension.to_context_map(activations))

        case AshA2A.Protocol.call(agent, message, call_opts) do
          {:ok, result} ->
            register_inline_push_config(agent, result, params, plug_opts)
            {:ok, result, _activations} = AshA2A.Protocol.Extension.run_response(activations, result, params)
            {:ok, result}

          {:error, :not_found} ->
            {:error, Error.task_not_found()}

          {:error, :not_continuable} ->
            {:error, Error.unsupported_operation()}

          {:error, :message_on_task} ->
            {:error, Error.invalid_agent_response("Message reply to a task-scoped request")}

          {:error, reason} ->
            {:error, internal_error(reason)}
        end
      end
    end

    @impl AshA2A.Protocol.JSONRPC
    def handle_get(task_id, params, %{agent: agent, opts: plug_opts}) do
      case GenServer.call(agent, {:get_task, task_id}) do
        {:ok, task} -> authorize_task(:get, task, params, plug_opts)
        {:error, :not_found} -> {:error, Error.task_not_found()}
      end
    end

    @impl AshA2A.Protocol.JSONRPC
    def handle_cancel(task_id, params, %{agent: agent, opts: plug_opts}) do
      with {:ok, task} <- fetch_task(agent, task_id),
           {:ok, _task} <- authorize_task(:cancel, task, params, plug_opts) do
        case GenServer.call(agent, {:cancel, task_id}) do
          :ok ->
            fetch_task(agent, task_id)

          {:error, :not_found} ->
            {:error, Error.task_not_found()}

          {:error, _reason} ->
            # The cancel failure reason is internal state; -32002 carries no
            # detail (SEC-08 — same redaction discipline as internal_error/1).
            {:error, Error.task_not_cancelable()}
        end
      else
        {:error, :not_found} -> {:error, Error.task_not_found()}
        {:error, %Error{} = error} -> {:error, error}
      end
    end

    @impl AshA2A.Protocol.JSONRPC
    def handle_list(params, %{agent: agent, opts: plug_opts}) do
      case GenServer.call(agent, {:list_tasks, params}) do
        {:ok, result} ->
          {:ok, authorize_task_list(result, params, plug_opts)}

        {:error, :invalid_page_token} ->
          {:error, Error.invalid_params("\"pageToken\" is invalid")}

        {:error, reason} ->
          {:error, internal_error(reason)}
      end
    end

    @impl AshA2A.Protocol.JSONRPC
    def handle_set_push_config(config, params, %{agent: agent, opts: plug_opts}) do
      with :ok <- push_declared(plug_opts),
           {:ok, _task} <-
             authorized_task(agent, config.task_id, :push_set, params, plug_opts) do
        config = %{config | id: config.id || AshA2A.Protocol.ID.generate("pcfg")}

        case GenServer.call(agent, {:set_push_config, config}) do
          {:ok, _config} = ok -> ok
          {:error, reason} -> {:error, internal_error(reason)}
        end
      end
    end

    @impl AshA2A.Protocol.JSONRPC
    def handle_get_push_config(task_id, config_id, params, %{agent: agent, opts: plug_opts}) do
      with :ok <- push_declared(plug_opts),
           {:ok, _task} <- authorized_task(agent, task_id, :push_get, params, plug_opts) do
        case GenServer.call(agent, {:get_push_config, task_id, config_id}) do
          {:ok, _config} = ok ->
            ok

          {:error, :not_found} ->
            {:error, Error.task_not_found("Push notification config not found")}
        end
      end
    end

    @impl AshA2A.Protocol.JSONRPC
    def handle_list_push_configs(task_id, params, %{agent: agent, opts: plug_opts}) do
      with :ok <- push_declared(plug_opts),
           {:ok, _task} <- authorized_task(agent, task_id, :push_list, params, plug_opts) do
        GenServer.call(agent, {:list_push_configs, task_id})
      end
    end

    @impl AshA2A.Protocol.JSONRPC
    def handle_delete_push_config(task_id, config_id, params, %{agent: agent, opts: plug_opts}) do
      with :ok <- push_declared(plug_opts),
           {:ok, _task} <- authorized_task(agent, task_id, :push_delete, params, plug_opts) do
        GenServer.call(agent, {:delete_push_config, task_id, config_id})
      end
    end

    # -- Helpers ---------------------------------------------------------------

    defp fetch_task(agent, task_id) do
      case GenServer.call(agent, {:get_task, task_id}) do
        {:ok, task} -> {:ok, task}
        {:error, :not_found} -> {:error, :not_found}
      end
    end

    # SEC-08: internal failure reasons never reach the wire verbatim — the
    # caller gets -32603 with an opaque correlation `ref`; the full reason is
    # logged server-side under the same ref (AshA2A.Transport.SafeError, the
    # same convention AshA2A.Transport.Plug and AshA2A.ToA2AError use).
    defp internal_error(reason) do
      %{ref: ref} = AshA2A.Transport.SafeError.internal(:internal_error, reason)
      Error.internal_error(%{"code" => "internal_error", "ref" => ref})
    end

    defp push_declared(plug_opts) do
      if push_notifications_declared?(plug_opts) do
        :ok
      else
        {:error, Error.push_notification_not_supported()}
      end
    end

    # A config attached to a task that does not exist can never fire, so the
    # lookup is part of the contract rather than a convenience.
    defp authorized_task(agent, task_id, operation, params, plug_opts) do
      case fetch_task(agent, task_id) do
        {:ok, task} -> authorize_task(operation, task, params, plug_opts)
        {:error, :not_found} -> {:error, Error.task_not_found()}
      end
    end

    defp authorize_task(_operation, task, _params, %{authorize_task: nil}), do: {:ok, task}

    defp authorize_task(operation, task, params, plug_opts) do
      context = authorization_context(params, plug_opts)

      case call_authorizer(plug_opts.authorize_task, operation, task, context) do
        :ok -> {:ok, task}
        true -> {:ok, task}
        {:ok, true} -> {:ok, task}
        {:ok, _identity} -> {:ok, task}
        {:error, %Error{} = error} -> {:error, error}
        _deny -> {:error, Error.task_not_found()}
      end
    end

    defp authorize_task_list(result, _params, %{authorize_task: nil}), do: result

    defp authorize_task_list(%{tasks: tasks} = result, params, plug_opts) do
      authorized =
        Enum.filter(tasks, fn task ->
          match?({:ok, ^task}, authorize_task(:list, task, params, plug_opts))
        end)

      %{
        result
        | tasks: authorized,
          total_size: length(authorized),
          page_size: length(authorized)
      }
    end

    defp call_authorizer(fun, operation, task, context) when is_function(fun, 3) do
      fun.(operation, task, context)
    end

    defp call_authorizer(fun, operation, task, _context) when is_function(fun, 2) do
      fun.(operation, task)
    end

    defp call_authorizer({module, function}, operation, task, context) do
      apply(module, function, [operation, task, context])
    end

    defp authorization_context(params, plug_opts) do
      %{metadata: request_metadata(params, plug_opts), params: params}
    end

    defp build_call_opts(params, plug_opts) do
      # 3-layer metadata merge: init → conn.private → JSON-RPC params
      metadata = request_metadata(params, plug_opts)

      []
      |> maybe_put(:task_id, params["id"])
      |> maybe_put(:context_id, params["contextId"])
      |> maybe_put(:metadata, if(metadata == %{}, do: nil, else: metadata))
    end

    defp merge_unless_nil(base, nil), do: base
    defp merge_unless_nil(base, override), do: Map.merge(base, override)

    # Reserved metadata keys the CALLER may never set: `"a2a.auth"` is the
    # verified identity the Auth plug stored on the conn (resolve_opts/2 puts
    # it under plug_opts.metadata last), `"ash_a2a.owner"` is the transport's
    # unforgeable owner key. Both are merged AFTER this function consumes
    # params.metadata downstream, so a caller-supplied value must be dropped
    # before the merge or it clobbers the verified identity (an attacker
    # answering as a different principal, or silently downgrading auth to
    # :anonymous). Mirrors AshA2A.Transport.Plug.call_opts/2, which drops the
    # same keys for the same reason.
    @reserved_metadata_keys ["a2a.auth", "ash_a2a.owner"]

    defp request_metadata(params, plug_opts) do
      caller_metadata =
        case params["metadata"] do
          %{} = m -> Map.drop(m, @reserved_metadata_keys)
          _ -> nil
        end

      merge_unless_nil(plug_opts.metadata, caller_metadata)
    end

    defp maybe_put(opts, _key, nil), do: opts
    defp maybe_put(opts, key, val), do: [{key, val} | opts]

    defp maybe_put_fallback(opts, key, val) do
      if Keyword.has_key?(opts, key), do: opts, else: maybe_put(opts, key, val)
    end
  end
end
