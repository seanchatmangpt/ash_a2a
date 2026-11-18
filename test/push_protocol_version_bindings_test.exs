# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.PushProtocolVersion.Probe do
  @moduledoc false
  use Ash.Resource,
    domain: AshA2A.PushProtocolVersion.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:echo, :read)
  end
end

defmodule AshA2A.PushProtocolVersion.Domain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.PushProtocolVersion.Probe)
  end
end

defmodule AshA2A.PushProtocolVersion.RestAgent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.PushProtocolVersion.Probe,
    name: "y5_push_version_rest_agent"
end

defmodule AshA2A.PushProtocolVersion.GrpcAgent do
  @moduledoc false
  use AshA2A.Protocol.Agent, name: "y5-push-version-grpc", description: "replies ok"

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _ctx), do: {:reply, [AshA2A.Protocol.Part.Text.new("ok")]}
end

defmodule AshA2A.PushProtocolVersion.GrpcHandler do
  @moduledoc """
  Real gRPC handler: tasks over the real agent, push-config CRUD over the SAME
  `AshA2A.A2ATransport.PushConfigRPC` the REST binding uses. Unlike the
  venue handler it forwards `protocol_version` both ways and the request's
  negotiated `a2a_version`.
  """

  @behaviour AshA2A.Protocol.JSONRPC

  alias AshA2A.A2ATransport.{PushConfigRPC, TaskEvents}
  alias AshA2A.Protocol.JSONRPC.Error

  @impl true
  def handle_send(message, _params, %{agent: agent}), do: AshA2A.Protocol.call(agent, message)

  @impl true
  def handle_get(id, _params, %{agent: agent}) do
    case GenServer.call(agent, {:get_task, id}) do
      {:ok, _} = ok -> ok
      {:error, :not_found} -> {:error, Error.task_not_found()}
    end
  end

  @impl true
  def handle_cancel(_id, _params, _ctx), do: {:error, Error.task_not_cancelable()}

  @impl true
  def handle_set_push_config(config, _params, ctx) do
    raw =
      %{"id" => config.id, "url" => config.url, "token" => config.token}
      |> put_version(config.protocol_version)

    case push("tasks/pushNotificationConfig/set", Map.put(raw, "taskId", config.task_id), ctx) do
      {:ok, envelope} -> {:ok, lift(envelope)}
      {:error, _} = error -> error
    end
  end

  @impl true
  def handle_get_push_config(task_id, config_id, _params, ctx) do
    case push(
           "tasks/pushNotificationConfig/get",
           %{"id" => task_id, "pushNotificationConfigId" => config_id},
           ctx
         ) do
      {:ok, envelope} -> {:ok, lift(envelope)}
      {:error, _} = error -> error
    end
  end

  @impl true
  def handle_list_push_configs(task_id, _params, ctx) do
    case push("tasks/pushNotificationConfig/list", %{"id" => task_id}, ctx) do
      {:ok, %{"configs" => envelopes}} -> {:ok, Enum.map(envelopes, &lift/1)}
      {:ok, envelopes} when is_list(envelopes) -> {:ok, Enum.map(envelopes, &lift/1)}
      {:error, _} = error -> error
    end
  end

  @impl true
  def handle_delete_push_config(task_id, config_id, _params, ctx),
    do:
      push(
        "tasks/pushNotificationConfig/delete",
        %{"id" => task_id, "pushNotificationConfigId" => config_id},
        ctx
      )

  defp put_version(raw, v) when is_binary(v) and v != "", do: Map.put(raw, "protocolVersion", v)
  defp put_version(raw, _), do: raw

  defp push(method, params, ctx) do
    push_ctx = %{
      agent: ctx.agent,
      transport: ctx.transport,
      push_opts: TaskEvents.push_opts(ctx.transport),
      principal: Map.get(ctx, :principal, :anonymous),
      wire: :v1,
      a2a_version: Map.get(ctx, :a2a_version)
    }

    case PushConfigRPC.handle(method, params, :y5, push_ctx) do
      %{"result" => result} -> {:ok, result}
      %{"error" => e} -> {:error, %Error{code: e["code"], message: e["message"], data: e["data"]}}
    end
  end

  defp lift(%{"taskId" => task_id, "url" => _} = flat) do
    %AshA2A.Protocol.PushNotificationConfig{
      id: flat["id"],
      task_id: task_id,
      url: flat["url"],
      token: flat["token"],
      protocol_version: flat["protocolVersion"]
    }
  end

  defp lift(%{"taskId" => task_id, "pushNotificationConfig" => inner}) do
    %AshA2A.Protocol.PushNotificationConfig{
      id: inner["id"],
      task_id: task_id,
      url: inner["url"],
      token: inner["token"],
      protocol_version: inner["protocolVersion"]
    }
  end
end

defmodule AshA2A.PushProtocolVersionBindingsTest do
  @moduledoc """
  Y5 courts: `protocolVersion` on a push notification config round-trips on
  both the gRPC and the REST binding through the one real transport
  `PushConfigStore`: explicit version wins, the default is the creating
  request's A2A-Version, a malformed version is a typed refusal. gRPC runs over
  a real cowboy HTTP/2 listener and Mint client; REST over the real
  `HTTPJSON` plug and the same store. No mocks, no sleeps.
  """

  use ExUnit.Case, async: false

  alias AshA2A.A2ATransport.PushConfigStore
  alias AshA2A.Transport.HTTPJSON
  alias AshA2A.PushProtocolVersion.{GrpcAgent, GrpcHandler, RestAgent}
  alias Lf.A2a.V1, as: Pb
  alias Lf.A2a.V1.A2AService.Stub

  @server AshA2A.Transport.GRPC.Server
  @hook "http://127.0.0.1:9/hook"
  @v10 [metadata: %{"a2a-version" => "1.0"}]
  @v11 [metadata: %{"a2a-version" => "1.1"}]

  setup do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [RestAgent, GrpcAgent])

    transport = Module.concat(__MODULE__, Transport)

    start_supervised!(
      {AshA2A.A2ATransport,
       name: transport,
       push: [
         allow_http: true,
         allow_cidrs: ["127.0.0.1/32"],
         max_attempts: 1,
         base_backoff_ms: 5
       ]}
    )

    on_exit(fn -> Application.delete_env(:ash_a2a, @server) end)

    sup =
      start_supervised!(
        {AshA2A.Transport.GRPC.Supervisor,
         port: 0,
         handler: GrpcHandler,
         ctx: %{agent: GrpcAgent, opts: %{}, transport: transport, principal: :anonymous},
         name: Module.concat(__MODULE__, GrpcSup)}
      )

    port = AshA2A.Transport.GRPC.Supervisor.port(sup)
    {:ok, ch} = GRPC.Stub.connect("localhost:#{port}", adapter: GRPC.Client.Adapters.Mint)

    versions = Enum.uniq(AshA2A.Protocol.Version.supported_default() ++ ["1.0", "1.1"])

    rest =
      HTTPJSON.init(
        agent: RestAgent,
        base_url: "http://127.0.0.1:9/a2a",
        transport: transport,
        push_notifications: true,
        versions: versions
      )

    {:ok,
     channel: ch,
     rest: rest,
     transport: transport,
     store: AshA2A.A2ATransport.push_store_name(transport)}
  end

  # -- gRPC helpers --------------------------------------------------------------

  defp grpc_task(ch) do
    req = %Pb.SendMessageRequest{
      message: %Pb.Message{
        message_id: AshA2A.Protocol.ID.generate("y5p"),
        role: :ROLE_USER,
        parts: [%Pb.Part{content: {:text, "hello"}}]
      }
    }

    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{id: id}}}} =
             Stub.send_message(ch, req, @v11)

    id
  end

  defp grpc_create(ch, task_id, id, opts, extra \\ []) do
    cfg = struct(%Pb.TaskPushNotificationConfig{id: id, task_id: task_id, url: @hook}, extra)
    Stub.create_task_push_notification_config(ch, cfg, opts)
  end

  defp grpc_get(ch, task_id, id, opts),
    do:
      Stub.get_task_push_notification_config(
        ch,
        %Pb.GetTaskPushNotificationConfigRequest{task_id: task_id, id: id},
        opts
      )

  # -- REST helpers --------------------------------------------------------------

  defp rest_req(method, path, opts, body \\ nil, headers \\ []) do
    conn = Plug.Test.conn(method, path, body && Jason.encode!(body))

    conn =
      if body, do: Plug.Conn.put_req_header(conn, "content-type", "application/json"), else: conn

    conn = Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
    HTTPJSON.call(conn, opts)
  end

  defp rest_json(conn), do: Jason.decode!(conn.resp_body)

  defp rest_task(opts) do
    {:ok, msg} = AshA2A.Protocol.JSON.encode(AshA2A.Protocol.Message.new_user("hello"))
    conn = rest_req(:post, "/message:send", opts, %{"message" => msg})
    %{"task" => %{"id" => id}} = rest_json(conn)
    id
  end

  # v1 flat TaskPushNotificationConfig body (reports any stored protocolVersion back).
  defp rest_set_flat(opts, task_id, config, headers) do
    rest_req(:post, "/tasks/#{task_id}/pushNotificationConfig", opts, config, headers)
  end

  defp rest_set(opts, task_id, config, headers \\ [], extra \\ %{}) do
    rest_req(
      :post,
      "/tasks/#{task_id}/pushNotificationConfig",
      opts,
      Map.merge(%{"pushNotificationConfig" => config}, extra),
      headers
    )
  end

  # -- gRPC ------------------------------------------------------------------------

  test "gRPC: an explicit protocol_version round-trips create/get/list and lands in the store",
       ctx do
    task_id = grpc_task(ctx.channel)

    assert {:ok, %Pb.TaskPushNotificationConfig{protocol_version: "1.1"}} =
             grpc_create(ctx.channel, task_id, "g-explicit", @v11, protocol_version: "1.1")

    assert {:ok, %Pb.TaskPushNotificationConfig{id: "g-explicit", protocol_version: "1.1"}} =
             grpc_get(ctx.channel, task_id, "g-explicit", @v11)

    assert {:ok, %Pb.ListTaskPushNotificationConfigsResponse{configs: configs}} =
             Stub.list_task_push_notification_configs(
               ctx.channel,
               %Pb.ListTaskPushNotificationConfigsRequest{task_id: task_id},
               @v11
             )

    assert Enum.any?(configs, &(&1.id == "g-explicit" and &1.protocol_version == "1.1"))

    assert {:ok, %{protocol_version: "1.1"}} =
             PushConfigStore.get(ctx.store, task_id, "g-explicit")
  end

  test "gRPC: an explicit protocol_version wins over the request's A2A-Version", ctx do
    task_id = grpc_task(ctx.channel)

    assert {:ok, _} = grpc_create(ctx.channel, task_id, "g-wins", @v11, protocol_version: "1.0")

    assert {:ok, %{protocol_version: "1.0"}} = PushConfigStore.get(ctx.store, task_id, "g-wins")

    assert {:ok, %Pb.TaskPushNotificationConfig{protocol_version: "1.0"}} =
             grpc_get(ctx.channel, task_id, "g-wins", @v11)
  end

  test "gRPC: without protocol_version the default is the creating request's A2A-Version", ctx do
    task_id = grpc_task(ctx.channel)

    assert {:ok, _} = grpc_create(ctx.channel, task_id, "g-default-11", @v11)
    assert {:ok, _} = grpc_create(ctx.channel, task_id, "g-default-10", @v10)

    assert {:ok, %{protocol_version: "1.1"}} =
             PushConfigStore.get(ctx.store, task_id, "g-default-11")

    assert {:ok, %{protocol_version: "1.0"}} =
             PushConfigStore.get(ctx.store, task_id, "g-default-10")

    assert {:ok, %Pb.TaskPushNotificationConfig{protocol_version: "1.1"}} =
             grpc_get(ctx.channel, task_id, "g-default-11", @v11)
  end

  test "gRPC: a malformed protocol_version is refused INVALID_ARGUMENT(3) and nothing is stored",
       ctx do
    task_id = grpc_task(ctx.channel)

    assert {:error, %GRPC.RPCError{status: 3}} =
             grpc_create(ctx.channel, task_id, "g-bad", @v11, protocol_version: "nope")

    assert :error = PushConfigStore.get(ctx.store, task_id, "g-bad")
  end

  # -- REST --------------------------------------------------------------------------

  test "REST: an explicit protocolVersion round-trips set/get/list and lands in the store", ctx do
    task_id = rest_task(ctx.rest)

    conn =
      rest_set(ctx.rest, task_id, %{
        "id" => "r-explicit",
        "url" => @hook,
        "protocolVersion" => "1.1"
      })

    assert conn.status == 200
    assert %{"id" => "r-explicit", "protocolVersion" => "1.1"} = rest_json(conn)

    got = rest_req(:get, "/tasks/#{task_id}/pushNotificationConfig/r-explicit", ctx.rest)
    assert got.status == 200
    assert %{"protocolVersion" => "1.1"} = rest_json(got)

    list = rest_req(:get, "/tasks/#{task_id}/pushNotificationConfig", ctx.rest)
    assert %{"configs" => configs} = rest_json(list)
    assert Enum.any?(configs, &(&1["id"] == "r-explicit" and &1["protocolVersion"] == "1.1"))

    assert {:ok, %{protocol_version: "1.1"}} =
             PushConfigStore.get(ctx.store, task_id, "r-explicit")
  end

  test "REST: an explicit protocolVersion wins over the A2A-Version header", ctx do
    task_id = rest_task(ctx.rest)

    conn =
      rest_set_flat(
        ctx.rest,
        task_id,
        %{"id" => "r-wins", "url" => @hook, "protocolVersion" => "1.0"},
        [{"a2a-version", "1.1"}]
      )

    assert conn.status == 200
    # <1.1 configs are reported in the exact pre-1.1 shape (no protocolVersion key);
    # the explicit value still wins and is what the store holds.
    refute Map.has_key?(rest_json(conn), "protocolVersion")
    assert {:ok, %{protocol_version: "1.0"}} = PushConfigStore.get(ctx.store, task_id, "r-wins")
  end

  test "REST: without protocolVersion the default is the creating request's A2A-Version", ctx do
    task_id = rest_task(ctx.rest)

    c11 =
      rest_set(ctx.rest, task_id, %{"id" => "r-default-11", "url" => @hook}, [
        {"a2a-version", "1.1"}
      ])

    assert %{"protocolVersion" => "1.1"} = rest_json(c11)

    c10 =
      rest_set_flat(ctx.rest, task_id, %{"id" => "r-default-10", "url" => @hook}, [
        {"a2a-version", "1.0"}
      ])

    refute Map.has_key?(rest_json(c10), "protocolVersion")

    assert {:ok, %{protocol_version: "1.1"}} =
             PushConfigStore.get(ctx.store, task_id, "r-default-11")

    assert {:ok, %{protocol_version: "1.0"}} =
             PushConfigStore.get(ctx.store, task_id, "r-default-10")
  end

  test "REST: a top-level protocolVersion beside pushNotificationConfig passes through", ctx do
    task_id = rest_task(ctx.rest)

    conn =
      rest_set(ctx.rest, task_id, %{"id" => "r-top", "url" => @hook}, [], %{
        "protocolVersion" => "1.1"
      })

    assert conn.status == 200
    assert %{"protocolVersion" => "1.1"} = rest_json(conn)
    assert {:ok, %{protocol_version: "1.1"}} = PushConfigStore.get(ctx.store, task_id, "r-top")
  end

  test "REST: a malformed protocolVersion is 400 and nothing is stored", ctx do
    task_id = rest_task(ctx.rest)

    conn =
      rest_set(ctx.rest, task_id, %{"id" => "r-bad", "url" => @hook, "protocolVersion" => "nope"})

    assert conn.status == 400
    assert :error = PushConfigStore.get(ctx.store, task_id, "r-bad")
  end

  # -- cross-binding -----------------------------------------------------------------

  test "a version stored via gRPC and one stored via REST are read identically from the one store",
       ctx do
    g_task = grpc_task(ctx.channel)
    r_task = rest_task(ctx.rest)

    assert {:ok, _} = grpc_create(ctx.channel, g_task, "x-g", @v11, protocol_version: "1.1")

    assert 200 ==
             rest_set(ctx.rest, r_task, %{
               "id" => "x-r",
               "url" => @hook,
               "protocolVersion" => "1.1"
             }).status

    assert {:ok, %{protocol_version: gv}} = PushConfigStore.get(ctx.store, g_task, "x-g")
    assert {:ok, %{protocol_version: rv}} = PushConfigStore.get(ctx.store, r_task, "x-r")
    assert gv == rv
    assert gv == "1.1"
  end
end
