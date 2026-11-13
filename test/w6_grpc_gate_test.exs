defmodule AshA2A.W6.GRPCGateTest.Ext do
  @moduledoc false
  @behaviour AshA2A.Protocol.Extension
  @uri "https://example.com/ext/w6-required"

  def uri, do: @uri

  @impl true
  def declaration(_state),
    do: %AshA2A.Protocol.AgentExtension{uri: @uri, description: "w6", required: true}

  @impl true
  def activate(_requested, _ctx, _state), do: {:ok, :active}
end

defmodule AshA2A.W6.GRPCGateTest.Handler do
  @moduledoc false
  @behaviour AshA2A.Protocol.JSONRPC

  alias AshA2A.Test.Fixture.EchoAgent

  @impl true
  def handle_send(message, _params, %{agent: agent}), do: AshA2A.Protocol.call(agent, message)

  @impl true
  def handle_get(task_id, _params, %{agent: agent}) do
    case EchoAgent.get_task(agent, task_id) do
      {:ok, task} -> {:ok, task}
      {:error, :not_found} -> {:error, %AshA2A.Protocol.JSONRPC.Error{code: -32001, message: "nf"}}
    end
  end

  @impl true
  def handle_cancel(_task_id, _params, _ctx),
    do: {:error, %AshA2A.Protocol.JSONRPC.Error{code: -32001, message: "nf"}}

  @impl true
  def handle_list(params, %{test_pid: pid}) do
    send(pid, {:list_params, params})
    {:ok, %{tasks: [], total_size: 0, page_size: 0, next_page_token: ""}}
  end
end

defmodule AshA2A.W6.GRPCGateTest do
  @moduledoc """
  W6 courts over a real cowboy HTTP/2 listener on an ephemeral port and a real
  Mint gRPC client: A2A-Version gate on all 11 RPCs, A2A-Extensions gate
  (-32008 -> FAILED_PRECONDITION, activated-extension response metadata),
  configurable supported versions, PERMISSION_DENIED(7) mapping, ListTasks
  status/history passthrough, and the supervised listener loopback.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Test.Fixture.EchoAgent
  alias AshA2A.W6.GRPCGateTest.{Ext, Handler}
  alias Lf.A2a.V1, as: Pb
  alias Lf.A2a.V1.A2AService.Stub

  @server AshA2A.Transport.GRPC.Server
  @endpoint AshA2A.Transport.GRPC.Server.Endpoint

  defmodule Forbidder do
    @moduledoc false
    # Real interceptor: identity "bob" is authenticated but not permitted.
    def authenticate(mat, _opts) do
      case GRPC.Stream.get_headers(mat) do
        %{"x-user" => "bob"} -> {:error, :forbidden}
        _ -> :ok
      end
    end
  end

  setup do
    {_sup, _registry} = AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [EchoAgent])
    transport = Module.concat(__MODULE__, Transport)
    start_supervised!({AshA2A.A2ATransport, name: transport})

    on_exit(fn ->
      Application.delete_env(:ash_a2a, @server)
      Application.delete_env(:ash_a2a, @endpoint)
    end)

    {:ok, transport: transport}
  end

  defp put_server(transport, extra \\ []) do
    Application.put_env(
      :ash_a2a,
      @server,
      Keyword.merge(
        [handler: Handler, ctx: %{agent: EchoAgent, opts: [], transport: transport, test_pid: self()}],
        extra
      )
    )
  end

  defp start_listener do
    {:ok, _pid, port} = GRPC.Server.start_endpoint(@endpoint, 0)

    on_exit(fn ->
      try do
        GRPC.Server.stop_endpoint(@endpoint)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, channel} = GRPC.Stub.connect("localhost:#{port}", adapter: GRPC.Client.Adapters.Mint)
    channel
  end

  defp message_request do
    %Pb.SendMessageRequest{
      message: %Pb.Message{
        message_id: AshA2A.Protocol.ID.generate("w6"),
        role: :ROLE_USER,
        parts: [%Pb.Part{content: {:text, "hi"}}]
      }
    }
  end

  # Streaming stubs may surface the refusal either as the call result or as
  # the first element of the response stream.
  defp first_error({:error, %GRPC.RPCError{} = e}), do: e

  defp first_error({:ok, stream}) do
    case Enum.take(stream, 1) do
      [{:error, %GRPC.RPCError{} = e}] -> e
      other -> flunk("expected an RPC error, got #{inspect(other)}")
    end
  end

  defp first_error(other), do: flunk("expected an RPC error, got #{inspect(other)}")

  @bad_version [metadata: %{"a2a-version" => "99.0"}]

  test "all 11 RPCs refuse an unsupported a2a-version with UNIMPLEMENTED(12)", %{transport: t} do
    put_server(t)
    ch = start_listener()

    calls = [
      {"SendMessage", fn -> Stub.send_message(ch, message_request(), @bad_version) end},
      {"SendStreamingMessage", fn -> Stub.send_streaming_message(ch, message_request(), @bad_version) end},
      {"GetTask", fn -> Stub.get_task(ch, %Pb.GetTaskRequest{id: "x"}, @bad_version) end},
      {"CancelTask", fn -> Stub.cancel_task(ch, %Pb.CancelTaskRequest{id: "x"}, @bad_version) end},
      {"ListTasks", fn -> Stub.list_tasks(ch, %Pb.ListTasksRequest{}, @bad_version) end},
      {"SubscribeToTask", fn -> Stub.subscribe_to_task(ch, %Pb.SubscribeToTaskRequest{id: "x"}, @bad_version) end},
      {"CreateTaskPushNotificationConfig",
       fn -> Stub.create_task_push_notification_config(ch, %Pb.TaskPushNotificationConfig{}, @bad_version) end},
      {"GetTaskPushNotificationConfig",
       fn ->
         Stub.get_task_push_notification_config(ch, %Pb.GetTaskPushNotificationConfigRequest{}, @bad_version)
       end},
      {"ListTaskPushNotificationConfigs",
       fn ->
         Stub.list_task_push_notification_configs(ch, %Pb.ListTaskPushNotificationConfigsRequest{}, @bad_version)
       end},
      {"DeleteTaskPushNotificationConfig",
       fn ->
         Stub.delete_task_push_notification_config(ch, %Pb.DeleteTaskPushNotificationConfigRequest{}, @bad_version)
       end},
      {"GetExtendedAgentCard", fn -> Stub.get_extended_agent_card(ch, %Pb.GetExtendedAgentCardRequest{}, @bad_version) end}
    ]

    assert length(calls) == 11

    for {name, call} <- calls do
      error = first_error(call.())
      assert error.status == 12, "#{name}: expected UNIMPLEMENTED(12), got #{inspect(error)}"
    end
  end

  test "SendLiveMessage (v1.1 bidi) refuses an unsupported a2a-version with UNIMPLEMENTED(12)", %{transport: t} do
    put_server(t)
    ch = start_listener()

    stream = Stub.send_live_message(ch, @bad_version)
    stream = GRPC.Stub.send_request(stream, %Pb.StreamRequest{}, end_stream: true)

    error =
      case GRPC.Stub.recv(stream, timeout: 5_000) do
        {:error, %GRPC.RPCError{} = e} ->
          e

        {:ok, replies} ->
          case Enum.take(replies, 1) do
            [{:error, %GRPC.RPCError{} = e}] -> e
            other -> flunk("expected an RPC error, got #{inspect(other)}")
          end
      end

    assert error.status == 12
  end

  test "required extension missing -> FAILED_PRECONDITION(9); present -> ok + echoed metadata", %{transport: t} do
    put_server(t, extensions: [Ext])
    ch = start_listener()

    assert {:error, %GRPC.RPCError{status: 9, message: msg}} =
             Stub.send_message(ch, message_request())

    assert msg =~ Ext.uri()

    assert {:ok, %Pb.SendMessageResponse{}, %{headers: headers}} =
             Stub.send_message(ch, message_request(),
               metadata: %{"a2a-extensions" => Ext.uri()},
               return_headers: true
             )

    assert headers["a2a-extensions"] == Ext.uri()

    # Streaming and unary alike are gated.
    assert %GRPC.RPCError{status: 9} = first_error(Stub.send_streaming_message(ch, message_request()))
  end

  test "supported versions are configurable", %{transport: t} do
    put_server(t, versions: ["1.0"])
    ch = start_listener()

    # Absent header = "0.3" default, which this server no longer supports.
    assert {:error, %GRPC.RPCError{status: 12}} = Stub.send_message(ch, message_request())

    assert {:ok, %Pb.SendMessageResponse{}} =
             Stub.send_message(ch, message_request(), metadata: %{"a2a-version" => "1.0"})
  end

  test "forbidden interceptor outcome maps to PERMISSION_DENIED(7); unauthenticated stays 16", %{transport: t} do
    put_server(t)
    Application.put_env(:ash_a2a, @endpoint, auth: {Forbidder, nil})
    ch = start_listener()

    assert {:error, %GRPC.RPCError{status: 7}} =
             Stub.send_message(ch, message_request(), metadata: %{"x-user" => "bob"})

    assert {:ok, %Pb.SendMessageResponse{}} =
             Stub.send_message(ch, message_request(), metadata: %{"x-user" => "alice"})

    assert AshA2A.Transport.GRPC.Auth.forbidden().status == 7
  end

  test "ListTasks: UNSPECIFIED status is no filter; history_length passes through", %{transport: t} do
    put_server(t)
    ch = start_listener()

    assert {:ok, %Pb.ListTasksResponse{}} =
             Stub.list_tasks(ch, %Pb.ListTasksRequest{history_length: 2, page_size: 5})

    assert_receive {:list_params, params}, 5_000
    refute Map.has_key?(params, "status")
    assert params["historyLength"] == 2
    assert params["pageSize"] == 5
  end

  test "supervised listener boots on an ephemeral port and answers a loopback call", %{transport: t} do
    spec =
      {AshA2A.Transport.GRPC.Supervisor,
       port: 0,
       handler: Handler,
       ctx: %{agent: EchoAgent, opts: [], transport: t, test_pid: self()},
       name: AshA2A.W6.GRPCGateTest.GrpcListener}

    sup = start_supervised!(spec)

    port = AshA2A.Transport.GRPC.Supervisor.port(sup)
    assert is_integer(port) and port > 0

    {:ok, ch} = GRPC.Stub.connect("localhost:#{port}", adapter: GRPC.Client.Adapters.Mint)

    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{id: id}}}} =
             Stub.send_message(ch, message_request())

    assert id != ""
  end
end
