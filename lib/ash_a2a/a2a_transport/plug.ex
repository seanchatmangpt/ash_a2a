defmodule AshA2A.A2ATransport.Plug do
  @moduledoc """
  ash_a2a-owned A2A HTTP transport: a drop-in wrapper around `A2A.Plug` that
  implements the methods the vendored plug hard-codes to refusals.

  | method | `A2A.Plug` | this plug |
  |--------|------------|-----------|
  | `message/stream` | SSE, stream consumed inline by the first connection | SSE; stream pumped by a supervised process, fan-out to every subscriber |
  | `tasks/resubscribe` | -32004 | SSE: snapshot, backlog replay (`Last-Event-ID` aware), live events until final |
  | `tasks/pushNotificationConfig/*` | -32003 | -32003 unless `push_notifications: true`; then set/get/list/delete + signed, SSRF-admitted webhook delivery |
  | `agent/getAuthenticatedExtendedCard` | -32004 | -32007 unless an `:extended_card` provider is configured; 401 for unauthenticated callers |
  | everything else | -- | delegated to `A2A.Plug` unchanged |

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

  All `A2A.Plug` options, plus:

    * `:transport` -- `AshA2A.A2ATransport` instance name (default
      `AshA2A.A2ATransport`). When that instance is **not running**,
      `message/stream`, `tasks/resubscribe` and push config fall back to
      `A2A.Plug`'s behavior (inline stream, -32004, -32003) -- nothing is
      silently half-enabled.
    * `:push_notifications` -- default `false` (fail closed). When `false`,
      push-config methods answer -32003 and a `message/send` or
      `message/stream` carrying `configuration.pushNotificationConfig` is
      refused with -32003 instead of silently ignoring the config.
    * `:extended_card` -- provider for the authenticated extended card, see
      `AshA2A.A2ATransport.ExtendedCard`. Default `nil`.
    * `:heartbeat_ms` (15_000) / `:max_idle_ms` (300_000) -- SSE keepalive
      and idle close for resubscribers.

  When push notifications or an extended-card provider are enabled, the
  served public agent card advertises `capabilities.pushNotifications` /
  `capabilities.extendedAgentCard` accordingly.
  """

  @behaviour Plug

  import Plug.Conn

  alias A2A.JSONRPC.{Error, Request, Response}
  alias AshA2A.A2ATransport
  alias AshA2A.A2ATransport.{ExtendedCard, Ownership, PushConfigRPC, SSE, TaskEvents}

  # Mirrors A2A.JSONRPC's private @method_aliases (deps/a2a/lib/a2a/jsonrpc.ex);
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

  @doc false
  def method_aliases, do: @method_aliases

  @impl Plug
  def init(opts) do
    {own, a2a} =
      Keyword.split(opts, [
        :transport,
        :push_notifications,
        :extended_card,
        :heartbeat_ms,
        :max_idle_ms
      ])

    %{
      a2a: A2A.Plug.init(a2a),
      transport: Keyword.get(own, :transport, A2ATransport.default_name()),
      push_notifications: Keyword.get(own, :push_notifications, false),
      extended_card: validate_provider!(Keyword.get(own, :extended_card)),
      sse: Keyword.take(own, [:heartbeat_ms, :max_idle_ms])
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
  def call(%{method: "GET", path_info: path} = conn, %{a2a: %{agent_card_path: path}} = opts),
    do: A2A.Plug.call(conn, advertise(opts))

  def call(%{method: "POST", path_info: path} = conn, %{a2a: %{json_rpc_path: path}} = opts) do
    case read_json(conn) do
      {:ok, decoded, conn} -> route(conn, decoded, opts)
      {:error, error, conn} -> send_json(conn, Response.error(nil, error))
    end
  end

  def call(conn, opts), do: A2A.Plug.call(conn, opts.a2a)

  # -- routing ------------------------------------------------------------------

  defp route(conn, decoded, opts) do
    decoded = sanitize(decoded)

    with {:ok, req} <- Request.parse(decoded),
         req = %{req | method: Map.get(@method_aliases, req.method, req.method)},
         :ok <- Request.validate_params(req) do
      dispatch(conn, req, decoded, opts)
    else
      # Malformed envelopes: A2A.Plug produces the canonical error.
      _ -> delegate(conn, decoded, opts)
    end
  end

  defp dispatch(conn, %Request{method: "agent/getAuthenticatedExtendedCard"} = req, _raw, opts),
    do: ExtendedCard.handle(conn, req.id, opts)

  defp dispatch(conn, %Request{method: "tasks/pushNotificationConfig/" <> _} = req, raw, opts) do
    if push_enabled?(opts) do
      send_json(conn, PushConfigRPC.handle(req.method, req.params, req.id, ctx(conn, opts)))
    else
      delegate(conn, raw, opts)
    end
  end

  defp dispatch(conn, %Request{method: "message/" <> _} = req, raw, opts) do
    case continued_task(req.params) do
      nil -> dispatch_message(conn, req, raw, opts)
      task_id -> if_owned(conn, req, task_id, opts, &dispatch_message(&1, req, raw, opts))
    end
  end

  defp dispatch(conn, %Request{method: "tasks/resubscribe"} = req, raw, opts) do
    if transport?(opts) do
      sse_opts = Keyword.put(opts.sse, :principal, Ownership.caller(conn))
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

  defp dispatch(conn, %Request{method: "tasks/get"} = req, raw, opts),
    do: if_owned(conn, req, req.params["id"], opts, &delegate(&1, raw, opts))

  defp dispatch(conn, _req, raw, opts), do: delegate(conn, raw, opts)

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
    case A2A.JSON.decode(req.params["message"], :message) do
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
        send_json(conn, Response.error(req.id, Error.invalid_params(inspect(reason))))
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

      TaskEvents.publish(opts.transport, task_id, "task", task, final?)
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
    |> A2A.Plug.call(opts.a2a)
  end

  # Owner scope for methods naming an existing task: a task the verified
  # caller does not own is answered exactly like a missing one (-32001).
  defp if_owned(conn, req, task_id, opts, fun) do
    case Ownership.fetch(opts.a2a.agent, task_id, Ownership.caller(conn)) do
      {:ok, _task} -> fun.(conn)
      {:error, :not_found} -> send_json(conn, Response.error(req.id, Error.task_not_found()))
    end
  end

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
      %{conn | resp_body: Jason.encode!(%{decoded | "result" => stripped})}
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
    caps =
      %{}
      |> then(&if(push_enabled?(opts), do: Map.put(&1, :push_notifications, true), else: &1))
      |> then(&if(opts.extended_card, do: Map.put(&1, :extended_agent_card, true), else: &1))

    if caps == %{} do
      opts.a2a
    else
      card_opts = opts.a2a.agent_card_opts
      merged = Map.merge(Keyword.get(card_opts, :capabilities, %{}), caps)
      %{opts.a2a | agent_card_opts: Keyword.put(card_opts, :capabilities, merged)}
    end
  end

  # Same 3-layer metadata merge and auth propagation as A2A.Plug.
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

  defp read_json(%{body_params: %Plug.Conn.Unfetched{}} = conn) do
    case read_body(conn) do
      {:ok, body, conn} ->
        case Jason.decode(body) do
          {:ok, decoded} -> {:ok, decoded, conn}
          {:error, _} -> {:error, Error.parse_error(), conn}
        end

      {:more, _partial, conn} ->
        {:error, Error.parse_error("Body too large"), conn}

      {:error, reason} ->
        {:error, Error.internal_error(inspect(reason)), conn}
    end
  end

  defp read_json(%{body_params: params} = conn), do: {:ok, params, conn}

  defp send_json(conn, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body))
  end
end
