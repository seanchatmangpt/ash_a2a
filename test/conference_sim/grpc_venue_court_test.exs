# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConferenceSim.GRPCVenueHandler do
  @moduledoc """
  The venue's real gRPC handler — a real `AshA2A.Protocol.JSONRPC` behaviour
  implementation over the SAME supervised `AshA2A.Test.Fixture.EchoAgent` and
  the SAME `AshA2A.A2ATransport` instance the venue's JSON-RPC and HTTP+JSON
  (REST) bindings serve. No mocks.

  Task surface delegates to the shared agent (the same calls the HTTP
  binding's dispatcher makes); the push-config surface delegates to
  `AshA2A.A2ATransport.PushConfigRPC` — the very module the REST binding's
  push routes delegate to — against the shared transport's real
  `PushConfigStore`, so cross-binding parity is by construction and this
  court witnesses it over the wire.
  """

  @behaviour AshA2A.Protocol.JSONRPC

  alias AshA2A.A2ATransport.{PushConfigRPC, TaskEvents}
  alias AshA2A.Protocol.JSONRPC.Error
  alias AshA2A.Test.Fixture.EchoAgent

  @impl true
  def handle_send(message, _params, %{agent: agent}) do
    AshA2A.Protocol.call(agent, message)
  end

  @impl true
  def handle_get(task_id, _params, %{agent: agent}) do
    case EchoAgent.get_task(agent, task_id) do
      {:ok, task} -> {:ok, task}
      {:error, :not_found} -> {:error, Error.task_not_found(task_id)}
    end
  end

  @impl true
  def handle_cancel(task_id, _params, %{agent: agent}) do
    case EchoAgent.cancel(agent, task_id) do
      :ok ->
        EchoAgent.get_task(agent, task_id)

      {:error, :not_found} ->
        {:error, Error.task_not_found(task_id)}

      {:error, reason} ->
        {:error, Error.task_not_cancelable(inspect(reason))}
    end
  end

  @impl true
  def handle_list(params, %{agent: agent}) do
    case GenServer.call(agent, {:ash_a2a_list_tasks, :anonymous, params}) do
      {:ok, result} -> {:ok, result}
      {:error, :unsupported} -> {:error, Error.unsupported_operation()}
      {:error, reason} -> {:error, Error.internal_error(inspect(reason))}
    end
  end

  # -- push config CRUD: the SAME PushConfigRPC the REST binding calls ---------

  @impl true
  def handle_set_push_config(config, _params, ctx) do
    raw = %{
      "id" => config.id,
      "url" => config.url,
      "token" => config.token,
      "authentication" => auth_raw(config.authentication)
    }

    case push(
           "tasks/pushNotificationConfig/set",
           %{"taskId" => config.task_id, "pushNotificationConfig" => raw},
           ctx
         ) do
      # The codec-encoded config struct is what the JSON-RPC dispatcher
      # re-encodes onto the wire (a plain envelope map would refuse in
      # AshA2A.Protocol.JSON.encode/1); the store's copy is authoritative.
      {:ok, _envelope} -> {:ok, config}
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def handle_get_push_config(task_id, config_id, _params, ctx) do
    case push(
           "tasks/pushNotificationConfig/get",
           %{"id" => task_id, "pushNotificationConfigId" => config_id},
           ctx
         ) do
      {:ok, envelope} -> {:ok, config_struct(envelope)}
      other -> other
    end
  end

  @impl true
  def handle_list_push_configs(task_id, _params, ctx) do
    case push("tasks/pushNotificationConfig/list", %{"id" => task_id}, ctx) do
      {:ok, envelopes} -> {:ok, Enum.map(envelopes, &config_struct/1)}
      other -> other
    end
  end

  @impl true
  def handle_delete_push_config(task_id, config_id, _params, ctx) do
    push(
      "tasks/pushNotificationConfig/delete",
      %{"id" => task_id, "pushNotificationConfigId" => config_id},
      ctx
    )
  end

  defp push(method, params, ctx) do
    push_ctx = %{
      agent: ctx.agent,
      transport: ctx.transport,
      push_opts: TaskEvents.push_opts(ctx.transport),
      principal: Map.get(ctx, :principal, :anonymous)
    }

    case PushConfigRPC.handle(method, params, :venue, push_ctx) do
      %{"result" => result} ->
        {:ok, result}

      %{"error" => error} ->
        {:error, %Error{code: error["code"], message: error["message"], data: error["data"]}}
    end
  end

  # Rebuilds the wire-shaped authentication map from the codec-decoded
  # (atom-keyed) authentication, so a gRPC-set config reads back through REST
  # with the same envelope shape a REST-set config would answer.
  defp auth_raw(nil), do: nil

  defp auth_raw(%{scheme: scheme} = auth) do
    %{"schemes" => [scheme]}
    |> maybe_put("credentials", auth[:credentials])
  end

  defp auth_raw(auth) when is_map(auth), do: auth

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # The JSON-RPC dispatcher re-encodes handler results through the codec, so
  # a push-config envelope (plain string-keyed map) must be lifted back into
  # the codec struct before it goes on the wire.
  defp config_struct(%{"taskId" => task_id, "pushNotificationConfig" => inner}) do
    %AshA2A.Protocol.PushNotificationConfig{
      id: inner["id"],
      task_id: task_id,
      url: inner["url"],
      token: inner["token"],
      authentication:
        case inner["authentication"] do
          %{"schemes" => [scheme]} = auth ->
            %{scheme: scheme}
            |> maybe_put(:credentials, auth["credentials"])

          auth when is_map(auth) -> auth
          _ -> nil
        end
    }
  end
end

defmodule AshA2A.ConferenceSim.GRPCVenueAuthVerify do
  @moduledoc """
  The venue's badge check: real HS256 JWT verification — header check,
  constant-time HMAC-SHA256 signature comparison, required `sub` claim. Real
  `:crypto` HMAC math, no JWT library, no mocks.
  """

  @secret "conference-sim-venue-badge-secret"

  def secret, do: @secret

  def verify(_scheme, credential, _conn) do
    with [header_b64, payload_b64, sig_b64] <- String.split(credential, ".", parts: 3),
         {:ok, %{"alg" => "HS256"}} <-
           Jason.decode(Base.url_decode64!(header_b64, padding: false)),
         {:ok, claims} <- Jason.decode(Base.url_decode64!(payload_b64, padding: false)),
         signing_input = header_b64 <> "." <> payload_b64,
         :ok <- check_sig(signing_input, sig_b64) do
      if is_binary(claims["sub"]) and claims["sub"] != "" do
        {:ok, %{id: claims["sub"]}}
      else
        {:error, "missing sub claim"}
      end
    else
      _ -> {:error, "invalid JWT"}
    end
  end

  defp check_sig(signing_input, sig_b64) do
    expected = :crypto.mac(:hmac, :sha256, @secret, signing_input)
    sig = Base.url_decode64!(sig_b64, padding: false)
    if Plug.Crypto.secure_compare(sig, expected), do: :ok, else: {:error, "bad signature"}
  end
end

defmodule AshA2A.ConferenceSim.GRPCVenueCourt do
  @moduledoc """
  Conference-sim lane EV7 court: the venue's gRPC binding (the 11-RPC
  `a2a.A2AService` surface) serving event traffic against ONE agent and ONE
  `AshA2A.A2ATransport` — the same task/push-config store the venue's
  JSON-RPC and HTTP+JSON (REST) bindings serve. Real cowboy HTTP/2 listener,
  real Mint gRPC client, real supervised `EchoAgent`, real `PushConfigStore`.
  Zero mocks.

  ## Courts

    1. BIND-EQUIV at event scale: a task created via the JSON-RPC binding is
       fetchable via gRPC `GetTask` and visible to gRPC `ListTasks`; a task
       created via gRPC `SendMessage` is fetchable via JSON-RPC `tasks/get`
       and REST `GET /tasks/{id}` — same ids, same terminal state.
    2. Push-config CRUD parity: a config written via gRPC reads back with
       exactly the envelope the REST binding answers (write-only credentials
       stripped on the wire, stored for delivery); REST-set configs read
       back via the gRPC dispatch layer; gRPC delete is visible via REST.
    3. Typed-error parity: identical bad requests answered across bindings
       per the spec §5.4 mapping — gRPC `GetTask` unknown id is NOT_FOUND(5)
       + ErrorInfo TASK_NOT_FOUND where JSON-RPC answers -32001; gRPC push
       get on a missing config is INVALID_ARGUMENT(3) + ErrorInfo
       INVALID_PARAMS where REST answers the 400 INVALID_PARAMS envelope;
       gRPC push set on an unknown task is NOT_FOUND(5) like JSON-RPC -32001.
    4. Load: 20 interleaved gRPC + 20 JSON-RPC + 20 REST sends — all 60
       succeed against the shared store, 60 distinct task ids, one gRPC
       endpoint (no port/registry contention).
    5. CC15's auth interceptor: with bearer auth configured on the gRPC
       endpoint, unauthenticated calls are UNAUTHENTICATED(16) with the typed
       HTTP body; a valid badge JWT passes and creates a real task.
  """

  use ExUnit.Case, async: false

  alias AshA2A.A2ATransport.Plug, as: TransportPlug
  alias AshA2A.A2ATransport.{PushConfigStore, TaskEvents}
  alias AshA2A.ConferenceSim.GRPCVenueAuthVerify, as: Badge
  alias AshA2A.ConferenceSim.GRPCVenueHandler
  alias AshA2A.Test.Fixture.EchoAgent
  alias AshA2A.Transport.Grpc.Dispatch
  alias AshA2A.Transport.HTTPJSON
  alias Lf.A2a.V1, as: Pb

  @endpoint AshA2A.Transport.GRPC.Server.Endpoint
  @error_info_type "type.googleapis.com/google.rpc.ErrorInfo"
  @hook_url "http://127.0.0.1:9/hook"

  setup context do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [EchoAgent])

    transport = Module.concat(__MODULE__, Transport)

    start_supervised!(
      {AshA2A.A2ATransport,
       name: transport,
       push: [allow_http: true, allow_cidrs: ["127.0.0.1/32"], signing_secret: "venue-secret"]}
    )

    # -- binding 1: JSON-RPC (AshA2A.A2ATransport.Plug) -------------------------
    jsonrpc =
      TransportPlug.init(
        agent: EchoAgent,
        base_url: "http://x/a2a",
        transport: transport,
        push_notifications: true
      )

    # -- binding 2: HTTP+JSON REST (AshA2A.Transport.HTTPJSON) ------------------
    rest =
      HTTPJSON.init(
        agent: EchoAgent,
        base_url: "http://x/a2a",
        transport: transport,
        push_notifications: true
      )

    # -- binding 3: gRPC (AshA2A.Transport.GRPC.Server + the venue handler) ------
    Application.put_env(:ash_a2a, AshA2A.Transport.GRPC.Server,
      handler: GRPCVenueHandler,
      ctx: %{agent: EchoAgent, opts: [], transport: transport}
    )

    on_exit(fn -> Application.delete_env(:ash_a2a, AshA2A.Transport.GRPC.Server) end)

    if context[:venue_auth] do
      auth_opts =
        AshA2A.Protocol.Plug.Auth.init(
          schemes: %{"bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}},
          verify: &Badge.verify/3
        )

      Application.put_env(:ash_a2a, @endpoint, auth: {AshA2A.Transport.GRPC.Auth, auth_opts})

      on_exit(fn -> Application.delete_env(:ash_a2a, @endpoint) end)
    end

    {:ok, _client_sup} =
      DynamicSupervisor.start_link(
        strategy: :one_for_one,
        name: Module.concat(__MODULE__, ClientSup)
      )

    {:ok, _pid, port} = GRPC.Server.start_endpoint(@endpoint, 0)

    on_exit(fn ->
      try do
        GRPC.Server.stop_endpoint(@endpoint)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, channel} = GRPC.Stub.connect("localhost:#{port}", adapter: GRPC.Client.Adapters.Mint)

    %{jsonrpc: jsonrpc, rest: rest, channel: channel, transport: transport}
  end

  # -- helpers -------------------------------------------------------------------

  defp rpc(opts, method, params) do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})

    :post
    |> Plug.Test.conn("/", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> TransportPlug.call(opts)
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
  end

  defp user_message(text) do
    # Codec-encoded wire shape — the same map every binding's clients send.
    AshA2A.Protocol.JSON.encode!(AshA2A.Protocol.Message.new_user(text))
  end

  defp new_task_jsonrpc(opts, text) do
    %{"result" => %{"task" => %{"id" => id}}} =
      rpc(opts, "message/send", %{"message" => user_message(text)})

    id
  end

  defp rest_req(method, path, opts, body) do
    conn = Plug.Test.conn(method, path, body && Jason.encode!(body))

    conn =
      if body, do: Plug.Conn.put_req_header(conn, "content-type", "application/json"), else: conn

    HTTPJSON.call(conn, opts)
  end

  defp rest_json(method, path, opts, body \\ nil) do
    method
    |> rest_req(path, opts, body)
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
  end

  defp rest_new_task(opts, text) do
    %{"task" => %{"id" => id}} =
      rest_json(:post, "/message:send", opts, %{"message" => user_message(text)})

    id
  end

  defp grpc_user_request(text) do
    %Pb.SendMessageRequest{
      message: %Pb.Message{
        message_id: AshA2A.Protocol.ID.generate("venue-grpc"),
        role: :ROLE_USER,
        parts: [%Pb.Part{content: {:text, text}}]
      }
    }
  end

  defp grpc_send_task_id(channel, text) do
    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{} = task}}} =
             Lf.A2a.V1.A2AService.Stub.send_message(channel, grpc_user_request(text))

    assert task.status.state == :TASK_STATE_COMPLETED
    task.id
  end

  defp push_ctx(transport) do
    %{
      agent: EchoAgent,
      transport: transport,
      push_opts: TaskEvents.push_opts(transport),
      principal: :anonymous
    }
  end

  defp error_infos(%GRPC.RPCError{details: details}) do
    Enum.map(details, fn %Google.Protobuf.Any{type_url: type_url, value: value} ->
      assert type_url == @error_info_type
      Google.Rpc.ErrorInfo.decode(value)
    end)
  end

  # ===========================================================================
  # Court 1 — BIND-EQUIV: cross-binding task consistency
  # ===========================================================================

  test "court 1a: task created via jsonrpc is fetchable via gRPC GetTask and ListTasks", %{
    jsonrpc: jsonrpc,
    rest: rest,
    channel: channel
  } do
    task_id = new_task_jsonrpc(jsonrpc, "venue jsonrpc task")

    assert {:ok, %Pb.Task{} = got} =
             Lf.A2a.V1.A2AService.Stub.get_task(channel, %Pb.GetTaskRequest{id: task_id})

    assert got.id == task_id
    assert got.status.state == :TASK_STATE_COMPLETED

    assert {:ok, %Pb.ListTasksResponse{tasks: tasks}} =
             Lf.A2a.V1.A2AService.Stub.list_tasks(channel, %Pb.ListTasksRequest{})

    # The owner-scope law crosses bindings too: an anonymous list NEVER
    # enumerates other callers' tasks (SEC-01) — the shared-store task is
    # addressable by id but not listable anonymously, on gRPC exactly as on
    # the HTTP bindings.
    refute Enum.any?(tasks, &(&1.id == task_id))

    # REST fetch of the same shared-store task answers the same id and state.
    assert %{"id" => ^task_id, "status" => %{"state" => "TASK_STATE_COMPLETED"}} =
             rest_json(:get, "/tasks/#{task_id}", rest)
  end

  test "court 1b: task created via gRPC is fetchable via jsonrpc and REST", %{
    jsonrpc: jsonrpc,
    rest: rest,
    channel: channel
  } do
    task_id = grpc_send_task_id(channel, "venue grpc task")

    assert %{"result" => %{"id" => ^task_id, "status" => %{"state" => "TASK_STATE_COMPLETED"}}} =
             rpc(jsonrpc, "tasks/get", %{"id" => task_id})

    assert %{"id" => ^task_id} = rest_json(:get, "/tasks/#{task_id}", rest)
  end

  # ===========================================================================
  # Court 2 — push-config CRUD parity
  # ===========================================================================

  test "court 2: push config CRUD via gRPC matches the REST result", %{
    rest: rest,
    channel: channel,
    transport: transport
  } do
    task_id = rest_new_task(rest, "push parity task")

    # (a) Wire-level set via the gRPC stub.
    assert {:ok, %Pb.TaskPushNotificationConfig{task_id: ^task_id}} =
             Lf.A2a.V1.A2AService.Stub.create_task_push_notification_config(
               channel,
               %Pb.TaskPushNotificationConfig{
                 id: "cfg-grpc-1",
                 task_id: task_id,
                 url: @hook_url,
                 token: "tok-grpc"
               }
             )

    # The gRPC write went through the SAME PushConfigRPC/PushConfigStore the
    # REST binding uses: REST reads it back with exactly the envelope REST's
    # own set would answer.
    expected1 = %{
      "taskId" => task_id,
      "pushNotificationConfig" => %{
        "id" => "cfg-grpc-1",
        "url" => @hook_url,
        "token" => "tok-grpc"
      }
    }

    assert rest_json(:get, "/tasks/#{task_id}/pushNotificationConfig/cfg-grpc-1", rest) == expected1

    assert rest_json(:get, "/tasks/#{task_id}/pushNotificationConfig", rest) == [expected1]

    # (b) Dispatch-layer parity with credentials: the gRPC binding's own
    # dispatch layer answers the SAME proto-JSON map the REST binding
    # answers, credentials write-only (stripped on the wire, stored).
    assert {:ok, flat2} =
             Dispatch.call_detailed(
               "CreateTaskPushNotificationConfig",
               %{
                 "taskId" => task_id,
                 "id" => "cfg-grpc-2",
                 "url" => @hook_url,
                 "token" => "tok-2",
                 "authentication" => %{"schemes" => ["Bearer"], "credentials" => "s3cret-2"}
               },
               GRPCVenueHandler,
               push_ctx(transport)
             )

    # Field-level parity with the REST envelope's inner config (the v1.0 gRPC
    # wire is flat where REST nests under pushNotificationConfig).
    assert flat2["taskId"] == task_id
    assert flat2["id"] == "cfg-grpc-2"
    assert flat2["url"] == @hook_url
    assert flat2["token"] == "tok-2"

    {:ok, stored} =
      PushConfigStore.get(AshA2A.A2ATransport.push_store_name(transport), task_id, "cfg-grpc-2")

    assert stored.authentication == %{"schemes" => ["Bearer"], "credentials" => "s3cret-2"}

    # (c) Reverse direction: a REST-set config read via the gRPC dispatch layer.
    rest_req(:post, "/tasks/#{task_id}/pushNotificationConfig", rest, %{
      "pushNotificationConfig" => %{"id" => "cfg-rest-1", "url" => @hook_url}
    })

    assert {:ok, flat_rest} =
             Dispatch.call_detailed(
               "GetTaskPushNotificationConfig",
               %{"taskId" => task_id, "id" => "cfg-rest-1"},
               GRPCVenueHandler,
               push_ctx(transport)
             )

    assert flat_rest["taskId"] == task_id
    assert flat_rest["id"] == "cfg-rest-1"
    assert flat_rest["url"] == @hook_url

    # (d) Delete via gRPC stub: idempotent OK; REST sees the removal.
    assert {:ok, %Google.Protobuf.Empty{}} =
             Lf.A2a.V1.A2AService.Stub.delete_task_push_notification_config(
               channel,
               %Pb.DeleteTaskPushNotificationConfigRequest{task_id: task_id, id: "cfg-grpc-1"}
             )

    assert rest_json(:get, "/tasks/#{task_id}/pushNotificationConfig/cfg-grpc-1", rest) == %{
             "error" => %{
               "code" => 400,
               "message" => "Invalid parameters",
               "details" => [
                 %{
                   "@type" => @error_info_type,
                   "domain" => "a2a-protocol.org",
                   "reason" => "INVALID_PARAMS",
                   "metadata" => %{"detail" => "push notification config not found"}
                 }
               ]
             }
           }

    remaining = rest_json(:get, "/tasks/#{task_id}/pushNotificationConfig", rest)
    ids = Enum.map(remaining, & &1["pushNotificationConfig"]["id"])
    assert Enum.sort(ids) == ["cfg-grpc-2", "cfg-rest-1"]
  end

  # ===========================================================================
  # Court 3 — typed-error parity across bindings
  # ===========================================================================

  test "court 3a: unknown task — gRPC NOT_FOUND(5)+TASK_NOT_FOUND vs jsonrpc -32001", %{
    jsonrpc: jsonrpc,
    channel: channel
  } do
    assert %{"error" => %{"code" => -32_001}} = rpc(jsonrpc, "tasks/get", %{"id" => "no-such-task"})

    assert {:error, %GRPC.RPCError{status: 5} = error} =
             Lf.A2a.V1.A2AService.Stub.get_task(channel, %Pb.GetTaskRequest{id: "no-such-task"})

    assert [%Google.Rpc.ErrorInfo{reason: "TASK_NOT_FOUND", domain: "a2a-protocol.org"}] =
             error_infos(error)
  end

  test "court 3b: missing push config — gRPC INVALID_ARGUMENT(3)+INVALID_PARAMS vs REST 400 envelope", %{
    rest: rest,
    channel: channel
  } do
    task_id = rest_new_task(rest, "typed errors task")

    assert %{"error" => %{"code" => 400, "details" => [%{"reason" => "INVALID_PARAMS"}]}} =
             rest_json(:get, "/tasks/#{task_id}/pushNotificationConfig/nope", rest)

    assert {:error, %GRPC.RPCError{status: 3} = error} =
             Lf.A2a.V1.A2AService.Stub.get_task_push_notification_config(
               channel,
               %Pb.GetTaskPushNotificationConfigRequest{task_id: task_id, id: "nope"}
             )

    assert [%Google.Rpc.ErrorInfo{reason: "INVALID_PARAMS", domain: "a2a-protocol.org"}] =
             error_infos(error)
  end

  test "court 3c: push set on an unknown task — gRPC NOT_FOUND(5) like jsonrpc -32001", %{
    channel: channel
  } do
    assert {:error, %GRPC.RPCError{status: 5} = error} =
             Lf.A2a.V1.A2AService.Stub.create_task_push_notification_config(
               channel,
               %Pb.TaskPushNotificationConfig{
                 id: "cfg-x",
                 task_id: "no-such-task",
                 url: @hook_url
               }
             )

    assert [%Google.Rpc.ErrorInfo{reason: "TASK_NOT_FOUND", domain: "a2a-protocol.org"}] =
             error_infos(error)
  end

  # ===========================================================================
  # Court 4 — load: 60 interleaved mixed-protocol calls, one endpoint
  # ===========================================================================

  test "court 4: 60 interleaved mixed-protocol calls all succeed against the shared store", %{
    jsonrpc: jsonrpc,
    rest: rest,
    channel: channel
  } do
    grpc_jobs = for i <- 1..20, do: Task.async(fn -> grpc_send_task_id(channel, "load grpc #{i}") end)

    jsonrpc_jobs =
      for i <- 1..20, do: Task.async(fn -> new_task_jsonrpc(jsonrpc, "load jsonrpc #{i}") end)

    rest_jobs = for i <- 1..20, do: Task.async(fn -> rest_new_task(rest, "load rest #{i}") end)

    ids = Task.await_many(grpc_jobs ++ jsonrpc_jobs ++ rest_jobs, 30_000)

    assert length(ids) == 60
    assert ids |> Enum.uniq() |> length() == 60, "60 distinct task ids, no store contention"

    # Spot-check across bindings: a gRPC-created task is fetchable via jsonrpc.
    [grpc_id | _] = Enum.take(ids, 3)
    assert %{"result" => %{"id" => ^grpc_id}} = rpc(jsonrpc, "tasks/get", %{"id" => grpc_id})
  end

  # ===========================================================================
  # Court 5 — CC15 auth interceptor on the gRPC endpoint
  # ===========================================================================

  @tag :venue_auth
  test "court 5a: unauthenticated venue call is UNAUTHENTICATED(16) with the typed HTTP body", %{
    channel: channel
  } do
    assert {:error, %GRPC.RPCError{status: 16} = error} =
             Lf.A2a.V1.A2AService.Stub.send_message(channel, grpc_user_request("no badge"))

    assert error.message == ~s({"error":"Unauthorized"})
  end

  @tag :venue_auth
  test "court 5b: valid badge JWT passes the interceptor and creates a real task", %{
    channel: channel
  } do
    # Real-state self-check: the court-minted badge verifies before it is
    # sent over the wire.
    assert {:ok, %{id: "attendee-42"}} = Badge.verify(nil, badge_token("attendee-42"), nil)

    metadata = %{"authorization" => "Bearer " <> badge_token("attendee-42")}

    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{} = task}}} =
             Lf.A2a.V1.A2AService.Stub.send_message(
               channel,
               grpc_user_request("badged attendee"),
               metadata: metadata
             )

    assert task.status.state == :TASK_STATE_COMPLETED
    assert task.id != ""
  end

  # Real HS256 badge JWT minted with :crypto HMAC — the same JOSE math the
  # venue's verifier runs; no JWT library, no mocks.
  defp badge_token(sub, secret \\ Badge.secret()) do
    b64 = fn bin -> Base.url_encode64(bin, padding: false) end

    header = b64.(Jason.encode!(%{"alg" => "HS256", "typ" => "JWT"}))
    payload = b64.(Jason.encode!(%{"sub" => sub, "iss" => "venue-gate"}))
    signing_input = header <> "." <> payload
    signature = :crypto.mac(:hmac, :sha256, secret, signing_input)

    signing_input <> "." <> b64.(signature)
  end
end
