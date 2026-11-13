defmodule AshA2A.X2.GRPCV11GapsTest.Handler do
  @moduledoc false
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

defmodule AshA2A.X2.GRPCV11GapsTest do
  @moduledoc """
  X2 courts: v1.1 gaps on the gRPC binding over a real cowboy HTTP/2 listener
  and a real Mint gRPC client. Live-path downgrade for explicit <1.1 clients,
  `Downgrade.strip` of `message_update`, GetTask `timeline_length` and
  `current_generation` long-poll, `ifGenerationMatch` -> ABORTED(10), and
  SubscribeToTask `last_seen_generation` replay. No sleeps: bounded recv/await.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Transport.GRPC.Downgrade
  alias AshA2A.X2.GRPCV11GapsTest.Handler
  alias Lf.A2a.V1, as: Pb
  alias Lf.A2a.V1.A2AService.Stub

  @server AshA2A.Transport.GRPC.Server
  @v10 [metadata: %{"a2a-version" => "1.0"}]
  @v11 [metadata: %{"a2a-version" => "1.1"}]

  defmodule OpenAgent do
    use AshA2A.Protocol.Agent,
      name: "x2-open",
      description: "streaming, keeps tasks open",
      capabilities: %{streaming: true}

    @impl AshA2A.Protocol.Agent
    def handle_message(_message, _ctx),
      do: {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
  end

  setup do
    start_supervised!({OpenAgent, []})

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

    {:ok, transport: transport}
  end

  defp connect(transport, name) do
    sup =
      start_supervised!(
        {AshA2A.Transport.GRPC.Supervisor,
         port: 0,
         handler: Handler,
         ctx: %{agent: OpenAgent, opts: %{}, transport: transport, principal: :anonymous},
         name: name}
      )

    port = AshA2A.Transport.GRPC.Supervisor.port(sup)
    {:ok, ch} = GRPC.Stub.connect("localhost:#{port}", adapter: GRPC.Client.Adapters.Mint)
    ch
  end

  defp message(text, extra \\ []) do
    struct(
      %Pb.Message{
        message_id: AshA2A.Protocol.ID.generate("x2"),
        role: :ROLE_USER,
        parts: [%Pb.Part{content: {:text, text}}]
      },
      extra
    )
  end

  defp send_pb(ch, text, extra \\ [], opts \\ @v11) do
    req = %Pb.SendMessageRequest{message: message(text, extra)}
    Stub.send_message(ch, req, opts)
  end

  defp new_task(ch) do
    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{} = task}}} =
             send_pb(ch, "ask")

    task
  end

  defp push(stream, payload),
    do: GRPC.Stub.send_request(stream, %Pb.StreamRequest{payload: payload})

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

  # -- live-path downgrade ---------------------------------------------------

  test "SendLiveMessage with an explicit 1.0 client carries no v1.1 fields", %{transport: t} do
    ch = connect(t, __MODULE__.LiveSup)
    task = new_task(ch)
    assert task.generation > 0

    stream =
      ch
      |> Stub.send_live_message(@v10 ++ [timeout: 15_000])
      |> push({:subscribe, %Pb.SubscribeToTaskRequest{id: task.id}})

    assert {:ok, replies} = GRPC.Stub.recv(stream, timeout: 10_000)

    assert {:task, %Pb.Task{} = snap} = next(replies)
    assert snap.generation == 0
    assert snap.timeline == []

    _stream =
      push(
        stream,
        {:send_message, %Pb.SendMessageRequest{message: message("more", task_id: task.id)}}
      )

    {kind, value} = next(replies)
    refute kind == :message_update

    case {kind, value} do
      {:task, t} -> assert t.generation == 0 and t.timeline == []
      {:status_update, e} -> assert e.generation == 0
      {:artifact_update, e} -> assert e.generation == 0
      _ -> :ok
    end
  end

  test "Downgrade.strip drops a message_update StreamResponse for <1.1, keeps it for 1.1/nil" do
    frame = %Pb.StreamResponse{payload: {:message_update, %Pb.TaskMessageUpdateEvent{}}}

    assert Downgrade.strip(frame, "1.0") == :drop
    assert Downgrade.strip(frame, "0.3") == :drop
    assert Downgrade.strip(frame, "1.1") == frame
    assert Downgrade.strip(frame, nil) == frame
  end

  # -- GetTask options -------------------------------------------------------

  test "GetTask timeline_length truncates the timeline over gRPC", %{transport: t} do
    ch = connect(t, __MODULE__.TimelineSup)
    task = new_task(ch)
    assert {:ok, _} = send_pb(ch, "two", task_id: task.id)

    assert {:ok, %Pb.Task{timeline: full}} =
             Stub.get_task(ch, %Pb.GetTaskRequest{id: task.id}, @v11)

    assert full != []

    assert {:ok, %Pb.Task{timeline: cut}} =
             Stub.get_task(ch, %Pb.GetTaskRequest{id: task.id, timeline_length: 1}, @v11)

    assert length(cut) == 1
    assert length(full) >= length(cut)
  end

  test "GetTask current_generation long-polls until the generation advances", %{transport: t} do
    ch = connect(t, __MODULE__.PollSup)
    task = new_task(ch)
    gen = task.generation

    poll =
      Task.async(fn ->
        Stub.get_task(
          ch,
          %Pb.GetTaskRequest{id: task.id, current_generation: gen},
          @v11 ++ [timeout: 15_000]
        )
      end)

    assert {:ok, _} = send_pb(ch, "again", task_id: task.id)

    assert {:ok, %Pb.Task{generation: new_gen}} = Task.await(poll, 12_000)
    assert new_gen > gen
  end

  test "ifGenerationMatch mismatch -> ABORTED(10) TASK_GENERATION_MISMATCH", %{transport: t} do
    ch = connect(t, __MODULE__.MismatchSup)
    task = new_task(ch)

    req = %Pb.SendMessageRequest{
      message: message("more", task_id: task.id),
      configuration: %Pb.SendMessageConfiguration{if_generation_match: 987_654}
    }

    assert {:error, %GRPC.RPCError{status: 10} = error} = Stub.send_message(ch, req, @v11)
    assert "TASK_GENERATION_MISMATCH" in rpc_error_reasons(error)
  end

  # -- SubscribeToTask replay ------------------------------------------------

  test "SubscribeToTask last_seen_generation replays events without a snapshot", %{transport: t} do
    ch = connect(t, __MODULE__.ReplaySup)
    task = new_task(ch)

    req = %Pb.SubscribeToTaskRequest{id: task.id, last_seen_generation: task.generation}
    sub = Task.async(fn -> Stub.subscribe_to_task(ch, req, @v11 ++ [timeout: 10_000]) end)

    # the stream opens lazily on its first frame: produce one
    assert {:ok, _} = send_pb(ch, "next", task_id: task.id)

    assert {:ok, replies} = Task.await(sub, 12_000)
    {kind, _value} = next(replies)
    refute kind == :task, "expected an event after last_seen_generation, got a snapshot"
  end
end
