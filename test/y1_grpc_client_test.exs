defmodule AshA2A.Y1.GRPCClientTest.Handler do
  @moduledoc false
  # A real in-process handler (no mocks): the agent GenServer is the real
  # agent, push configs live in a real Agent process.
  @behaviour AshA2A.Protocol.JSONRPC

  alias AshA2A.Protocol.JSONRPC.Error
  alias AshA2A.Transport.Runtime

  @store AshA2A.Y1.GRPCClientTest.PushStore

  @impl true
  def handle_send(message, _params, %{agent: agent}) do
    opts = [task_id: message.task_id, context_id: message.context_id]

    case AshA2A.Protocol.call(agent, message, opts) do
      {:ok, _} = ok -> ok
      {:error, :not_found} -> {:error, Error.task_not_found()}
      {:error, _} -> {:error, Error.internal_error()}
    end
  end

  @impl true
  def handle_get(id, _params, %{agent: agent}) do
    case GenServer.call(agent, {:get_task, id}) do
      {:ok, _} = ok -> ok
      {:error, :not_found} -> {:error, Error.task_not_found()}
    end
  end

  @impl true
  def handle_cancel(id, _params, %{agent: agent}) do
    case GenServer.call(agent, {:get_task, id}) do
      {:ok, _} -> {:error, Error.task_not_cancelable()}
      {:error, :not_found} -> {:error, Error.task_not_found()}
    end
  end

  @impl true
  def handle_list(params, ctx) do
    case GenServer.call(ctx.agent, {:ash_a2a_list_tasks, ctx.principal, params}) do
      {:ok, %{tasks: tasks} = result} -> {:ok, %{result | tasks: Enum.map(tasks, &Runtime.wire_task/1)}}
      {:error, _} -> {:error, Error.internal_error()}
    end
  end

  @impl true
  def handle_set_push_config(config, _params, _ctx) do
    stored = %{config | id: config.id || AshA2A.Protocol.ID.generate("pc")}
    Agent.update(@store, &Map.put(&1, {stored.task_id, stored.id}, stored))
    {:ok, stored}
  end

  @impl true
  def handle_get_push_config(task_id, config_id, _params, _ctx) do
    case Agent.get(@store, &Map.get(&1, {task_id, config_id})) do
      nil -> {:error, Error.task_not_found()}
      config -> {:ok, config}
    end
  end

  @impl true
  def handle_list_push_configs(task_id, _params, _ctx) do
    {:ok, Agent.get(@store, fn m -> for {{^task_id, _}, config} <- m, do: config end)}
  end

  @impl true
  def handle_delete_push_config(task_id, config_id, _params, _ctx) do
    Agent.update(@store, &Map.delete(&1, {task_id, config_id}))
    :ok
  end

  def handle_extended_card(_ctx) do
    {:ok,
     %{
       "name" => "y1-extended",
       "description" => "extended card over gRPC",
       "version" => "1.0.0",
       "supportedInterfaces" => [
         %{"url" => "localhost:1", "protocolBinding" => "GRPC", "protocolVersion" => "1.1"}
       ],
       "capabilities" => %{},
       "defaultInputModes" => ["text/plain"],
       "defaultOutputModes" => ["text/plain"],
       "skills" => [%{"id" => "s1", "name" => "skill", "description" => "d", "tags" => ["t"]}]
     }}
  end
end

defmodule AshA2A.Y1.GRPCClientTest do
  @moduledoc """
  Y1 courts: the gRPC client binding against a real cowboy HTTP/2 listener
  (`AshA2A.Transport.GRPC.Supervisor`) and a real Mint gRPC channel. No mocks:
  the handler drives the real agent GenServer and a real Agent-backed push store.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Protocol.Client
  alias AshA2A.Protocol.Client.GRPC, as: GrpcClient
  alias AshA2A.Y1.GRPCClientTest.Handler

  @server AshA2A.Transport.GRPC.Server
  @store AshA2A.Y1.GRPCClientTest.PushStore

  defmodule OpenAgent do
    use AshA2A.Protocol.Agent,
      name: "y1-open",
      description: "streaming, keeps tasks open",
      capabilities: %{streaming: true}

    @impl AshA2A.Protocol.Agent
    def handle_message(%{parts: [%AshA2A.Protocol.Part.Text{text: "stream me"} | _]}, _ctx),
      do: {:stream, Stream.map(1..3, &AshA2A.Protocol.Part.Text.new("chunk #{&1}"))}

    def handle_message(_message, _ctx), do: {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
  end

  setup do
    start_supervised!({OpenAgent, []})
    start_supervised!(%{id: @store, start: {Agent, :start_link, [fn -> %{} end, [name: @store]]}})

    unless Process.whereis(AshA2A.Transport.Live.Registry),
      do: start_supervised!(AshA2A.Transport.Live.Supervisor)

    transport = Module.concat(__MODULE__, Transport)
    start_supervised!({AshA2A.A2ATransport, name: transport})

    previous = Application.get_env(:ash_a2a, :long_poll_timeout_ms)
    Application.put_env(:ash_a2a, :long_poll_timeout_ms, 10_000)

    on_exit(fn ->
      Application.delete_env(:ash_a2a, @server)

      if previous,
        do: Application.put_env(:ash_a2a, :long_poll_timeout_ms, previous),
        else: Application.delete_env(:ash_a2a, :long_poll_timeout_ms)
    end)

    sup =
      start_supervised!(
        {AshA2A.Transport.GRPC.Supervisor,
         port: 0,
         handler: Handler,
         ctx: %{agent: OpenAgent, opts: %{}, transport: transport, principal: :anonymous},
         name: Module.concat(__MODULE__, Sup)}
      )

    port = AshA2A.Transport.GRPC.Supervisor.port(sup)
    {:ok, client} = GrpcClient.connect(Client.new("localhost:#{port}", transport: :grpc))
    on_exit(fn -> GrpcClient.disconnect(client) end)

    {:ok, client: client, port: port}
  end

  defp new_task(client) do
    assert {:ok, %AshA2A.Protocol.Task{} = task} = Client.send_message(client, "ask")
    task
  end

  defp next(events) do
    case Enum.take(events, 1) do
      [event] -> event
      other -> flunk("expected one event, got #{inspect(other)}")
    end
  end

  # -- unary -------------------------------------------------------------------

  test "send_message returns a Task over gRPC", %{client: client} do
    task = new_task(client)
    assert is_binary(task.id)
    assert task.status.state == :input_required
  end

  test "get_task round trips and an unknown id is :task_not_found", %{client: client} do
    task = new_task(client)
    assert {:ok, %AshA2A.Protocol.Task{id: id}} = Client.get_task(client, task.id)
    assert id == task.id
    assert {:error, :task_not_found} = Client.get_task(client, "y1-missing")
  end

  test "get_task timeline_length truncates", %{client: client} do
    task = new_task(client)
    assert {:ok, _} = Client.send_message(client, "two", task_id: task.id)

    assert {:ok, %{timeline: full}} = Client.get_task(client, task.id)
    assert full != []
    assert {:ok, %{timeline: cut}} = Client.get_task(client, task.id, timeline_length: 1)
    assert length(cut) == 1
  end

  test "current_generation long-polls until the generation advances", %{client: client} do
    task = new_task(client)

    poll =
      Task.async(fn ->
        Client.get_task(client, task.id, current_generation: task.generation, timeout: 15_000)
      end)

    assert {:ok, _} = Client.send_message(client, "again", task_id: task.id)
    assert {:ok, %AshA2A.Protocol.Task{generation: gen}} = Task.await(poll, 12_000)
    assert gen > task.generation
  end

  test "A2A-Version metadata: an explicit 1.0 client gets no v1.1 timeline", %{client: client, port: port} do
    task = new_task(client)
    assert {:ok, %{timeline: [_ | _]}} = Client.get_task(client, task.id)

    v10 = Client.new("localhost:#{port}", transport: :grpc, version: "1.0", channel: client.channel)
    assert {:ok, %{timeline: []}} = Client.get_task(v10, task.id)
  end

  test "if_generation_match mismatch -> {:task_generation_mismatch, details}", %{client: client} do
    task = new_task(client)

    assert {:error, {:task_generation_mismatch, %{metadata: metadata, message: message}}} =
             Client.send_message(client, "more", task_id: task.id, if_generation_match: 987_654)

    assert is_map(metadata)
    assert is_binary(message)
  end

  test "cancel_task maps typed refusals", %{client: client} do
    task = new_task(client)
    assert {:error, :task_not_cancelable} = Client.cancel_task(client, task.id)
    assert {:error, :task_not_found} = Client.cancel_task(client, "y1-missing")
  end

  test "list_tasks answers the page envelope", %{client: client} do
    _task = new_task(client)

    # The fixture caller is anonymous and anonymous callers never enumerate
    # tasks (owner gate), so the envelope is well-formed and empty.
    assert {:ok, %{tasks: tasks} = page} = Client.list_tasks(client)
    assert tasks == []
    assert is_map(page)
  end

  test "push config CRUD over the four RPCs", %{client: client} do
    task = new_task(client)

    config = %AshA2A.Protocol.PushNotificationConfig{task_id: task.id, url: "https://example.com/hook", token: "t0"}

    assert {:ok, %AshA2A.Protocol.PushNotificationConfig{id: id, url: "https://example.com/hook"}} =
             Client.set_push_config(client, config)

    assert is_binary(id)

    assert {:ok, %{id: ^id, token: "t0"}} = Client.get_push_config(client, task.id, id)
    assert {:ok, [%{id: ^id}]} = Client.list_push_configs(client, task.id)
    assert :ok = Client.delete_push_config(client, task.id, id)
    assert {:ok, []} = Client.list_push_configs(client, task.id)
    assert {:error, :task_not_found} = Client.get_push_config(client, task.id, id)
  end

  test "get_extended_card decodes the extended card", %{client: client} do
    assert {:ok, %AshA2A.Protocol.AgentCard{name: "y1-extended"}} = Client.get_extended_card(client)
  end

  # -- channel handling ------------------------------------------------------------

  test "a client without a channel connects per call", %{port: port} do
    lazy = Client.new("localhost:#{port}", transport: :grpc)
    assert lazy.channel == nil
    assert {:ok, %AshA2A.Protocol.Task{}} = Client.send_message(lazy, "no channel")
  end

  test "connect/disconnect manage the stored channel", %{port: port} do
    assert {:ok, %Client{channel: channel} = connected} =
             GrpcClient.connect(Client.new("localhost:#{port}", transport: :grpc))

    assert channel != nil
    assert %Client{channel: nil} = GrpcClient.disconnect(connected)
  end

  test "a refused connection is a typed error" do
    dead = Client.new("localhost:1", transport: :grpc)
    assert {:error, {:grpc_connect_failed, _}} = Client.send_message(dead, "hi")
  end

  test "from_card selects GRPC only when preferred_bindings names it", %{port: port} do
    card =
      struct(AshA2A.Protocol.AgentCard,
        name: "y1",
        description: "d",
        url: "http://unused",
        supported_interfaces: [
          %{url: "localhost:#{port}", protocol_binding: "GRPC", protocol_version: "1.1"}
        ]
      )

    assert {:error, :no_supported_interface} = Client.from_card(card)
    assert {:ok, %Client{transport: :grpc, version: "1.1"} = client} = Client.from_card(card, preferred_bindings: [:grpc])
    assert {:ok, %AshA2A.Protocol.Task{}} = Client.send_message(client, "via card")
  end

  # -- streaming ----------------------------------------------------------------------

  test "stream_message yields decoded events", %{client: client} do
    assert {:ok, stream} = Client.stream_message(client, "stream me")

    assert %mod{} = next(stream)

    assert mod in [
             AshA2A.Protocol.Task,
             AshA2A.Protocol.Event.StatusUpdate,
             AshA2A.Protocol.Event.ArtifactUpdate,
             AshA2A.Protocol.Message
           ]
  end

  test "resubscribe with last_seen_generation replays events without a snapshot", %{client: client} do
    task = new_task(client)

    sub =
      Task.async(fn ->
        case Client.resubscribe(client, task.id, last_seen_generation: task.generation, timeout: 10_000) do
          {:ok, stream} -> {:ok, Enum.take(stream, 1)}
          other -> other
        end
      end)

    # the stream opens lazily on its first frame: produce one
    assert {:ok, _} = Client.send_message(client, "next", task_id: task.id)

    assert {:ok, [event]} = Task.await(sub, 12_000)
    refute match?(%AshA2A.Protocol.Task{}, event), "expected an event, got a snapshot"
  end

  # -- live (bidirectional) -------------------------------------------------------------

  test "live session: subscribe, uplink message, close", %{client: client} do
    task = new_task(client)

    assert {:ok, %{events: events, session: session}} =
             GrpcClient.open_live(client, %{"subscribe" => %{"id" => task.id}}, timeout: 15_000)

    assert %AshA2A.Protocol.Task{id: id} = next(events)
    assert id == task.id

    assert :ok = GrpcClient.live_send(session, "more", [])
    assert next(events) != nil

    assert :ok = GrpcClient.live_close(session)
  end

  test "live uplink rejection surfaces as a stream_error event", %{client: client} do
    task = new_task(client)

    assert {:ok, %{events: events, session: session}} =
             GrpcClient.open_live(client, %{"subscribe" => %{"id" => task.id}}, timeout: 15_000)

    assert %AshA2A.Protocol.Task{} = next(events)
    assert :ok = GrpcClient.live_send(session, "more", if_generation_match: 987_654)
    assert {:stream_error, %AshA2A.Protocol.StreamError{}} = next(events)

    assert :ok = GrpcClient.live_close(session)
  end

  test "open_live refuses non-gRPC clients" do
    assert {:error, {:transport_unsupported, :grpc_live}} =
             GrpcClient.open_live(Client.new("http://localhost:1", transport: :http_json), %{})
  end

  # -- error mapping ----------------------------------------------------------------------

  test "map_error maps status codes without ErrorInfo" do
    assert :task_not_found = GrpcClient.map_error(%GRPC.RPCError{status: 5, message: "x"})
    assert {:unauthorized, []} = GrpcClient.map_error(%GRPC.RPCError{status: 16, message: "x"})
    assert {:forbidden, "no"} = GrpcClient.map_error(%GRPC.RPCError{status: 7, message: "no"})
    assert {:grpc_error, 13, "boom"} = GrpcClient.map_error(%GRPC.RPCError{status: 13, message: "boom"})
    assert :passthrough = GrpcClient.map_error(:passthrough)
  end

  test "map_error maps ErrorInfo reasons incl. generation mismatch" do
    info = fn reason, metadata ->
      %Google.Protobuf.Any{
        type_url: "type.googleapis.com/google.rpc.ErrorInfo",
        value:
          Google.Rpc.ErrorInfo.encode(%Google.Rpc.ErrorInfo{
            reason: reason,
            domain: "a2a-protocol.org",
            metadata: metadata
          })
      }
    end

    assert :task_not_cancelable =
             GrpcClient.map_error(%GRPC.RPCError{status: 9, message: "m", details: [info.("TASK_NOT_CANCELABLE", %{})]})

    assert {:task_generation_mismatch, %{metadata: %{"actualGeneration" => "3"}, message: "m"}} =
             GrpcClient.map_error(%GRPC.RPCError{
               status: 10,
               message: "m",
               details: [info.("TASK_GENERATION_MISMATCH", %{"actualGeneration" => "3"})]
             })

    assert {:grpc_error, 9, "m"} =
             GrpcClient.map_error(%GRPC.RPCError{status: 9, message: "m", details: [info.("SOMETHING_NEW", %{})]})
  end
end
