defmodule AshA2A.Transport.GRPCServerTestHandler do
  @moduledoc """
  Real `AshA2A.Protocol.JSONRPC` behaviour implementation wired to a real,
  supervised `AshA2A.Test.Fixture.EchoAgent` — the same agent fixture the
  HTTP-binding tests drive. No mocks.
  """

  @behaviour AshA2A.Protocol.JSONRPC

  alias AshA2A.Protocol.JSONRPC.Error
  alias AshA2A.Test.Fixture.EchoAgent

  @impl AshA2A.Protocol.JSONRPC
  def handle_send(message, _params, %{agent: agent}) do
    AshA2A.Protocol.call(agent, message)
  end

  @impl AshA2A.Protocol.JSONRPC
  def handle_get(task_id, _params, %{agent: agent}) do
    case EchoAgent.get_task(agent, task_id) do
      {:ok, task} -> {:ok, task}
      {:error, :not_found} -> {:error, Error.task_not_found(task_id)}
    end
  end

  @impl AshA2A.Protocol.JSONRPC
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
end

defmodule AshA2A.Transport.GRPCServerTest.MessageOnlyAgent do
  @moduledoc """
  Real `AshA2A.Protocol.Agent` whose only skill answers with a bare
  `{:message, parts}` reply — so `AshA2A.Protocol.stream/3` returns
  `{:ok, %AshA2A.Protocol.Message{}}` (no task, no stream). That is a real
  reason term `start_message_stream/1`'s else-branch receives (the branch
  whose redacted reason is interpolated into the refusal message); a plain
  task-backed agent streams fine over gRPC, so it cannot drive this branch.
  No mocks: the agent is a real supervised process.
  """

  use AshA2A.Protocol.Agent,
    name: "grpc_message_only",
    description: "Answers every message with a bare Message reply (no task, no stream)",
    skills: [
      %{
        id: "ack",
        name: "ack",
        description: "Acknowledges the message without creating a task"
      }
    ]

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context) do
    {:message, [AshA2A.Protocol.Part.Text.new("acknowledged, no task")]}
  end
end

defmodule AshA2A.Transport.GRPCServerTest do
  @moduledoc """
  REAL gRPC-over-the-wire tests for `AshA2A.Transport.GRPC.Server`: a real
  cowboy HTTP/2 listener on a loopback port, driven by a real gRPC client
  (Mint adapter) through the generated `Lf.A2a.V1.A2AService.Stub`.

  SendMessage creates a real task in a real agent, GetTask reads it back,
  an unknown task surfaces as a real `grpc-status: 5` NOT_FOUND trailer, and
  `SendStreamingMessage` delivers the task snapshot plus live events until
  the final status update. Zero mocks: every collaborator is real.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Test.Fixture.EchoAgent
  alias Lf.A2a.V1, as: Pb

  @endpoint AshA2A.Transport.GRPC.Server.Endpoint

  setup do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        EchoAgent,
        AshA2A.Test.Fixture.StreamingWidgetAgent
      ])

    # Real rows for the streaming agent's real read stream (same seeding the
    # SSE streaming test uses; the ETS data layer is process-shared).
    Ash.Seed.seed!(AshA2A.Test.Fixture.StreamingWidget, %{label: "grpc-alpha"})
    Ash.Seed.seed!(AshA2A.Test.Fixture.StreamingWidget, %{label: "grpc-bravo"})

    transport = Module.concat(__MODULE__, Transport)
    start_supervised!({AshA2A.A2ATransport, name: transport})

    Application.put_env(:ash_a2a, AshA2A.Transport.GRPC.Server,
      handler: AshA2A.Transport.GRPCServerTestHandler,
      ctx: %{agent: EchoAgent, opts: [], transport: transport}
    )

    on_exit(fn -> Application.delete_env(:ash_a2a, AshA2A.Transport.GRPC.Server) end)

    {:ok, _client_sup} =
      DynamicSupervisor.start_link(
        strategy: :one_for_one,
        name: Module.concat(__MODULE__, ClientSup)
      )

    {:ok, _endpoint_pid, port} = GRPC.Server.start_endpoint(@endpoint, 0)
    on_exit(fn ->
      try do
        GRPC.Server.stop_endpoint(@endpoint)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, channel} =
      GRPC.Stub.connect("localhost:#{port}", adapter: GRPC.Client.Adapters.Mint)

    {:ok, %{channel: channel}}
  end

  defp transport_name, do: Module.concat(__MODULE__, Transport)

  # A server-streaming stub call may surface the server's refusal either at
  # call time ({:error, %GRPC.RPCError{}}) or lazily when the returned stream
  # is enumerated, depending on when the trailers arrive — handle both.
  defp rpc_error_from_stream({:error, %GRPC.RPCError{} = error}), do: error

  defp rpc_error_from_stream({:ok, stream}) do
    try do
      _ = Enum.to_list(stream)
      flunk("expected the server-streaming call to fail")
    rescue
      e in GRPC.RPCError -> e
    end
  end

  defp data_request do
    value = Protobuf.JSON.decode!(~s({"stream": true}), Google.Protobuf.Value)

    %Pb.SendMessageRequest{
      message: %Pb.Message{
        message_id: AshA2A.Protocol.ID.generate("grpc"),
        role: :ROLE_USER,
        parts: [%Pb.Part{content: {:data, value}}]
      }
    }
  end

  defp user_message_request(text) do
    %Pb.SendMessageRequest{
      message: %Pb.Message{
        message_id: AshA2A.Protocol.ID.generate("grpc"),
        role: :ROLE_USER,
        parts: [%Pb.Part{content: {:text, text}}]
      }
    }
  end

  defp send_and_get_task_id(channel, text) do
    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{} = task}}} =
             Lf.A2a.V1.A2AService.Stub.send_message(channel, user_message_request(text))

    assert task.status.state == :TASK_STATE_COMPLETED
    assert is_binary(task.id) and task.id != ""
    task.id
  end

  test "SendMessage creates a real task over the wire", %{channel: channel} do
    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{} = task}}} =
             Lf.A2a.V1.A2AService.Stub.send_message(channel, user_message_request("hello grpc"))

    assert task.status.state == :TASK_STATE_COMPLETED
    assert task.id != ""
    assert task.context_id != ""

    assert Enum.any?(task.history, fn
             %Pb.Message{parts: [%Pb.Part{content: {:text, "hello grpc"}}]} -> true
             _ -> false
           end)
  end

  test "GetTask reads the created task back over the wire", %{channel: channel} do
    task_id = send_and_get_task_id(channel, "echo round trip")

    assert {:ok, %Pb.Task{} = got} =
             Lf.A2a.V1.A2AService.Stub.get_task(channel, %Pb.GetTaskRequest{id: task_id})

    assert got.id == task_id
    assert got.status.state == :TASK_STATE_COMPLETED

    assert Enum.any?(got.history, fn
             %Pb.Message{parts: [%Pb.Part{content: {:text, "echo round trip"}}]} -> true
             _ -> false
           end)
  end

  test "GetTask with an unknown id surfaces a real grpc-status NOT_FOUND trailer", %{
    channel: channel
  } do
    assert {:error, %GRPC.RPCError{} = error} =
             Lf.A2a.V1.A2AService.Stub.get_task(
               channel,
               %Pb.GetTaskRequest{id: "no-such-task"}
             )

    assert error.status == 5
    assert error.message == "Task not found"

    # GRPC-ERR-001 (spec §10.6): an A2A error carries its google.rpc.ErrorInfo
    # (reason TASK_NOT_FOUND, domain a2a-protocol.org) in the
    # grpc-status-details-bin trailer.
    assert [%Google.Protobuf.Any{type_url: "type.googleapis.com/google.rpc.ErrorInfo"} = any] =
             error.details

    assert %Google.Rpc.ErrorInfo{reason: "TASK_NOT_FOUND", domain: "a2a-protocol.org"} =
             Google.Rpc.ErrorInfo.decode(any.value)
  end

  test "SendStreamingMessage streams the snapshot and events until the final status", %{
    channel: channel
  } do
    # The streaming RPC drives the real streaming-capable agent fixture (the
    # Echo agent is not streamable); point the transport's ctx at it for this
    # test and restore after.
    Application.put_env(:ash_a2a, AshA2A.Transport.GRPC.Server,
      handler: AshA2A.Transport.GRPCServerTestHandler,
      ctx: %{
        agent: AshA2A.Test.Fixture.StreamingWidgetAgent,
        opts: [],
        transport: transport_name()
      }
    )

    on_exit(fn ->
      Application.delete_env(:ash_a2a, AshA2A.Transport.GRPC.Server)
    end)

    assert {:ok, stream} =
             channel |> Lf.A2a.V1.A2AService.Stub.send_streaming_message(data_request())

    replies =
      stream
      |> Enum.map(fn {:ok, %Pb.StreamResponse{} = resp} -> resp end)
      |> Enum.to_list()

    assert [%Pb.StreamResponse{payload: {:task, %Pb.Task{}}} = _snapshot | events] = replies

    kinds =
      Enum.map(events, fn
        %Pb.StreamResponse{payload: {:artifact_update, _}} -> :artifact
        %Pb.StreamResponse{payload: {:status_update, _}} -> :status
        %Pb.StreamResponse{payload: {:task, _}} -> :task
        %Pb.StreamResponse{payload: {:message, _}} -> :message
      end)

    assert kinds != []
    assert [last_event | _] = Enum.reverse(events)
    assert match?(%Pb.StreamResponse{payload: {:status_update, %{status: %{state: :TASK_STATE_COMPLETED}}}}, last_event)
  end

  # -- G-E pinned gRPC TCK-failure closures (lane G-Q) -----------------------

  test "SubscribeToTask of a terminal task is UNIMPLEMENTED(12), not FAILED_PRECONDITION(9)", %{
    channel: channel
  } do
    task_id = send_and_get_task_id(channel, "terminal resubscribe")

    error =
      rpc_error_from_stream(
        Lf.A2a.V1.A2AService.Stub.subscribe_to_task(channel, %Pb.SubscribeToTaskRequest{
          id: task_id
        })
      )

    assert error.status == 12

    # The TCK's ERROR_BINDINGS bind the terminal-resubscribe refusal class
    # (UnsupportedOperationError, -32004) to UNIMPLEMENTED with reason
    # UNSUPPORTED_OPERATION; FAILED_PRECONDITION(9) is TaskNotCancelable's
    # (-32002) status, not this one.
    assert error.message == "This operation is not supported"

    assert [%Google.Protobuf.Any{type_url: "type.googleapis.com/google.rpc.ErrorInfo"} = any] =
             error.details

    assert %Google.Rpc.ErrorInfo{reason: "UNSUPPORTED_OPERATION", domain: "a2a-protocol.org"} =
             Google.Rpc.ErrorInfo.decode(any.value)
  end

  test "SendStreamingMessage to a non-streamable agent is FAILED_PRECONDITION(9) with a string message", %{
    channel: channel
  } do
    # The refusal may surface at call time or at enumeration time (the client
    # stream is lazy), so enumerate under rescue. The MessageOnlyAgent drives
    # the same else-branch `{:not_streaming, %Task{}}` lands in: any non-
    # `{:ok, task, enum}` reply is refused here.
    agent_name = :"grpc_message_only_#{System.unique_integer([:positive])}"
    start_supervised!({AshA2A.Transport.GRPCServerTest.MessageOnlyAgent, name: agent_name})

    Application.put_env(:ash_a2a, AshA2A.Transport.GRPC.Server,
      handler: AshA2A.Transport.GRPCServerTestHandler,
      ctx: %{agent: agent_name, opts: [], transport: transport_name()}
    )

    error =
      rpc_error_from_stream(
        Lf.A2a.V1.A2AService.Stub.send_streaming_message(
          channel,
          user_message_request("no stream please")
        )
      )

    assert error.status == 9
    assert error.message =~ "Task is not streamable:"

    # A binary message: the redacted term was rendered with inspect/1 before
    # interpolation, so no crash-and-INTERNAL detour.
    assert is_binary(error.message)
  end

  test "unsupported A2A-Version metadata is refused UNIMPLEMENTED(12) with a VERSION_NOT_SUPPORTED ErrorInfo", %{
    channel: channel
  } do
    assert {:error, %GRPC.RPCError{status: 12} = error} =
             Lf.A2a.V1.A2AService.Stub.send_message(
               channel,
               user_message_request("bad version"),
               metadata: %{"a2a-version" => "99.0"}
             )

    assert error.message == "Version not supported"

    assert [%Google.Protobuf.Any{type_url: "type.googleapis.com/google.rpc.ErrorInfo"} = any] =
             error.details

    assert %Google.Rpc.ErrorInfo{reason: "VERSION_NOT_SUPPORTED", domain: "a2a-protocol.org"} =
             info = Google.Rpc.ErrorInfo.decode(any.value)

    assert info.metadata == %{"detail" => "99.0"}

    # Absent header: default tolerance (§3.6.2 — missing version means "0.3"),
    # the request processes normally.
    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{}}}} =
             Lf.A2a.V1.A2AService.Stub.send_message(channel, user_message_request("no version header"))
  end
end
