defmodule AshA2A.V10.GRPCLiveTest.Handler do
  @moduledoc false
  # Real JSON-RPC handler over the real agents below (same shape as the V6
  # generation court's handler).
  @behaviour AshA2A.Protocol.JSONRPC

  alias AshA2A.Protocol.JSONRPC.Error

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
  def handle_cancel(_id, _params, _ctx), do: {:error, Error.task_not_cancelable()}
end

defmodule AshA2A.V10.GRPCLiveTest do
  @moduledoc """
  V10 courts: the v1.1 gRPC binding over a real cowboy HTTP/2 listener on an
  ephemeral port and a real Mint gRPC client. `SendLiveMessage` (native
  duplex), `ifGenerationMatch` -> ABORTED(10), `artifactUpdates` capability
  gate, `lastSeenGeneration` fallback, `Task.generation` on the wire.
  """

  use ExUnit.Case, async: false

  alias AshA2A.V10.GRPCLiveTest.Handler
  alias Lf.A2a.V1, as: Pb
  alias Lf.A2a.V1.A2AService.Stub

  @server AshA2A.Transport.GRPC.Server
  @v11 [metadata: %{"a2a-version" => "1.1"}]

  defmodule LiveAgent do
    use AshA2A.Protocol.Agent,
      name: "v10-live",
      description: "streaming, no client artifacts",
      capabilities: %{streaming: true}

    @impl AshA2A.Protocol.Agent
    def handle_message(message, _ctx) do
      case AshA2A.Protocol.Message.text(message) do
        "ask" -> {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
        _ -> {:input_required, [AshA2A.Protocol.Part.Text.new("again?")]}
      end
    end
  end

  defmodule ArtAgent do
    use AshA2A.Protocol.Agent,
      name: "v10-art",
      description: "streaming + client artifacts",
      capabilities: %{streaming: true, user_artifacts: true}

    @impl AshA2A.Protocol.Agent
    def handle_message(_message, _ctx),
      do: {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
  end

  defmodule PlainAgent do
    use AshA2A.Protocol.Agent, name: "v10-plain", description: "no streaming"

    @impl AshA2A.Protocol.Agent
    def handle_message(_message, _ctx),
      do: {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
  end

  setup do
    start_supervised!({LiveAgent, []})
    start_supervised!({ArtAgent, []})
    start_supervised!({PlainAgent, []})

    unless Process.whereis(AshA2A.Transport.Live.Registry),
      do: start_supervised!(AshA2A.Transport.Live.Supervisor)

    transport = Module.concat(__MODULE__, Transport)
    start_supervised!({AshA2A.A2ATransport, name: transport})
    on_exit(fn -> Application.delete_env(:ash_a2a, @server) end)
    {:ok, transport: transport}
  end

  defp connect(agent, transport, name) do
    sup =
      start_supervised!(
        {AshA2A.Transport.GRPC.Supervisor,
         port: 0,
         handler: Handler,
         ctx: %{agent: agent, opts: %{}, transport: transport, principal: :anonymous},
         name: name}
      )

    port = AshA2A.Transport.GRPC.Supervisor.port(sup)
    {:ok, ch} = GRPC.Stub.connect("localhost:#{port}", adapter: GRPC.Client.Adapters.Mint)
    ch
  end

  defp message(text, extra \\ []) do
    struct(
      %Pb.Message{
        message_id: AshA2A.Protocol.ID.generate("v10"),
        role: :ROLE_USER,
        parts: [%Pb.Part{content: {:text, text}}]
      },
      extra
    )
  end

  defp new_task(ch) do
    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{} = task}}} =
             Stub.send_message(ch, %Pb.SendMessageRequest{message: message("ask")}, @v11)

    task
  end

  defp open_live(ch) do
    Stub.send_live_message(ch, @v11 ++ [timeout: 15_000])
  end

  defp push(stream, payload),
    do: GRPC.Stub.send_request(stream, %Pb.StreamRequest{payload: payload})

  defp subscribe(id, extra \\ []),
    do: {:subscribe, struct(%Pb.SubscribeToTaskRequest{id: id}, extra)}

  defp send_msg(text, extra \\ []) do
    {:send_message, %Pb.SendMessageRequest{message: message(text, extra)}}
  end

  # Next downlink frame, bounded by the recv deadline.
  defp next(replies) do
    case Enum.take(replies, 1) do
      [{:ok, %Pb.StreamResponse{payload: {kind, value}}}] -> {kind, value}
      other -> flunk("expected one StreamResponse, got #{inspect(other)}")
    end
  end

  defp rpc_error_reasons(%GRPC.RPCError{details: details}) do
    for %Google.Protobuf.Any{value: v} <- List.wrap(details),
        do: Google.Rpc.ErrorInfo.decode(v).reason
  end

  test "SendLiveMessage subscribe-first: first frame is a Task snapshot", %{transport: t} do
    ch = connect(LiveAgent, t, __MODULE__.SubSup)
    task = new_task(ch)

    stream = ch |> open_live() |> push(subscribe(task.id))
    assert {:ok, replies} = GRPC.Stub.recv(stream, timeout: 10_000)
    assert {:task, %Pb.Task{id: id}} = next(replies)
    assert id == task.id
  end

  test "SendLiveMessage: a follow-up message on the same stream is accepted", %{transport: t} do
    ch = connect(LiveAgent, t, __MODULE__.FollowSup)

    stream = ch |> open_live() |> push(send_msg("ask"))
    assert {:ok, replies} = GRPC.Stub.recv(stream, timeout: 10_000)
    assert {:task, %Pb.Task{id: id}} = next(replies)

    _stream = push(stream, send_msg("more", task_id: id))

    frame = next(replies)
    refute match?({:error, _}, frame), "follow-up was rejected: #{inspect(frame)}"
  end

  test "SendLiveMessage: wrong-task request yields StreamError and keeps the stream open", %{
    transport: t
  } do
    ch = connect(LiveAgent, t, __MODULE__.WrongSup)

    stream = ch |> open_live() |> push(send_msg("ask"))
    assert {:ok, replies} = GRPC.Stub.recv(stream, timeout: 10_000)
    assert {:task, %Pb.Task{id: id}} = next(replies)

    stream = push(stream, send_msg("x", task_id: "some-other-task"))
    assert {:error, %Pb.StreamError{code: code}} = next(replies)
    assert code == "INVALID_ARGUMENT"

    # Late subscribe is also a non-fatal StreamError.
    stream = push(stream, subscribe(id))
    assert {:error, %Pb.StreamError{code: "FAILED_PRECONDITION"}} = next(replies)

    # The stream is still usable.
    _stream = push(stream, send_msg("more", task_id: id))
    frame = next(replies)
    refute match?({:error, _}, frame)
  end

  test "SendLiveMessage on a non-streaming agent -> UNIMPLEMENTED(12) UNSUPPORTED_OPERATION", %{
    transport: t
  } do
    ch = connect(PlainAgent, t, __MODULE__.PlainSup)

    stream = ch |> open_live() |> push(send_msg("ask"))

    error =
      case GRPC.Stub.recv(stream, timeout: 10_000) do
        {:error, %GRPC.RPCError{} = e} ->
          e

        {:ok, replies} ->
          assert [{:error, %GRPC.RPCError{} = e}] = Enum.take(replies, 1)
          e
      end

    assert error.status == 12
    assert "UNSUPPORTED_OPERATION" in rpc_error_reasons(error)
  end

  test "ifGenerationMatch mismatch -> ABORTED(10) TASK_GENERATION_MISMATCH", %{transport: t} do
    ch = connect(LiveAgent, t, __MODULE__.GenSup)
    task = new_task(ch)

    req = %Pb.SendMessageRequest{
      message: message("more", task_id: task.id),
      configuration: %Pb.SendMessageConfiguration{if_generation_match: 987_654}
    }

    assert {:error, %GRPC.RPCError{status: 10} = error} = Stub.send_message(ch, req, @v11)
    assert "TASK_GENERATION_MISMATCH" in rpc_error_reasons(error)
  end

  test "artifactUpdates are refused with UNSUPPORTED_OPERATION(12) when the capability is off", %{
    transport: t
  } do
    ch = connect(LiveAgent, t, __MODULE__.ArtOffSup)
    task = new_task(ch)

    req = %Pb.SendMessageRequest{
      message: message("more", task_id: task.id),
      artifact_updates: [
        %Pb.TaskArtifactUpdateEvent{
          task_id: task.id,
          artifact: %Pb.Artifact{artifact_id: "a1", parts: [%Pb.Part{content: {:text, "x"}}]}
        }
      ]
    }

    assert {:error, %GRPC.RPCError{status: 12} = error} = Stub.send_message(ch, req, @v11)
    assert "UNSUPPORTED_OPERATION" in rpc_error_reasons(error)
  end

  test "artifactUpdates are accepted when user_artifacts is declared", %{transport: t} do
    ch = connect(ArtAgent, t, __MODULE__.ArtOnSup)
    task = new_task(ch)

    req = %Pb.SendMessageRequest{
      message: message("more", task_id: task.id),
      artifact_updates: [
        %Pb.TaskArtifactUpdateEvent{
          task_id: task.id,
          artifact: %Pb.Artifact{artifact_id: "a1", parts: [%Pb.Part{content: {:text, "x"}}]}
        }
      ]
    }

    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{id: id}}}} =
             Stub.send_message(ch, req, @v11)

    assert id == task.id
  end

  test "Task.generation survives the proto bridge", %{transport: t} do
    ch = connect(LiveAgent, t, __MODULE__.TaskGenSup)
    task = new_task(ch)
    assert task.generation > 0

    assert {:ok, %Pb.Task{generation: gen}} =
             Stub.get_task(ch, %Pb.GetTaskRequest{id: task.id}, @v11)

    assert gen == task.generation
  end

  test "SubscribeToTask lastSeenGeneration falls back to a snapshot when replay is unavailable",
       %{transport: t} do
    ch = connect(LiveAgent, t, __MODULE__.LastSeenSup)
    task = new_task(ch)

    req = %Pb.SubscribeToTaskRequest{id: task.id, last_seen_generation: 0}
    assert {:ok, replies} = Stub.subscribe_to_task(ch, req, @v11 ++ [timeout: 10_000])
    assert [{:ok, %Pb.StreamResponse{payload: {:task, %Pb.Task{id: id}}}}] = Enum.take(replies, 1)
    assert id == task.id
  end
end
