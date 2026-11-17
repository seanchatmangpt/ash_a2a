# NOTE: 5 module(s) removed from this consolidated file because the repaired originals (kept as separate files) define the same modules; see docs/reference/test-consolidation-merge.md.
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: Root Task Store Contracts & Runtime Hardening
# Consolidated from 14 source files:
#   - test/push_notification_delivery_test.exs
#   - test/push_protocol_version_bindings_test.exs
#   - test/receipt_digest_determinism_test.exs
#   - test/registry_discovery_test.exs
#   - test/rest_live_paths_test.exs
#   - test/runtime_hardening_test.exs
#   - test/security_review_remediation_test.exs
#   - test/semantic_engine_test.exs
#   - test/semantic_serialization_test.exs
#   - test/sibling_dep_integrity_test.exs
#   - test/spg_conformance_runtime_test.exs
#   - test/sse_generation_frames_test.exs
#   - test/sse_stream_wire_test.exs
#   - test/stream_generation_frames_test.exs
# ==============================================================================

# --- SOURCE: test/push_notification_delivery_test.exs ---



# --- SOURCE: test/push_protocol_version_bindings_test.exs ---
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

# --- SOURCE: test/receipt_digest_determinism_test.exs ---
defmodule AshA2A.ReceiptDigestDeterminismTest do
  use ExUnit.Case, async: true

  test "digests are insertion-order independent for large maps" do
    pairs = for i <- 1..200, do: {"k#{i}", i}
    a = Map.new(pairs)
    b = Map.new(Enum.reverse(pairs))
    assert AshA2A.Evidence.Class.digest(a) == AshA2A.Evidence.Class.digest(b)
  end
end

# --- SOURCE: test/registry_discovery_test.exs ---
defmodule AshA2A.RegistryDiscoveryTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias AshA2A.Protocol.Registry
  alias AshA2A.Protocol.Registry.Plug, as: RegPlug

  defmodule AgentA, do: nil
  defmodule AgentB, do: nil
  defmodule Bare, do: nil

  @card_a %{
    name: "a",
    provider: %{organization: "Acme"},
    capabilities: %{streaming: true},
    default_input_modes: ["text/plain"],
    default_output_modes: ["application/json"],
    skills: [%{id: "a.price", tags: ["pricing"]}]
  }
  @card_b %{
    name: "b",
    provider: %{organization: "Beta"},
    capabilities: %{streaming: false},
    default_input_modes: ["image/png"],
    default_output_modes: ["text/plain"],
    skills: [%{id: "b.risk", tags: ["risk", "pricing"]}]
  }

  setup do
    name = :"w15_reg_#{System.unique_integer([:positive])}"

    disclose = fn card, principal ->
      case principal do
        "id:trusted" -> card
        _ -> Map.drop(card, [:provider])
      end
    end

    {:ok, _} = start_supervised({Registry, name: name, disclose: disclose})
    :ok = Registry.register(name, AgentA, @card_a)
    :ok = Registry.register(name, AgentB, @card_b)
    :ok = Registry.register(name, Bare, %{name: "bare"})
    %{reg: name}
  end

  test "card without skills does not crash find_by_skill", %{reg: reg} do
    assert Enum.sort(Registry.find_by_skill(reg, "pricing")) == [AgentA, AgentB]
  end

  test "multi-criteria find", %{reg: reg} do
    assert [{AgentB, _}] = Registry.find(reg, %{tag: "risk", capabilities: %{streaming: false}})
    assert [{AgentA, _}] = Registry.find(reg, %{provider: "Acme", input_mode: "text/plain"})

    assert [{AgentA, _}] =
             Registry.find(reg, %{skill_id: "a.price", output_mode: "application/json"})

    assert [] = Registry.find(reg, %{tag: "pricing", provider: "Nobody"})
  end

  test "disclosure differs per principal", %{reg: reg} do
    {:ok, trusted} = Registry.get_for(reg, AgentA, "id:trusted")
    {:ok, other} = Registry.get_for(reg, AgentA, "id:other")
    assert Map.has_key?(trusted, :provider)
    refute Map.has_key?(other, :provider)
    assert {:error, :not_found} = Registry.get_for(reg, Nope, "id:other")
  end

  defp get(reg, path, headers \\ []) do
    conn = conn(:get, path)
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    RegPlug.call(conn, RegPlug.init(registry: reg))
  end

  test "plug 200 list, filter, 404 and ETag 304", %{reg: reg} do
    conn = get(reg, "/registry/agents?tag=risk")
    assert conn.status == 200
    assert [cc] = get_resp_header(conn, "cache-control")
    assert cc =~ "max-age"
    assert %{"agents" => [%{"id" => id}]} = Jason.decode!(conn.resp_body)
    assert id == inspect(AgentB)

    [etag] = get_resp_header(conn, "etag")
    again = get(reg, "/registry/agents?tag=risk", [{"if-none-match", etag}])
    assert again.status == 304

    one = get(reg, "/registry/agents/" <> inspect(AgentA))
    assert one.status == 200
    assert %{"card" => %{"name" => "a"}} = Jason.decode!(one.resp_body)

    assert get(reg, "/registry/agents/Missing.Agent").status == 404
  end
end

# --- SOURCE: test/rest_live_paths_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.RestLivePaths.Resource do
  @moduledoc "Real fixture: `:converse` parks in input_required when :text is omitted."

  use Ash.Resource,
    domain: AshA2A.RestLivePaths.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  actions do
    action :converse, :map do
      argument(:text, :string, allow_nil?: false)

      run(fn input, _context -> {:ok, %{text: input.arguments.text}} end)
    end
  end

  a2a do
    skill(:converse, :converse, consequence: :observe)
  end
end

defmodule AshA2A.RestLivePaths.Domain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.RestLivePaths.Resource)
  end
end

defmodule AshA2A.RestLivePaths.Agent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.RestLivePaths.Resource,
    name: "y5_rest_live_agent"
end

defmodule AshA2A.RestLivePaths.PlainAgent do
  @moduledoc false
  # Real Protocol.Agent that does not declare streaming.
  use AshA2A.Protocol.Agent, name: "y5-rest-plain", description: "no streaming"

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _ctx),
    do: {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
end

defmodule AshA2A.RestLivePaths.StreamingAgent do
  @moduledoc false
  use AshA2A.Protocol.Agent,
    name: "y5-rest-streaming",
    description: "streaming, parks in input_required",
    capabilities: %{streaming: true}

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _ctx),
    do: {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
end

defmodule AshA2A.RestLivePaths.FlakyCardAgent do
  @moduledoc false
  # Hand-written real implementation of the agent card interface: the first
  # `:get_agent_card` (the transport's own capability probe) answers a
  # streaming card; every later one (the Live core's own card fetch) answers
  # a non-card, which the Live core reports as `{:error, :unavailable}`.
  use GenServer

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, :ok, name: Keyword.fetch!(opts, :name))

  @impl true
  def init(:ok), do: {:ok, 0}

  @impl true
  def handle_call(:get_agent_card, _from, 0),
    do: {:reply, %{name: "y5-flaky", capabilities: %{streaming: true}}, 1}

  def handle_call(:get_agent_card, _from, n), do: {:reply, :unavailable, n + 1}
  def handle_call(_other, _from, n), do: {:reply, {:error, :unsupported}, n}
end

defmodule AshA2A.RestLivePaths.Pipeline do
  @moduledoc "Stamps a verified identity (`x-y5-user` header, default alice) on every request."

  @behaviour Plug

  def init(opts) when is_map(opts), do: opts
  def init(opts), do: AshA2A.Transport.HTTPJSON.init(opts)

  def call(conn, opts) do
    user = List.first(Plug.Conn.get_req_header(conn, "x-y5-user")) || "alice"
    conn = AshA2A.Protocol.Plug.Auth.put_identity(conn, %{identity: user})
    AshA2A.Transport.HTTPJSON.call(conn, opts)
  end
end

defmodule AshA2A.RestLivePathsTest do
  @moduledoc """
  Y5 courts: REST `POST /{tenant}/message:live` and its uplink failure
  surface over real Bandit and real `Req`: path tenant binding, uplink by
  `live_session_id` (query and body), streaming-disabled 400, 503 when the
  agent card is unreachable (downlink and uplink), and the missing-task
  uplink at the Live core the REST binding maps to 404. Waits are
  deadline-bounded receives, no sleeps.
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.Protocol.{Message, Part}
  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.RestLivePaths.{Agent, FlakyCardAgent, PlainAgent, Pipeline, StreamingAgent}

  @v11 [{"a2a-version", "1.1"}]
  @deadline_ms 5_000

  setup do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [Agent])

    {:ok, server: start_server(Agent)}
  end

  # -- helpers -----------------------------------------------------------------

  defp start_server(agent) do
    versions = Enum.uniq(AshA2A.Protocol.Version.supported_default() ++ ["1.0", "1.1"])
    opts = [agent: agent, base_url: "http://127.0.0.1/fixture", versions: versions]
    EphemeralHttp.start!({Pipeline, Pipeline.init(opts)})
  end

  defp parked, do: AshA2A.Protocol.JSON.encode!(Message.new_user([Part.Data.new(%{})]))
  defp send_body(message), do: %{"sendMessage" => %{"message" => message}}
  defp live_url(server, prefix \\ ""), do: server.base_url <> prefix <> "/message:live"

  defp frames(buffer) do
    buffer
    |> String.split("\n\n")
    |> Enum.drop(-1)
    |> Enum.flat_map(fn
      "data: " <> json -> [Jason.decode!(json)]
      _comment -> []
    end)
  end

  defp open_sse(url, json, headers) do
    parent = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        Req.request!(
          method: :post,
          url: url,
          json: json,
          headers: headers,
          retry: false,
          receive_timeout: 20_000,
          into: fn {:data, data}, {req, resp} ->
            case Req.Response.get_header(resp, "a2a-live-session-id") do
              [sid | _] -> send(parent, {:sid, ref, sid})
              [] -> :ok
            end

            send(parent, {:sse, ref, data})
            {:cont, {req, resp}}
          end
        )
      end)

    on_exit(fn -> Process.exit(task.pid, :kill) end)
    ref
  end

  defp session_id(ref) do
    receive do
      {:sid, ^ref, sid} -> sid
    after
      @deadline_ms -> flunk("no a2a-live-session-id response header")
    end
  end

  defp collect_until(ref, buffer, pred) do
    deadline = System.monotonic_time(:millisecond) + @deadline_ms
    do_collect(ref, buffer, pred, deadline)
  end

  defp do_collect(ref, buffer, pred, deadline) do
    all = frames(buffer)

    if pred.(all) do
      {all, buffer}
    else
      remaining = deadline - System.monotonic_time(:millisecond)
      if remaining <= 0, do: flunk("deadline; frames so far: #{inspect(all)}")

      receive do
        {:sse, ^ref, data} -> do_collect(ref, buffer <> data, pred, deadline)
      after
        remaining -> flunk("deadline; frames so far: #{inspect(all)}")
      end
    end
  end

  # Opens a downlink and returns {ref, task_id, sid, buffer}.
  defp open_downlink(url) do
    ref = open_sse(url, send_body(parked()), @v11)
    {[%{"task" => %{"id" => id}} | _], buffer} = collect_until(ref, "", &(&1 != []))
    {ref, id, session_id(ref), buffer}
  end

  # -- per-request tenant --------------------------------------------------------

  test "/{tenant}/message:live binds the path tenant: the live task is visible to that tenant only",
       %{
         server: server
       } do
    {ref, id, sid, buffer} = open_downlink(live_url(server, "/acme"))

    ack =
      Req.post!(
        url: live_url(server, "/acme"),
        json: send_body(Map.put(parked(), "taskId", id)),
        headers: @v11 ++ [{"a2a-live-session-id", sid}],
        retry: false
      )

    assert ack.status == 200
    assert %{"id" => ^id} = ack.body

    {frames, _} =
      collect_until(ref, buffer, fn fs -> Enum.any?(fs, &Map.has_key?(&1, "statusUpdate")) end)

    assert Enum.any?(frames, &Map.has_key?(&1, "statusUpdate"))

    own = Req.get!(url: server.base_url <> "/acme/tasks/#{id}", headers: @v11, retry: false)
    assert own.status == 200
    assert %{"id" => ^id} = own.body

    foreign = Req.get!(url: server.base_url <> "/other/tasks/#{id}", headers: @v11, retry: false)
    assert foreign.status == 404
  end

  # -- uplink via live_session_id ---------------------------------------------------

  test "uplink via the live_session_id query parameter answers the ack task only", %{
    server: server
  } do
    {ref, id, sid, buffer} = open_downlink(live_url(server))

    ack =
      Req.post!(
        url: live_url(server) <> "?live_session_id=#{sid}",
        json: send_body(Map.put(parked(), "taskId", id)),
        headers: @v11,
        retry: false
      )

    assert ack.status == 200
    assert %{"id" => ^id} = ack.body
    refute Map.has_key?(ack.body, "statusUpdate")

    {frames, _} =
      collect_until(ref, buffer, fn fs -> Enum.any?(fs, &Map.has_key?(&1, "statusUpdate")) end)

    assert Enum.any?(frames, &Map.has_key?(&1, "statusUpdate"))
  end

  test "uplink via the live_session_id body key answers the ack task only", %{server: server} do
    {_ref, id, sid, _buffer} = open_downlink(live_url(server))

    body =
      send_body(Map.put(parked(), "taskId", id))
      |> Map.put("live_session_id", sid)

    ack = Req.post!(url: live_url(server), json: body, headers: @v11, retry: false)

    assert ack.status == 200
    assert %{"id" => ^id} = ack.body
  end

  # -- missing task -----------------------------------------------------------------

  test "uplink naming a task that does not exist is {:error, :not_found} at the Live core (REST: 404)" do
    start_supervised!({StreamingAgent, []})

    unless Process.whereis(AshA2A.Transport.Live.Registry),
      do: start_supervised!(AshA2A.Transport.Live.Supervisor)

    request = send_body(Map.put(parked(), "taskId", "y5-no-such-task"))

    assert {:error, :not_found} =
             AshA2A.Transport.Live.uplink_call(
               StreamingAgent,
               %{metadata: %{}, principal: :anonymous},
               request
             )
  end

  # -- streaming disabled -------------------------------------------------------------

  test "message:live when streaming is disabled is 400 UNSUPPORTED_OPERATION" do
    start_supervised!({PlainAgent, []})
    server = start_server(PlainAgent)

    resp =
      Req.post!(url: live_url(server), json: send_body(parked()), headers: @v11, retry: false)

    assert resp.status == 400
    assert %{"error" => %{"details" => [%{"reason" => "UNSUPPORTED_OPERATION"} | _]}} = resp.body
  end

  # -- 503 unavailable ------------------------------------------------------------------

  test "uplink is 503 when the agent card becomes unreachable" do
    name = :"y5_flaky_uplink_#{System.unique_integer([:positive])}"
    start_supervised!({FlakyCardAgent, name: name}, id: name)
    server = start_server(name)

    resp =
      Req.post!(
        url: live_url(server),
        json: send_body(parked()),
        headers: @v11 ++ [{"a2a-live-session-id", "live-y5-any"}],
        retry: false
      )

    assert resp.status == 503
    assert %{"error" => %{}} = resp.body
  end

  test "downlink open is 503 when the agent card becomes unreachable" do
    name = :"y5_flaky_downlink_#{System.unique_integer([:positive])}"
    start_supervised!({FlakyCardAgent, name: name}, id: name)
    server = start_server(name)

    resp =
      Req.post!(url: live_url(server), json: send_body(parked()), headers: @v11, retry: false)

    assert resp.status == 503
    assert %{"error" => %{}} = resp.body
  end
end

# --- SOURCE: test/runtime_hardening_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT


# --- SOURCE: test/security_review_remediation_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SecurityReviewRemediationTest do
  use ExUnit.Case, async: true

  alias AshA2A.Protocol.PushNotificationSender.HTTP, as: PushHTTP
  alias AshA2A.Protocol.Version

  describe "A2A-Version echo" do
    test "hostile values never reach a response header verbatim" do
      assert Version.safe_echo("x\r\nSet-Cookie: a") == "invalid"
      assert Version.safe_echo(String.duplicate("9", 500)) == "invalid"
      assert Version.safe_echo("2.0") == "2.0"
    end

    test "lenient suffixes are not normalized into a supported version" do
      assert Version.normalize("1.1;x") == "1.1;x"
      assert Version.normalize("1.0-evil") == "1.0-evil"
      assert Version.normalize("1.1.3") == "1.1"
    end
  end

  describe "legacy push sender SSRF" do
    defp config(url), do: %{url: url, token: nil, authentication: nil}

    test "IPv4-mapped IPv6 loopback is refused" do
      assert {:error, {:private_host, _}} =
               PushHTTP.deliver(config("https://[::ffff:127.0.0.1]/hook"), %{"t" => 1})
    end

    test "CGNAT and metadata-adjacent literals are refused" do
      for host <- ["100.64.0.1", "0.0.0.0", "169.254.169.254"] do
        assert {:error, {:private_host, _}} =
                 PushHTTP.deliver(config("https://#{host}/hook"), %{"t" => 1}),
               host
      end
    end

    test "a redirect is reported, never followed" do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listener)

      server =
        Task.async(fn ->
          {:ok, sock} = :gen_tcp.accept(listener, 5_000)
          {:ok, _req} = :gen_tcp.recv(sock, 0, 5_000)

          :ok =
            :gen_tcp.send(
              sock,
              "HTTP/1.1 302 Found\r\nlocation: http://169.254.169.254/\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
            )

          :gen_tcp.close(sock)
        end)

      assert {:error, {:http_status, 302}} =
               PushHTTP.deliver(
                 config("http://127.0.0.1:#{port}/hook"),
                 %{"t" => 1},
                 block_private_ips: false,
                 require_https: false,
                 attempts: 1
               )

      Task.await(server, 5_000)
      :gen_tcp.close(listener)
    end
  end
end

defmodule AshA2A.Protocol.JSONGuardTest do
  use ExUnit.Case, async: true
  alias AshA2A.Protocol.JSONGuard

  test "deep nesting is refused, normal bodies decode" do
    assert {:error, {:nesting_exceeded, 64}} = JSONGuard.decode(String.duplicate("[", 100_000))
    assert {:ok, %{"a" => [1, %{"b" => 2}]}} = JSONGuard.decode(~s({"a":[1,{"b":2}]}))
  end

  test "brackets inside strings do not count toward depth" do
    body = Jason.encode!(%{"s" => String.duplicate("[", 500) <> "\\\"["})
    assert {:ok, _} = JSONGuard.decode(body, 4)
  end
end

# --- SOURCE: test/semantic_engine_test.exs ---

# --- SOURCE: test/semantic_serialization_test.exs ---
defmodule AshA2A.SemanticSerializationTest do
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{AgentCard, Ontology, Serialize}

  @evil "http://example.org/x> <http://evil/p> \"pwn\" . <http://a"

  test "Serialize escapes injection characters in IRIs and control chars in literals" do
    assert Serialize.escape_iri(@evil) =~ "\\u003E"
    refute Serialize.escape_iri(@evil) =~ ">"
    assert Serialize.escape_literal("a\rb\u0001c\"d") == "a\\rb\\u0001c\\\"d"
  end

  test "Ontology.to_ntriples cannot be injected through subject IRI and re-parses as one triple" do
    out =
      Ontology.to_ntriples([%{subject: @evil, predicate: "http://example.org/p", object: "o\rx"}])

    assert length(String.split(out, "\n", trim: true)) == 1
    refute out =~ "> <http://evil/p>"
    assert out =~ "\\r"
  end

  test "AgentCard.to_turtle escapes literals and IRIs via the shared writer" do
    decl = %AgentCard{
      capability_iri: "urn:cap:x",
      input_shape: @evil,
      output_shape: "urn:shape:out",
      consequence_class: "c\rd\"e",
      authority_requirement: "none",
      receipt_class: "r",
      semantic_basis: "b",
      version: "1",
      cost_envelope: "e",
      preconditions: [],
      effects: [],
      planner_compatibility: []
    }

    ttl = AgentCard.to_turtle(decl)
    refute ttl =~ "<http://evil/p>"
    assert ttl =~ "\\r"
    assert ttl =~ "\\u003E"
  end

  test "FalsifierSuite.to_ntriples escapes IRIs" do
    out =
      AshA2A.Semantic.FalsifierSuite.to_ntriples([
        {@evil, "http://example.org/p", {:lit, "a\rb"}}
      ])

    assert length(String.split(out, "\n", trim: true)) == 1
    refute out =~ "> <http://evil/p>"
    assert out =~ "\\r"
  end

  test "priv/sa2a/AllSA2A.ttl is byte-identical to canonical/AllSA2A.ttl (ggen.toml reads the former)" do
    assert File.read!("priv/sa2a/AllSA2A.ttl") == File.read!("priv/sa2a/canonical/AllSA2A.ttl")
  end
end

# --- SOURCE: test/sibling_dep_integrity_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SiblingDepIntegrityTest do
  @moduledoc """
  Sibling-dependency integrity courts.

    * the resolved `ash_graphlaw` artifact either carries a wasm whose SHA-256
      matches its own MANIFEST, or the court states loudly why it cannot run
      (the Hex package ships no wasm);
    * ash_atlassian / ash_planning_center are CANDIDATE intake rows only -
      no `lib/` module may reference them until an adapter is admitted.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("../lib", __DIR__)

  test "ash_graphlaw wasm digest matches its MANIFEST (or loud skip)" do
    dir = :code.priv_dir(:ash_graphlaw) |> to_string() |> Path.join("graphlaw")
    wasm = Path.join(dir, "graphlaw.wasm")
    manifest = Path.join(dir, "MANIFEST.json")

    if File.exists?(wasm) and File.exists?(manifest) do
      expected = manifest |> File.read!() |> Jason.decode!() |> get_in(["artifact", "sha256"])
      actual = :crypto.hash(:sha256, File.read!(wasm)) |> Base.encode16(case: :lower)
      assert actual == expected
    else
      IO.puts(
        "[SKIP] ash_graphlaw wasm not vendored in #{dir} " <>
          "(Hex package); use ASH_GRAPHLAW_PATH or the sibling checkout"
      )
    end
  end

  test "ash_atlassian / ash_planning_center are not referenced by lib/ (CANDIDATE only)" do
    offenders =
      @lib
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.filter(fn f -> File.read!(f) =~ ~r/AshAtlassian|AshPlanningCenter/ end)

    assert offenders == []
  end
end

# --- SOURCE: test/spg_conformance_runtime_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SpgConformanceRuntimeTest do
  use ExUnit.Case, async: true

  alias AshA2A.SpgConformance

  setup_all do
    cases = SpgConformance.load_all()
    {:ok, cases: cases}
  end

  test "the executable corpus is complete, balanced, unique, and seeded", %{cases: cases} do
    assert length(cases) == 56
    assert Enum.count(cases, &(&1["expect"] == "admit")) == 28
    assert Enum.count(cases, &(&1["expect"] == "refuse")) == 28

    assert Enum.map(cases, & &1["case_id"]) ==
             Enum.map(1..56, &"SPG-#{String.pad_leading(Integer.to_string(&1), 3, "0")}")

    assert Enum.map(cases, &get_in(&1, ["replay", "seed"])) == Enum.to_list(1..56)
    assert Enum.all?(cases, fn case -> match?({:ok, _}, SpgConformance.validate_case(case)) end)
  end

  test "reference runtime executes all 56 fixtures from stimulus, not oracle", %{cases: cases} do
    assert {:ok, summary} = SpgConformance.run_cases(cases)
    assert summary.total == 56
    assert summary.admitted == 28
    assert summary.refused == 28
    assert String.starts_with?(summary.corpus_digest, "sha256:")
  end

  test "corpus and case digests are deterministic and stimulus-bearing", %{cases: cases} do
    assert SpgConformance.corpus_digest(cases) == SpgConformance.corpus_digest(cases)

    first = hd(cases)
    mutated = put_in(first, ["stimulus", "checks", Access.at(0), "predicate"], "identity.changed")

    refute SpgConformance.case_digest(first) == SpgConformance.case_digest(mutated)
  end

  test "oracle cannot be flipped without independently changing the stimulus", %{cases: cases} do
    first = hd(cases)
    forged = Map.put(first, "expect", "refuse")

    assert {:error, {:invalid_spg_case, "SPG-001", _}} =
             SpgConformance.evaluate(forged)
  end

  test "typed refusal code laundering is detected", %{cases: cases} do
    refused = Enum.find(cases, &(&1["case_id"] == "SPG-002"))

    evaluator = fn _case ->
      {:refuse, "SPG_IDENTITY_WRONG_REFUSAL"}
    end

    assert {:error,
            {:refusal_code_drift, "SPG_IDENTITY_SUBJECT_SHA_MISMATCH",
             "SPG_IDENTITY_WRONG_REFUSAL"}} =
             SpgConformance.evaluate(refused, evaluator)
  end

  test "false admission of a negative case is rejected", %{cases: cases} do
    refused = Enum.find(cases, &(&1["case_id"] == "SPG-007"))

    evaluator = fn case ->
      {:admit,
       %{
         "subject" => case["subject"],
         "procedure" => case["procedure"],
         "authority" => %{"explicit" => true},
         "receipt" => %{"case_id" => case["case_id"]}
       }}
    end

    assert {:error, :false_admission} = SpgConformance.evaluate(refused, evaluator)
  end

  test "admitted consumer must preserve exact subject identity", %{cases: cases} do
    admitted = Enum.find(cases, &(&1["case_id"] == "SPG-004"))

    evaluator = fn case ->
      projection =
        case
        |> SpgConformance.reference_evaluator()
        |> elem(1)
        |> put_in(["subject", "base_sha"], String.duplicate("f", 40))

      {:admit, projection}
    end

    assert {:error, :subject_identity_drift} = SpgConformance.evaluate(admitted, evaluator)
  end

  test "admitted consumer must preserve procedure authority and receipt projections", %{
    cases: cases
  } do
    admitted = Enum.find(cases, &(&1["case_id"] == "SPG-044"))

    missing_authority = fn case ->
      {:admit,
       %{
         "subject" => case["subject"],
         "procedure" => case["procedure"],
         "receipt" => %{}
       }}
    end

    assert {:error, :authority_projection_missing} =
             SpgConformance.evaluate(admitted, missing_authority)

    missing_receipt = fn case ->
      {:admit,
       %{
         "subject" => case["subject"],
         "procedure" => case["procedure"],
         "authority" => %{}
       }}
    end

    assert {:error, :receipt_projection_missing} =
             SpgConformance.evaluate(admitted, missing_receipt)
  end

  test "two-pass replay detects evaluator nondeterminism", %{cases: cases} do
    admitted = Enum.find(cases, &(&1["case_id"] == "SPG-026"))
    key = make_ref()
    Process.put(key, 0)

    evaluator = fn case ->
      count = Process.get(key, 0)
      Process.put(key, count + 1)

      if rem(count, 2) == 0 do
        SpgConformance.reference_evaluator(case)
      else
        {:refuse, "SPG_REPLAY_NONDETERMINISTIC"}
      end
    end

    assert {:error, :nondeterministic_replay} =
             SpgConformance.evaluate(admitted, evaluator)
  end

  test "duplicate semantic case identity is refused before execution", %{cases: cases} do
    duplicate = cases ++ [hd(cases)]
    assert {:error, :duplicate_case_id} = SpgConformance.run_cases(duplicate)
  end
end

# --- SOURCE: test/sse_generation_frames_test.exs ---
defmodule AshA2A.SseGenerationFramesTest.StreamAgent do
  @moduledoc false
  use AshA2A.Protocol.Agent, name: "v13-stream", description: "streams three parts"

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context),
    do: {:stream, Stream.map(1..3, &AshA2A.Protocol.Part.Text.new("part #{&1}"))}
end

defmodule AshA2A.SseGenerationFramesTest do
  @moduledoc """
  V13 courts: the JSON-RPC SSE builder stamps strictly increasing
  `generation` on statusUpdate/artifactUpdate frames, never emits
  messageUpdate to pre-1.1 clients, and validates `lastSeenGeneration`.
  Real agent GenServer, real Plug pipeline (Plug.Test), no mocks, no sleeps.
  """

  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias AshA2A.SseGenerationFramesTest.StreamAgent

  setup do
    agent = :"v13_agent_#{System.unique_integer([:positive])}"
    start_supervised!({StreamAgent, name: agent})

    plug_opts =
      AshA2A.Protocol.Plug.init(
        agent: agent,
        base_url: "http://x/a2a",
        agent_card_opts: [capabilities: %{streaming: true}]
      )

    %{plug_opts: plug_opts}
  end

  defp stream(plug_opts, version) do
    {:ok, msg} = AshA2A.Protocol.JSON.encode(AshA2A.Protocol.Message.new_user("go"))

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "message/stream",
        "params" => %{"message" => msg}
      })

    conn =
      conn(:post, "/", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("a2a-version", version)
      |> AshA2A.Protocol.Plug.call(plug_opts)

    for "data: " <> json <- String.split(conn.resp_body, "\n", trim: true),
        do: Jason.decode!(json)["result"]
  end

  defp gens(results) do
    for r <- results,
        key <- ["statusUpdate", "artifactUpdate"],
        inner = r[key],
        do: inner["generation"]
  end

  test "1.1 stream: statusUpdate and artifactUpdate carry strictly increasing generations", %{
    plug_opts: plug_opts
  } do
    results = stream(plug_opts, "1.1")
    gens = gens(results)

    assert length(gens) >= 2
    assert Enum.all?(gens, &(is_integer(&1) or is_binary(&1)))
    ints = Enum.map(gens, &(&1 |> to_string() |> String.to_integer()))
    assert ints == Enum.sort(Enum.uniq(ints))
    assert hd(results)["task"]
  end

  test "1.0 stream: no messageUpdate frame and no error", %{plug_opts: plug_opts} do
    results = stream(plug_opts, "1.0")
    refute Enum.any?(results, &Map.has_key?(&1, "messageUpdate"))
    refute Enum.any?(results, &Map.has_key?(&1, "error"))
    assert hd(results)["task"]
  end

  test "invalid lastSeenGeneration answers -32602 before any stream opens" do
    conn =
      AshA2A.Protocol.Plug.SSE.subscribe_task(conn(:post, "/", ""), :unused_agent, "t", 1, 100,
        params: %{"lastSeenGeneration" => -1}
      )

    assert Jason.decode!(conn.resp_body)["error"]["code"] == -32602
  end

  test "StreamError helper writes a frame with no id line and keeps the stream open" do
    conn =
      conn(:post, "/", "")
      |> put_resp_header("content-type", "text/event-stream")
      |> send_chunked(200)
      |> AshA2A.Protocol.Plug.SSE.write_stream_error(5, %AshA2A.Protocol.StreamError{
        task_id: "t-1",
        code: "INVALID_ARGUMENT",
        message: "bad"
      })

    assert conn.state == :chunked
    assert conn.resp_body =~ "\"error\""
    refute conn.resp_body =~ "id: "
  end
end

# --- SOURCE: test/sse_stream_wire_test.exs ---
defmodule AshA2A.SseStreamWireTest.MessageAgent do
  @moduledoc false
  use AshA2A.Protocol.Agent, name: "w3-message", description: "answers with a bare message"

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context),
    do: {:message, [AshA2A.Protocol.Part.Text.new("direct answer")]}
end

defmodule AshA2A.SseStreamWireTest.StreamAgent do
  @moduledoc false
  use AshA2A.Protocol.Agent, name: "w3-stream", description: "streams three parts"

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context),
    do: {:stream, Stream.map(1..3, &AshA2A.Protocol.Part.Text.new("part #{&1}"))}
end

defmodule AshA2A.SseStreamWireTest do
  @moduledoc """
  W3 court: message/stream per spec section 3.1.2 over a real Bandit listener
  and real agent GenServers (no mocks): a bare Message answer is one `message`
  frame then close; the final artifact chunk carries `lastChunk: true` with the
  agent's own artifactId; Last-Event-ID replays only seq > N; the resubscribe
  snapshot frame carries no `id:` line.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.SseStreamWireTest.{MessageAgent, StreamAgent}

  defp boot(agent_mod) do
    uniq = System.unique_integer([:positive])
    agent = :"w3_agent_#{uniq}"
    transport = :"w3_transport_#{uniq}"
    start_supervised!({agent_mod, name: agent})
    start_supervised!({AshA2A.A2ATransport, name: transport})

    http =
      EphemeralHttp.start!(
        {AshA2A.A2ATransport.Plug, agent: agent, base_url: "http://x/a2a", transport: transport}
      )

    http.base_url
  end

  defp envelope(method, params),
    do: %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => method,
      "params" => params
    }

  defp message do
    {:ok, encoded} = AshA2A.Protocol.JSON.encode(AshA2A.Protocol.Message.new_user("go"))
    encoded
  end

  defp post(url, method, params, headers \\ []) do
    Req.post!(url,
      json: envelope(method, params),
      headers: headers,
      retry: false,
      receive_timeout: 10_000
    ).body
  end

  # Returns [{id | nil, result}] from raw SSE bytes.
  defp frames(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn frame ->
      lines = String.split(frame, "\n")

      for "data: " <> json <- lines do
        id =
          case Enum.find(lines, &String.starts_with?(&1, "id: ")) do
            "id: " <> v -> String.to_integer(String.trim(v))
            nil -> nil
          end

        {id, Jason.decode!(json)["result"]}
      end
    end)
  end

  test "message/stream answered with a bare Message yields exactly one message frame then closes" do
    url = boot(MessageAgent)
    body = post(url, "message/stream", %{"message" => message()})

    assert [{nil, %{"message" => %{"parts" => [%{"text" => "direct answer"}]}} = result}] =
             frames(body)

    assert map_size(result) == 1
  end

  test "final artifact chunk carries lastChunk true, earlier chunks do not, one shared artifactId" do
    url = boot(StreamAgent)
    body = post(url, "message/stream", %{"message" => message()})
    results = body |> frames() |> Enum.map(&elem(&1, 1))

    updates = for %{"artifactUpdate" => u} <- results, do: u
    assert length(updates) == 3
    assert updates |> Enum.map(& &1["artifact"]["artifactId"]) |> Enum.uniq() |> length() == 1

    {init, [last]} = Enum.split(updates, -1)
    assert Enum.all?(init, &(not Map.has_key?(&1, "lastChunk") or &1["lastChunk"] == false))
    assert last["lastChunk"] == true

    refute Enum.any?(results, fn
             %{"statusUpdate" => su} -> Map.has_key?(su, "final")
             _ -> false
           end)
  end

  test "resubscribe snapshot frame has no id line; Last-Event-ID replays only seq > N" do
    url = boot(StreamAgent)
    body = post(url, "message/stream", %{"message" => message()})
    [{_, %{"task" => %{"id" => task_id}}} | _] = frames(body)

    all = frames(post(url, "tasks/resubscribe", %{"id" => task_id}))
    assert [{nil, %{"task" => _}} | replayed] = all
    ids = Enum.map(replayed, &elem(&1, 0))
    assert Enum.all?(ids, &is_integer/1)
    assert ids == Enum.sort(ids)

    cut = Enum.at(ids, 1)

    after_cut =
      url
      |> post("tasks/resubscribe", %{"id" => task_id}, [{"last-event-id", Integer.to_string(cut)}])
      |> frames()
      |> tl()

    assert Enum.all?(after_cut, fn {id, _} -> id > cut end)
    assert length(after_cut) == length(Enum.filter(ids, &(&1 > cut)))

    non_int =
      url
      |> post("tasks/resubscribe", %{"id" => task_id}, [{"last-event-id", "garbage"}])
      |> frames()
      |> tl()

    assert Enum.map(non_int, &elem(&1, 0)) == ids
  end
end

# --- SOURCE: test/stream_generation_frames_test.exs ---
defmodule AshA2A.StreamGenerationFramesTest.StreamAgent do
  @moduledoc false
  use AshA2A.Protocol.Agent, name: "v4-stream", description: "streams three parts"

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context),
    do: {:stream, Stream.map(1..3, &AshA2A.Protocol.Part.Text.new("part #{&1}"))}
end

defmodule AshA2A.StreamGenerationFramesTest.ErrorFramePlug do
  @moduledoc false
  # Real Bandit handler: opens an SSE stream, writes a StreamError frame via
  # SSE.write_stream_error/3, then writes a further frame on the SAME stream.
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> send_chunked(200)

    conn =
      AshA2A.A2ATransport.SSE.write_stream_error(conn, 7, %AshA2A.Protocol.StreamError{
        task_id: "t-1",
        code: "INVALID_ARGUMENT",
        message: "bad request",
        reference_id: "m-1"
      })

    {:ok, conn} = chunk(conn, "data: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"task\":{}}}\n\n")
    conn
  end
end

defmodule AshA2A.StreamGenerationFramesTest do
  @moduledoc """
  V4 courts (real transport, real Bandit listeners, real subscriber
  processes; no mocks, no sleeps): generation on logged events, message-update
  gating by negotiated version, lastSeenGeneration resume and fallback,
  StreamError frames on a live stream, terminal-only closure.
  """

  use ExUnit.Case, async: true

  alias AshA2A.A2ATransport.TaskEvents
  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.StreamGenerationFramesTest.{ErrorFramePlug, StreamAgent}

  setup do
    uniq = System.unique_integer([:positive])
    transport = :"v4_transport_#{uniq}"
    agent = :"v4_agent_#{uniq}"
    start_supervised!({AshA2A.A2ATransport, name: transport})
    start_supervised!({StreamAgent, name: agent})
    %{transport: transport, agent: agent, tid: "v4-task-#{uniq}"}
  end

  defp su(tid),
    do: %{"statusUpdate" => %{"taskId" => tid, "status" => %{"state" => "TASK_STATE_WORKING"}}}

  defp au(tid), do: %{"artifactUpdate" => %{"taskId" => tid}}
  defp mu(tid), do: %{"messageUpdate" => %{"taskId" => tid, "message" => %{}}}

  defp subscriber(transport, tid, version) do
    parent = self()

    task =
      Task.async(fn ->
        TaskEvents.subscribe(transport, tid, version: version)
        send(parent, {:subscribed, self()})
        collect(tid, [])
      end)

    assert_receive {:subscribed, _pid}, 5_000
    task
  end

  defp collect(tid, acc) do
    receive do
      {:a2a_task_event, ^tid, _seq, kind, payload, final?} ->
        acc = [{kind, payload} | acc]
        if final?, do: Enum.reverse(acc), else: collect(tid, acc)
    after
      5_000 -> flunk("subscriber deadline: got #{inspect(Enum.reverse(acc))}")
    end
  end

  test "logged events carry strictly increasing, never-duplicated generations", ctx do
    t = ctx.transport
    TaskEvents.publish(t, ctx.tid, "task", %{"task" => %{"id" => ctx.tid, "generation" => 3}})
    TaskEvents.publish(t, ctx.tid, "status-update", su(ctx.tid))
    # explicit duplicate of the last generation is replaced, not repeated
    TaskEvents.publish(t, ctx.tid, "artifact-update", au(ctx.tid), false, generation: 4)
    TaskEvents.publish(t, ctx.tid, "status-update", su(ctx.tid), false, generation: 9)
    # stale explicit generation is replaced by last + 1
    TaskEvents.publish(t, ctx.tid, "status-update", su(ctx.tid), false, generation: 2)

    gens =
      for {_, kind, p, _} <- TaskEvents.backlog(t, ctx.tid), kind != "task" do
        TaskEvents.generation_of(p)
      end

    assert gens == [4, 5, 9, 10]
  end

  test "message-update reaches only >= 1.1 subscribers; legacy stream stays ordered", ctx do
    t = ctx.transport
    legacy = subscriber(t, ctx.tid, "1.0")
    modern = subscriber(t, ctx.tid, "1.1")

    TaskEvents.publish(t, ctx.tid, "status-update", su(ctx.tid))
    TaskEvents.publish(t, ctx.tid, "message-update", mu(ctx.tid))
    TaskEvents.publish(t, ctx.tid, "status-update", su(ctx.tid), true)

    legacy_events = Task.await(legacy, 5_000)
    modern_events = Task.await(modern, 5_000)

    assert Enum.map(legacy_events, &elem(&1, 0)) == ["status-update", "status-update"]

    assert Enum.map(modern_events, &elem(&1, 0)) == [
             "status-update",
             "message-update",
             "status-update"
           ]

    gens = Enum.map(modern_events, fn {_, p} -> TaskEvents.generation_of(p) end)
    assert gens == Enum.sort(Enum.uniq(gens))

    # A late legacy subscriber's backlog also hides the message-update.
    late = TaskEvents.subscribe(t, ctx.tid, version: "1.0")
    assert Enum.all?(late, fn {_, kind, _, _} -> kind != "message-update" end)
    full = TaskEvents.subscribe(t, ctx.tid, version: "1.1")
    assert Enum.any?(full, fn {_, kind, _, _} -> kind == "message-update" end)
  end

  test "replay_from_generation: resume window, caught-up, and not-retained", ctx do
    t = ctx.transport
    for _ <- 1..4, do: TaskEvents.publish(t, ctx.tid, "status-update", su(ctx.tid))
    log = TaskEvents.backlog(t, ctx.tid)

    assert {:ok, replay, _cursor} = TaskEvents.replay_from_generation(log, 2, 4)
    assert Enum.map(replay, fn {_, _, p, _} -> TaskEvents.generation_of(p) end) == [3, 4]
    assert {:ok, [], _} = TaskEvents.replay_from_generation(log, 4, 4)
    assert :unavailable = TaskEvents.replay_from_generation(log, 99, 4)
    # task is ahead of everything the log retains -> cannot replay
    assert :unavailable = TaskEvents.replay_from_generation(log, 1, 12)
  end

  # -- HTTP: lastSeenGeneration ------------------------------------------------

  defp boot(ctx) do
    EphemeralHttp.start!(
      {AshA2A.A2ATransport.Plug,
       agent: ctx.agent, base_url: "http://x/a2a", transport: ctx.transport}
    ).base_url
  end

  defp post(url, method, params) do
    Req.post!(url,
      json: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params},
      headers: [{"a2a-version", "1.1"}],
      retry: false,
      receive_timeout: 10_000
    ).body
  end

  defp frames(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn frame ->
      for "data: " <> json <- String.split(frame, "\n"), do: Jason.decode!(json)["result"]
    end)
  end

  defp gen(%{"statusUpdate" => %{"generation" => g}}), do: g
  defp gen(%{"artifactUpdate" => %{"generation" => g}}), do: g
  defp gen(_), do: nil

  defp opened(ctx) do
    url = boot(ctx)
    msg = AshA2A.Protocol.Message.new_user("go")
    {:ok, encoded} = AshA2A.Protocol.JSON.encode(msg)
    results = url |> post("message/stream", %{"message" => encoded}) |> frames()
    [%{"task" => %{"id" => task_id}} | _] = results
    {url, task_id, results}
  end

  test "lastSeenGeneration set: no Task snapshot, only newer events", ctx do
    {url, task_id, results} = opened(ctx)
    gens = for r <- results, g = gen(r), do: g
    assert length(gens) >= 2
    assert gens == Enum.sort(Enum.uniq(gens))

    [cut | _] = gens
    newer = Enum.filter(gens, &(&1 > cut))

    resumed =
      url
      |> post("tasks/resubscribe", %{"id" => task_id, "lastSeenGeneration" => cut})
      |> frames()

    refute Enum.any?(resumed, &Map.has_key?(&1, "task"))
    assert for(r <- resumed, g = gen(r), do: g) == newer
  end

  test "lastSeenGeneration not retained: opens with a Task snapshot instead of failing", ctx do
    {url, task_id, _} = opened(ctx)

    resumed =
      url
      |> post("tasks/resubscribe", %{"id" => task_id, "lastSeenGeneration" => 10_000})
      |> frames()

    assert [%{"task" => %{"id" => ^task_id}} | _] = resumed
  end

  test "lastSeenGeneration unset: snapshot first (unchanged behaviour)", ctx do
    {url, task_id, _} = opened(ctx)
    resumed = url |> post("tasks/resubscribe", %{"id" => task_id}) |> frames()
    assert [%{"task" => %{"id" => ^task_id}} | _] = resumed
  end

  # -- StreamError ---------------------------------------------------------------

  test "StreamError frame is written and the stream stays open for the next frame" do
    url = EphemeralHttp.start!({ErrorFramePlug, []}).base_url
    results = Req.get!(url, retry: false, receive_timeout: 5_000).body |> frames()

    assert [%{"error" => %{"code" => "INVALID_ARGUMENT"} = err}, %{"task" => %{}}] = results
    assert err["referenceId"] == "m-1" or err["reference_id"] == "m-1"
  end

  test "an unknown StreamResponse payload kind in the log is passed through, not fatal", ctx do
    t = ctx.transport
    sub = subscriber(t, ctx.tid, "1.1")
    TaskEvents.publish(t, ctx.tid, "future-kind", %{"futureThing" => %{"x" => 1}})
    TaskEvents.publish(t, ctx.tid, "status-update", su(ctx.tid), true)
    events = Task.await(sub, 5_000)
    assert Enum.map(events, &elem(&1, 0)) == ["future-kind", "status-update"]
  end

  # -- terminal-only closure -------------------------------------------------------

  test "an interrupted status is not final; only a terminal state closes the stream", ctx do
    t = ctx.transport

    interrupted = %{
      "statusUpdate" => %{
        "taskId" => ctx.tid,
        "status" => %{"state" => "TASK_STATE_INPUT_REQUIRED"}
      }
    }

    refute TaskEvents.terminal_payload?(interrupted)
    assert TaskEvents.closing_payload?(interrupted)

    sub = subscriber(t, ctx.tid, "1.1")
    TaskEvents.publish(t, ctx.tid, "status-update", interrupted, false)

    completed = %{
      "statusUpdate" => %{"taskId" => ctx.tid, "status" => %{"state" => "TASK_STATE_COMPLETED"}}
    }

    assert TaskEvents.terminal_payload?(completed)
    TaskEvents.publish(t, ctx.tid, "status-update", completed, true)

    # collect/2 only returns at the final flag: both events were seen on one stream.
    events = Task.await(sub, 5_000)
    states = Enum.map(events, fn {_, p} -> TaskEvents.payload_state(p) end)
    assert states == ["input_required", "completed"]
  end
end

