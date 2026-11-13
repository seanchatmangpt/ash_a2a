# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.A2ATransport.Plug do
  @moduledoc """
  ash_a2a-owned A2A HTTP transport: a drop-in wrapper around `AshA2A.Protocol.Plug` that
  implements the methods the vendored plug hard-codes to refusals.

  | method | `AshA2A.Protocol.Plug` | this plug |
  |--------|------------|-----------|
  | `message/stream` | SSE, stream consumed inline by the first connection | SSE; stream pumped by a supervised process, fan-out to every subscriber |
  | `tasks/resubscribe` | -32004 | SSE: snapshot, backlog replay (`Last-Event-ID` aware), live events until final |
  | `tasks/pushNotificationConfig/*` | -32003 | -32003 unless `push_notifications: true`; then set/get/list/delete + signed, SSRF-admitted webhook delivery |
  | `agent/getAuthenticatedExtendedCard` | -32004 | -32007 unless an `:extended_card` provider is configured; 401 for unauthenticated callers |
  | everything else | -- | delegated to `AshA2A.Protocol.Plug` unchanged |

  PascalCase v0.3 aliases (`SubscribeToTask`, `GetExtendedAgentCard`,
  `CreateTaskPushNotificationConfig`, ...) route identically.

  ## Usage

      # supervision tree
      {AshA2A.A2ATransport, push: [signing_secret: secret]}

      # router / endpoint
      forward "/a2a", AshA2A.A2ATransport.Plug,
        agent: MyAgent,
        base_url: "https://agents.example.com/a2a",
        push_notifications: true,
        extended_card: &MyApp.Cards.extended/2

  ## Options

  All `AshA2A.Protocol.Plug` options, plus:

    * `:transport` -- `AshA2A.A2ATransport` instance name (default
      `AshA2A.A2ATransport`). When that instance is **not running**,
      `message/stream`, `tasks/resubscribe` and push config fall back to
      `AshA2A.Protocol.Plug`'s behavior (inline stream, -32004, -32003) -- nothing is
      silently half-enabled.
    * `:push_notifications` -- default `false` (fail closed). When `false`,
      push-config methods answer -32003 and a `message/send` or
      `message/stream` carrying `configuration.pushNotificationConfig` is
      refused with -32003 instead of silently ignoring the config.
    * `:extended_card` -- provider for the authenticated extended card, see
      `AshA2A.A2ATransport.ExtendedCard`. Default `nil`.
    * `:max_body_bytes` -- request body cap for the JSON-RPC POST (default
      8_000_000); an over-cap body is a typed -32600 error, never a crash.
    * `:heartbeat_ms` (15_000) / `:max_idle_ms` (300_000) -- SSE keepalive
      and idle close for resubscribers.
    * `:strict_pascal_case` -- default `false`. When `true`, only the v1.0
      PascalCase method names are accepted; the legacy slash spellings
      (`message/send`, `tasks/subscribe`, ...) answer `-32601`.

  An unknown method name (PascalCase or slash) always answers `-32601`
  (after the version/extension negotiation gate). `tasks/subscribe` is
  accepted as a slash alias of `tasks/resubscribe`. Push methods with push
  disabled answer `-32003`. The card route honors `If-None-Match` /
  `If-Modified-Since` (`304`), `:sign_with` signs the served card, and the
  advertised `capabilities.extendedAgentCard` tracks the `:extended_card`
  provider.

  When push notifications or an extended-card provider are enabled, the
  served public agent card advertises `capabilities.pushNotifications` /
  `capabilities.extendedAgentCard` accordingly.
  """

  @behaviour Plug

  import Plug.Conn

  alias AshA2A.Protocol.JSONRPC.{Error, Request, Response}
  alias AshA2A.A2ATransport
  alias AshA2A.A2ATransport.{ExtendedCard, Ownership, PushConfigRPC, SSE, TaskEvents}

  # Mirrors AshA2A.Protocol.JSONRPC's private @method_aliases (deps/a2a/lib/a2a/jsonrpc.ex);
  # test/ash_a2a/a2a_transport/spec_mapping_doc_test.exs fails on drift.
  @method_aliases %{
    "SendMessage" => "message/send",
    "SendStreamingMessage" => "message/stream",
    "GetTask" => "tasks/get",
    "CancelTask" => "tasks/cancel",
    "SubscribeToTask" => "tasks/resubscribe",
    "ListTasks" => "tasks/list",
    "GetExtendedAgentCard" => "agent/getAuthenticatedExtendedCard",
    "CreateTaskPushNotificationConfig" => "tasks/pushNotificationConfig/set",
    "GetTaskPushNotificationConfig" => "tasks/pushNotificationConfig/get",
    "ListTaskPushNotificationConfigs" => "tasks/pushNotificationConfig/list",
    "DeleteTaskPushNotificationConfig" => "tasks/pushNotificationConfig/delete"
  }

  # Routing-only aliases this plug accepts in addition to the v0.3 PascalCase
  # table above (kept separate: `method_aliases/0` mirrors JSONRPC's table 1:1
  # and a parity court pins that). `tasks/subscribe` is the slash spelling of
  # SubscribeToTask used by some v1.0 clients; it routes to `tasks/resubscribe`.
  @extra_aliases %{"tasks/subscribe" => "tasks/resubscribe"}

  # Canonical (slash) methods this plug can serve; anything else is -32601.
  @canonical_methods @method_aliases |> Map.values() |> Enum.sort()

  @doc false
  def method_aliases, do: @method_aliases

  @doc false
  def extra_method_aliases, do: @extra_aliases

  @doc false
  def canonical_methods, do: @canonical_methods

  @impl Plug
  def init(opts) do
    {own, a2a} =
      Keyword.split(opts, [
        :transport,
        :push_notifications,
        :extended_card,
        :heartbeat_ms,
        :max_idle_ms,
        :max_body_bytes,
        :strict_pascal_case
      ])

    %{
      a2a: AshA2A.Protocol.Plug.init(a2a),
      strict_pascal_case: Keyword.get(own, :strict_pascal_case, false) == true,
      transport: Keyword.get(own, :transport, A2ATransport.default_name()),
      push_notifications: Keyword.get(own, :push_notifications, false),
      extended_card: validate_provider!(Keyword.get(own, :extended_card)),
      sse: Keyword.take(own, [:heartbeat_ms, :max_idle_ms]),
      max_body_bytes: Keyword.get(own, :max_body_bytes, 8_000_000)
    }
  end

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
  def call(conn, opts) do
    conn = AshA2A.Trace.Plug.call(conn, %{agent: opts.a2a.agent, transport: opts.transport})

    if conn.halted do
      conn
    else
      do_call(conn, opts)
    end
  end

  defp do_call(%{method: "GET", path_info: path} = conn, %{a2a: %{agent_card_path: path}} = opts),
    do: AshA2A.Protocol.Plug.call(conn, advertise(opts))

  defp do_call(%{method: "POST", path_info: path} = conn, %{a2a: %{json_rpc_path: path}} = opts) do
    case read_json(conn, opts) do
      {:ok, decoded, conn} -> route(conn, decoded, opts)
      {:error, error, conn} -> send_json(conn, Response.error(nil, error))
    end
  end

  defp do_call(conn, opts), do: AshA2A.Protocol.Plug.call(conn, opts.a2a)

  # -- routing ------------------------------------------------------------------

  defp route(conn, decoded, opts) do
    decoded = sanitize(decoded)

    with {:ok, req} <- Request.parse(decoded),
         {:ok, method} <- resolve_method(req, opts),
         req = %{req | method: method},
         # Delegated methods are re-parsed by the vendored dispatcher: hand it
         # the canonical name so aliases it does not know (`tasks/subscribe`)
         # still route.
         decoded = Map.put(decoded, "method", method),
         :ok <- Request.validate_params(req) do
      if gate_locally?(req, opts) do
        gated(conn, req, opts, &dispatch(&1, req, decoded, opts))
      else
        prechecked(conn, req, opts, &dispatch(&1, req, decoded, opts))
      end
    else
      # Unknown method (PascalCase or slash), or a legacy slash name under
      # `strict_pascal_case: true`: a typed -32601, never a delegate.
      {:unknown_method, req} ->
        gated(
          conn,
          req,
          opts,
          &send_json(&1, Response.error(req.id, Error.method_not_found(req.method)))
        )

      # Malformed envelopes: AshA2A.Protocol.Plug produces the canonical error.
      _ ->
        delegate(conn, decoded, opts)
    end
  end

  # PascalCase v0.3 name -> canonical slash name. `strict_pascal_case` refuses
  # the slash spellings (and `tasks/subscribe`) outright.
  defp resolve_method(%Request{method: method} = req, opts) do
    cond do
      opts.strict_pascal_case and not Map.has_key?(@method_aliases, method) ->
        {:unknown_method, req}

      true ->
        canonical = Map.get(@method_aliases, method) || Map.get(@extra_aliases, method, method)
        if canonical in @canonical_methods, do: {:ok, canonical}, else: {:unknown_method, req}
    end
  end

  # Methods this plug answers itself (never reaching the vendored plug's own
  # `handle_json_rpc/2` gate) get the same A2A-Version (-32009) and
  # A2A-Extensions negotiation (spec §3.6.2/§4.5). Delegated methods are
  # gated by the vendored plug and are not gated twice (extension
  # `activate/3` is side-effecting).
  defp gate_locally?(%Request{method: method}, opts) do
    # Push methods are answered here in BOTH states (served when enabled,
    # -32003 when disabled), so the negotiation gate always runs first.
    method in ["agent/getAuthenticatedExtendedCard", "tasks/resubscribe", "tasks/list"] or
      String.starts_with?(method, "tasks/pushNotificationConfig/") or
      (method == "message/stream" and transport?(opts))
  end

  defp gated(conn, req, opts, fun) do
    alias AshA2A.Protocol.{Extension, Version}
    version = Version.from_conn(conn)
    requested = Extension.parse_header(get_req_header(conn, "a2a-extensions"))

    with :ok <- Version.validate(version, opts.a2a.versions),
         :ok <- Extension.validate_required(opts.a2a.extensions, requested),
         {:ok, _activations, uris} <-
           Extension.activate(opts.a2a.extensions, requested, %{conn: conn}) do
      conn = conn |> put_resp_header("a2a-version", version) |> Version.put_negotiated(version)

      conn =
        if uris == [],
          do: conn,
          else: put_resp_header(conn, "a2a-extensions", Enum.join(uris, ", "))

      fun.(conn)
    else
      {:error, _} = error -> negotiation_error(conn, req, error)
    end
  end

  # Delegated methods are gated (and their extensions activated) by the
  # vendored plug, but the owner-scope lookups this plug runs BEFORE delegating
  # (`tasks/get`, `tasks/cancel`, task-continuing `message/*`) would otherwise
  # answer -32001 for a request that should have been refused by negotiation
  # first. This pre-check validates version + required extensions only -- it
  # never activates (activation stays single, inside the delegate).
  defp prechecked(conn, req, opts, fun) do
    alias AshA2A.Protocol.{Extension, Version}
    version = Version.from_conn(conn)
    requested = Extension.parse_header(get_req_header(conn, "a2a-extensions"))

    with :ok <- Version.validate(version, opts.a2a.versions),
         :ok <- Extension.validate_required(opts.a2a.extensions, requested) do
      fun.(conn)
    else
      {:error, _} = error -> negotiation_error(conn, req, error)
    end
  end

  defp negotiation_error(conn, req, {:error, rejected}) when is_binary(rejected),
    do:
      conn
      |> put_resp_header("a2a-version", rejected)
      |> send_json(Response.error(req.id, Error.version_not_supported(rejected)))

  defp negotiation_error(conn, req, {:error, missing}) when is_list(missing) do
    send_json(
      conn,
      Response.error(
        req.id,
        Error.extension_support_required(
          "Client missing required extensions: " <> Enum.join(missing, ", ")
        )
      )
    )
  end

  defp negotiation_error(conn, req, {:error, %Error{} = err}),
    do: send_json(conn, Response.error(req.id, err))

  defp dispatch(conn, %Request{method: "agent/getAuthenticatedExtendedCard"} = req, _raw, opts),
    do: ExtendedCard.handle(conn, req.id, opts)

  defp dispatch(conn, %Request{method: "tasks/pushNotificationConfig/" <> _} = req, _raw, opts) do
    if push_enabled?(opts) do
      case push_task_id(req.params) do
        nil ->
          send_json(conn, PushConfigRPC.handle(req.method, req.params, req.id, ctx(conn, opts)))

        task_id ->
          if_owned(
            conn,
            req,
            task_id,
            opts,
            &send_json(&1, PushConfigRPC.handle(req.method, req.params, req.id, ctx(&1, opts))),
            push_operation(req.method)
          )
      end
    else
      # Push disabled (`push_notifications: false`, or the transport instance
      # is not running): fail closed with PushNotificationNotSupported (-32003)
      # regardless of what the vendored plug's card capabilities declare.
      send_json(conn, Response.error(req.id, Error.push_notification_not_supported()))
    end
  end

  defp dispatch(conn, %Request{method: method} = req, raw, opts)
       when method in ["message/send", "message/stream"] do
    case continued_task(req.params) do
      nil ->
        dispatch_message(conn, req, raw, opts)

      task_id ->
        op = if req.method == "message/stream", do: :message_stream
        if_owned(conn, req, task_id, opts, &dispatch_message(&1, req, raw, opts), op)
    end
  end

  defp dispatch(conn, %Request{method: "message/" <> _} = req, _raw, _opts),
    do: send_json(conn, Response.error(req.id, Error.method_not_found(req.method)))

  defp dispatch(conn, %Request{method: "tasks/resubscribe"} = req, raw, opts) do
    if transport?(opts) do
      sse_opts =
        opts.sse
        |> Keyword.put(:principal, Ownership.caller(conn))
        |> Keyword.put(:authorize, authorizer(conn, req, opts))

      SSE.resubscribe(conn, opts.transport, opts.a2a.agent, req.params, req.id, sse_opts)
    else
      delegate(conn, raw, opts)
    end
  end

  defp dispatch(conn, %Request{method: "tasks/cancel"} = req, raw, opts) do
    if_owned(conn, req, req.params["id"], opts, fn conn ->
      if transport?(opts) do
        conn
        |> register_before_send(&publish_result(&1, opts, fn body -> body["result"] end))
        |> delegate(raw, opts)
      else
        delegate(conn, raw, opts)
      end
    end)
  end

  defp dispatch(conn, %Request{method: "tasks/list"} = req, _raw, opts) do
    # Owner-scoped listing (SEC-01): delegating `tasks/list` to the vendored
    # plug answers with an UNscoped list — its `{:list_tasks, params}` call
    # carries no principal, so any caller (even anonymous) could enumerate
    # other principals' tasks. The full `AshA2A.Agent` surface answers the
    # owner-scoped `{:ash_a2a_list_tasks, principal, params}` message; a bare
    # `AshA2A.Protocol.Agent` (no such clause) falls back to the delegate,
    # preserving its unscoped-but-documented behavior.
    principal = Ownership.caller(conn)

    try do
      # Transport opts nest the agent under :a2a (see init/1) — reading
      # opts.agent directly is a KeyError that escapes the rescue below
      # (only FunctionClauseError is caught) and kills the connection with
      # an empty body. Tasks are encoded through the codec (wire_task/1
      # returns the struct; the wire needs the JSON map). A bare
      # `AshA2A.Protocol.Agent` (no owner-scoped clause) makes GenServer.call
      # EXIT — caught below and delegated, preserving its documented behavior.
      case GenServer.call(opts.a2a.agent, {:ash_a2a_list_tasks, principal, req.params}) do
        {:ok, %{tasks: tasks} = result} ->
          wire_tasks =
            Enum.map(tasks, fn task ->
              task
              |> AshA2A.Transport.Runtime.wire_task()
              |> AshA2A.Protocol.JSON.encode!()
            end)

          # The runtime's list result is atom/snake-keyed; the wire envelope
          # is camelCase string-keyed (mirror of jsonrpc.ex encode_list_result).
          send_json(
            conn,
            Response.success(req.id, %{
              "tasks" => wire_tasks,
              "totalSize" => Map.get(result, :total_size, 0),
              "pageSize" => Map.get(result, :page_size, 0),
              "nextPageToken" => Map.get(result, :next_page_token, "")
            })
          )

        {:error, :invalid_page_token} ->
          commit_list_refusal(
            :refused_structure,
            :invalid_page_token,
            principal,
            {:list, principal},
            -32_602
          )

          send_json(
            conn,
            Response.error(req.id, Error.invalid_params("\"pageToken\" is invalid"))
          )

        {:error, :unsupported} ->
          # Bare `AshA2A.Protocol.Agent` — the typed (non-lethal) branch of
          # the same refusal the `catch :exit` backstop answers below; the
          # agent now survives the probe and keeps serving later requests.
          commit_list_refusal(
            :unsupported_profile,
            :unsupported,
            principal,
            {:list, principal},
            -32_004
          )

          send_json(conn, Response.error(req.id, Error.unsupported_operation()))

        {:error, reason} ->
          commit_list_refusal(
            :blocked_unknown,
            :unclassified_error,
            principal,
            {:list, principal},
            -32_603
          )

          send_json(
            conn,
            Response.error(
              req.id,
              Error.internal_error(AshA2A.Transport.SafeError.redact(reason))
            )
          )
      end
    rescue
      # Client-side encode failures fall back to the vendored delegate
      # rather than killing the connection with an empty body.
      _ -> delegate_fallback(conn, req, opts)
    catch
      # A bare `AshA2A.Protocol.Agent` (no owner-scoped clause) makes the
      # GenServer.call EXIT server-side (FunctionClauseError raised in the
      # agent's handle_call reaches the client as an exit). Answer the typed
      # refusal instead of delegating into the vendored plug's own crash
      # (observed -32700 on this exact path).
      :exit, _exit ->
        commit_list_refusal(
          :unsupported_profile,
          :unsupported,
          principal,
          {:list, principal},
          -32_004
        )

        send_json(conn, Response.error(req.id, Error.unsupported_operation()))
    end
  end

  defp dispatch(conn, %Request{method: "tasks/get"} = req, raw, opts),
    do: if_owned(conn, req, req.params["id"], opts, &delegate(&1, raw, opts))

  defp dispatch(conn, _req, raw, opts), do: delegate(conn, raw, opts)

  # Additive committed refusal receipt (L175, mirroring the protocol plug's
  # L153 shape, see `AshA2A.Semantic.Refusal.commit/2`): every rejection in
  # the owner-scoped `tasks/list` handler commits a 32-byte receipt over the
  # refused list/principal identity, stage `:a2a_transport_list`. No change
  # to the wire response — the receipt rides the `Refusal` struct published
  # through telemetry, exactly like `AshA2A.Protocol.Plug`'s authorize court.
  defp commit_list_refusal(class, code, detail, subject, wire_code) do
    refusal =
      AshA2A.Semantic.Refusal.new(class, code, :a2a_transport_list, detail)
      |> AshA2A.Semantic.Refusal.commit(subject)

    :telemetry.execute([:ash_a2a, :transport, :plug, :list_refused], %{}, %{
      subject: subject,
      refusal: refusal,
      wire_code: wire_code
    })
  end

  defp delegate_fallback(conn, _req, opts), do: AshA2A.Protocol.Plug.call(conn, opts.a2a)

  defp dispatch_message(conn, req, raw, opts) do
    case inline_push(req.params) do
      nil ->
        send_message(conn, req, raw, opts, nil)

      push_config ->
        cond do
          not push_enabled?(opts) ->
            send_json(conn, Response.error(req.id, Error.push_notification_not_supported()))

          true ->
            case PushConfigRPC.preflight(push_config, push_opts(opts)) do
              :ok -> send_message(conn, req, raw, opts, push_config)
              {:error, error} -> send_json(conn, Response.error(req.id, error))
            end
        end
    end
  end

  defp send_message(conn, %Request{method: "message/stream"} = req, raw, opts, push_config) do
    if transport?(opts) do
      stream(conn, req, opts, push_config)
    else
      delegate(conn, raw, opts)
    end
  end

  defp send_message(conn, %Request{method: "message/send"}, raw, opts, push_config) do
    if transport?(opts) do
      conn
      |> register_before_send(
        &publish_result(&1, opts, fn body -> get_in(body, ["result", "task"]) end, push_config)
      )
      |> delegate(raw, opts)
    else
      delegate(conn, raw, opts)
    end
  end

  defp stream(conn, req, opts, push_config) do
    case AshA2A.Protocol.JSON.decode(req.params["message"], :message) do
      {:ok, message} ->
        call_opts =
          req.params
          |> call_opts(resolved_metadata(conn, opts))
          |> put_fallback(:task_id, message.task_id)
          |> put_fallback(:context_id, message.context_id)

        on_task =
          if push_config,
            do: fn task -> PushConfigRPC.attach_inline(task.id, push_config, ctx(conn, opts)) end,
            else: nil

        SSE.stream_message(
          conn,
          opts.transport,
          opts.a2a.agent,
          message,
          req.id,
          call_opts,
          Keyword.put(opts.sse, :on_task, on_task)
        )

      {:error, reason} ->
        send_json(
          conn,
          Response.error(
            req.id,
            Error.invalid_params(AshA2A.Transport.SafeError.redact(reason) |> inspect())
          )
        )
    end
  end

  # -- after-response publishing (message/send, tasks/cancel) --------------------

  defp publish_result(conn, opts, extract, push_config \\ nil) do
    with 200 <- conn.status,
         {:ok, body} <- Jason.decode(IO.iodata_to_binary(conn.resp_body || "")),
         %{"id" => task_id} = task <- extract.(body) do
      task = Ownership.strip_wire(task)
      if push_config, do: PushConfigRPC.attach_inline(task_id, push_config, ctx(conn, opts))

      final? = task |> get_in(["status", "state"]) |> closed_wire_state?()

      # StreamResponse wrapper: kind-"task" payloads are `{"task" => ...}` so
      # SSE frames and webhook bodies are the same v1.0 shape as sse.ex's.
      TaskEvents.publish(opts.transport, task_id, "task", %{"task" => task}, final?)
    end

    conn
  end

  # -- helpers ------------------------------------------------------------------

  # Accepts both wire spellings of TaskState ("completed" and "TASK_STATE_COMPLETED").
  @closed_states ~w(completed canceled cancelled failed rejected input-required input_required auth-required auth_required)
  defp closed_wire_state?(state) when is_binary(state) do
    normalized = state |> String.downcase() |> String.replace_prefix("task_state_", "")
    normalized in @closed_states
  end

  defp closed_wire_state?(_), do: false

  defp inline_push(%{"configuration" => %{"pushNotificationConfig" => config}})
       when not is_nil(config),
       do: config

  defp inline_push(_), do: nil

  defp delegate(conn, decoded, opts) do
    conn
    |> register_before_send(&strip_response/1)
    |> Map.put(:body_params, decoded)
    |> AshA2A.Protocol.Plug.call(opts.a2a)
  end

  # Owner scope for methods naming an existing task: a task the verified
  # caller does not own is answered exactly like a missing one (-32001).
  defp if_owned(conn, req, task_id, opts, fun, operation \\ nil) do
    case Ownership.fetch_strict(opts.a2a.agent, task_id, Ownership.caller(conn)) do
      {:ok, task} ->
        # `operation: nil` = the request is delegated to the vendored plug,
        # which authorizes (and commits its refusal receipt) itself.
        case if(operation,
               do: Ownership.authorize(authorizer(conn, req, opts), operation, task),
               else: :ok
             ) do
          :ok -> fun.(conn)
          {:error, error} -> send_json(conn, Response.error(req.id, error))
        end

      {:error, :not_found} ->
        send_json(conn, Response.error(req.id, Error.task_not_found()))

      {:error, :unavailable} ->
        send_json(conn, Response.error(req.id, Error.internal_error("agent unavailable")))
    end
  end

  # The vendored plug's `:authorize_task` seam (fun/2, fun/3 or {m, f}),
  # applied to every task-naming path this plug answers itself. A denial is
  # indistinguishable from a missing task (-32001) unless the authorizer
  # returns its own typed `%Error{}`.
  defp authorizer(conn, req, opts) do
    case opts.a2a.authorize_task do
      nil ->
        nil

      auth ->
        params = if is_map(req.params), do: req.params, else: %{}
        {auth, %{metadata: resolved_metadata(conn, opts), params: params}}
    end
  end

  # On the v1 flat `set`, `id` is the CONFIG id; `taskId` is the task.
  defp push_task_id(%{"taskId" => task_id}) when is_binary(task_id) and task_id != "",
    do: task_id

  defp push_task_id(%{} = params) do
    case params["id"] || params["taskId"] do
      id when is_binary(id) -> id
      _ -> nil
    end
  end

  defp push_task_id(_), do: nil

  defp push_operation("tasks/pushNotificationConfig/set"), do: :push_set
  defp push_operation("tasks/pushNotificationConfig/get"), do: :push_get
  defp push_operation("tasks/pushNotificationConfig/list"), do: :push_list
  defp push_operation("tasks/pushNotificationConfig/delete"), do: :push_delete

  defp continued_task(%{"id" => id}) when is_binary(id), do: id
  defp continued_task(%{"message" => %{"taskId" => id}}) when is_binary(id), do: id
  defp continued_task(_params), do: nil

  defp sanitize(%{"params" => %{} = params} = decoded),
    do: %{decoded | "params" => Ownership.sanitize_params(params)}

  defp sanitize(decoded), do: decoded

  # The vendored plug echoes the verified identity (`task.metadata["a2a.auth"]`,
  # which can carry the raw credential) in every task it returns.
  defp strip_response(%{status: 200, resp_body: body} = conn) when not is_nil(body) do
    with {:ok, %{"result" => result} = decoded} <- Jason.decode(IO.iodata_to_binary(body)),
         stripped when stripped != result <- strip_result(result) do
      body = AshA2A.Protocol.DowngradeWire.body(conn, %{decoded | "result" => stripped})
      %{conn | resp_body: Jason.encode!(body)}
    else
      _ -> conn
    end
  end

  defp strip_response(conn), do: conn

  defp strip_result(%{"task" => %{} = task} = r), do: %{r | "task" => Ownership.strip_wire(task)}

  defp strip_result(%{"tasks" => tasks} = r) when is_list(tasks),
    do: %{r | "tasks" => Enum.map(tasks, &Ownership.strip_wire/1)}

  defp strip_result(%{"id" => _, "status" => _} = task), do: Ownership.strip_wire(task)
  defp strip_result(other), do: other

  defp transport?(opts), do: A2ATransport.running?(opts.transport)
  defp push_enabled?(opts), do: opts.push_notifications and transport?(opts)

  defp push_opts(opts), do: TaskEvents.push_opts(opts.transport)

  defp ctx(conn, opts),
    do: %{
      agent: opts.a2a.agent,
      transport: opts.transport,
      push_opts: push_opts(opts),
      principal: Ownership.caller(conn)
    }

  defp advertise(opts) do
    # Capability facts derived from this plug's own configuration, layered over
    # the card's capabilities by AshA2A.Protocol.Plug (`:capability_overrides`):
    #   * pushNotifications is advertised only when push is actually served;
    #   * extendedAgentCard tracks the `:extended_card` provider BOTH ways, so a
    #     card never claims an extended card the plug would answer -32007 for.
    caps =
      %{extended_agent_card: opts.extended_card != nil}
      |> then(&if(push_enabled?(opts), do: Map.put(&1, :push_notifications, true), else: &1))

    %{opts.a2a | capability_overrides: Map.merge(opts.a2a.capability_overrides, caps)}
  end

  # Same 3-layer metadata merge and auth propagation as AshA2A.Protocol.Plug.
  defp resolved_metadata(conn, opts) do
    overrides = Map.get(conn.private, :a2a, %{})
    base = opts.a2a.metadata
    base = if m = Map.get(overrides, :metadata), do: Map.merge(base, m), else: base
    if auth = Map.get(overrides, :auth), do: Map.put(base, "a2a.auth", auth), else: base
  end

  defp call_opts(params, metadata) do
    metadata =
      if is_map(params["metadata"]), do: Map.merge(metadata, params["metadata"]), else: metadata

    []
    |> put_some(:task_id, params["id"])
    |> put_some(:context_id, params["contextId"])
    |> put_some(:metadata, if(metadata == %{}, do: nil, else: metadata))
  end

  defp put_some(opts, _key, nil), do: opts
  defp put_some(opts, key, value), do: [{key, value} | opts]

  defp put_fallback(opts, key, value),
    do: if(Keyword.has_key?(opts, key), do: opts, else: put_some(opts, key, value))

  defp read_json(%{body_params: %Plug.Conn.Unfetched{}} = conn, opts) do
    case read_body(conn, length: opts.max_body_bytes) do
      {:ok, body, conn} ->
        case Jason.decode(body) do
          {:ok, decoded} -> {:ok, decoded, conn}
          {:error, _} -> {:error, Error.parse_error(), conn}
        end

      {:more, _partial, conn} ->
        {:error, Error.invalid_request("Body too large"), conn}

      {:error, _reason} ->
        {:error, Error.internal_error(), conn}
    end
  end

  defp read_json(%{body_params: params} = conn, _opts), do: {:ok, params, conn}

  defp send_json(conn, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(AshA2A.Protocol.DowngradeWire.body(conn, body)))
  end
end
