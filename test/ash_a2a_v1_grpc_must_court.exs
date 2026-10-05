# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.V1.GrpcMustCourt.ErrorProbeHandler do
  @moduledoc """
  Real `AshA2A.Protocol.JSONRPC` behaviour implementation wired to the real,
  supervised `AshA2A.Test.Fixture.EchoAgent` — the same shape the HTTP
  binding and `AshA2A.Transport.GRPCServerTestHandler` use. No mocks.

  For the error-band court it can be pointed at a real
  `AshA2A.Protocol.JSONRPC.Error` struct via :persistent_term
  (`AshA2A.V1.GrpcMustCourt.ErrorProbeHandler.error_key()`), so each A2A
  error code's §3.3.2 gRPC-status mapping and §5.4 google.rpc.ErrorInfo
  stamping is exercised through the REAL server path: cowboy HTTP/2 listener,
  gRPC framing, `AshA2A.Transport.Grpc.Dispatch`, `grpc-status-details-bin`
  trailer, Mint client decode. The handler returns the Error struct through
  the same `{:error, %Error{}}` edge the real EchoAgent handlers return
  through; nothing about the mapping layer is bypassed.
  """

  @behaviour AshA2A.Protocol.JSONRPC

  alias AshA2A.Protocol.JSONRPC.Error
  alias AshA2A.Test.Fixture.EchoAgent

  @error_key :ash_a2a_v1_grpc_must_court_error

  def error_key, do: @error_key

  def configure_error(%Error{} = error) do
    :persistent_term.put(@error_key, error)
  end

  def clear_error do
    :persistent_term.put(@error_key, nil)
  end

  @impl AshA2A.Protocol.JSONRPC
  def handle_send(message, _params, %{agent: agent}) do
    AshA2A.Protocol.call(agent, message)
  end

  @impl AshA2A.Protocol.JSONRPC
  def handle_get(task_id, _params, %{agent: agent}) do
    case :persistent_term.get(@error_key, nil) do
      %Error{} = error ->
        {:error, error}

      nil ->
        case EchoAgent.get_task(agent, task_id) do
          {:ok, task} -> {:ok, task}
          {:error, :not_found} -> {:error, Error.task_not_found(task_id)}
        end
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

defmodule AshA2A.V1.GrpcMustCourt do
  @moduledoc """
  Per-declared-transport MUST-level court for the A2A v1.0 gRPC binding
  (lane X15, TCK residue reduction: prior verdict recorded the gRPC residue
  as "echo-SUT only" class; this court witnesses every MUST on the declared
  `lf.a2a.v1.A2AService` surface over a REAL cowboy HTTP/2 socket with a
  real gRPC client (Mint) — zero mocks, no framing-level stand-ins needed).

  ## MUST matrix

    * SendMessage / GetTask (TaskGetter) / CancelTask unary MUSTs, real task
      lifecycle over the wire.
    * SendStreamingMessage / SubscribeToTask server-streaming MUSTs.
    * TaskState wire spellings: the full `lf.a2a.v1.TaskState` enum set
      round-trips the server's exact proto-JSON bridge (Jason.encode! →
      Protobuf.JSON.decode!) with canonical `TASK_STATE_*` spellings.
      **Stated boundary**: the enum round-trip drives the server's bridge
      functions directly (`Protobuf.JSON` + `Jason`, the two calls in
      `AshA2A.Transport.GRPC.Server.to_pb!/2`), not the socket, because the
      echo agent only ever reaches TASK_STATE_COMPLETED on the wire; the
      wire-visible COMPLETED spelling is witnessed separately in the socket
      courts below.
    * Cross-binding error court: every A2A error code -32001..-32009 plus
      -32602 maps to its §3.3.2 gRPC status and carries its §5.4
      google.rpc.ErrorInfo (reason, domain a2a-protocol.org) in the
      grpc-status-details-bin trailer — each witnessed over the real socket.
    * A2A-Version metadata gate: unsupported version refused UNIMPLEMENTED(12)
      with VERSION_NOT_SUPPORTED ErrorInfo; supported "1.0"/"0.3" and the
      absent-header "0.3" default (§3.6.2) all accepted.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Protocol.JSONRPC.Error
  alias AshA2A.Test.Fixture.{EchoAgent, StreamingWidgetAgent}
  alias AshA2A.V1.GrpcMustCourt.ErrorProbeHandler
  alias Lf.A2a.V1, as: Pb

  @endpoint AshA2A.Transport.GRPC.Server.Endpoint

  # §3.3.2 cross-binding error table × §5.4 ErrorInfo reasons
  # (@ AshA2A.Protocol.JSONRPC.Error.error_info_reasons). {jsonrpc_code,
  # error_constructor, expected_grpc_status, expected_error_info_reason}.
  @error_matrix [
    {-32_001, :task_not_found, 5, "TASK_NOT_FOUND"},
    {-32_002, :task_not_cancelable, 9, "TASK_NOT_CANCELABLE"},
    {-32_003, :push_notification_not_supported, 12, "PUSH_NOTIFICATION_NOT_SUPPORTED"},
    {-32_004, :unsupported_operation, 12, "UNSUPPORTED_OPERATION"},
    {-32_005, :content_type_not_supported, 3, "CONTENT_TYPE_NOT_SUPPORTED"},
    {-32_006, :invalid_agent_response, 13, "INVALID_AGENT_RESPONSE"},
    {-32_007, :authenticated_extended_card_not_configured, 9, "EXTENDED_AGENT_CARD_NOT_CONFIGURED"},
    {-32_008, :extension_support_required, 9, "EXTENSION_SUPPORT_REQUIRED"},
    {-32_009, :version_not_supported, 12, "VERSION_NOT_SUPPORTED"}
  ]

  setup do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        EchoAgent,
        StreamingWidgetAgent
      ])

    Ash.Seed.seed!(AshA2A.Test.Fixture.StreamingWidget, %{label: "x15-alpha"})
    Ash.Seed.seed!(AshA2A.Test.Fixture.StreamingWidget, %{label: "x15-bravo"})

    transport = Module.concat(__MODULE__, Transport)
    start_supervised!({AshA2A.A2ATransport, name: transport})

    Application.put_env(:ash_a2a, AshA2A.Transport.GRPC.Server,
      handler: ErrorProbeHandler,
      ctx: %{agent: EchoAgent, opts: [], transport: transport}
    )

    ErrorProbeHandler.clear_error()

    on_exit(fn ->
      Application.delete_env(:ash_a2a, AshA2A.Transport.GRPC.Server)
      :persistent_term.put(ErrorProbeHandler.error_key(), nil)
    end)

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

  # -- helpers ---------------------------------------------------------------

  defp transport_name, do: Module.concat(__MODULE__, Transport)

  defp rpc_error_from_stream({:error, %GRPC.RPCError{} = error}), do: error

  defp rpc_error_from_stream({:ok, stream}) do
    try do
      _ = Enum.to_list(stream)
      flunk("expected the server-streaming call to fail")
    rescue
      e in GRPC.RPCError -> e
    end
  end

  defp user_message_request(text) do
    %Pb.SendMessageRequest{
      message: %Pb.Message{
        message_id: AshA2A.Protocol.ID.generate("x15"),
        role: :ROLE_USER,
        parts: [%Pb.Part{content: {:text, text}}]
      }
    }
  end

  defp data_request do
    value = Protobuf.JSON.decode!(~s({"stream": true}), Google.Protobuf.Value)

    %Pb.SendMessageRequest{
      message: %Pb.Message{
        message_id: AshA2A.Protocol.ID.generate("x15"),
        role: :ROLE_USER,
        parts: [%Pb.Part{content: {:data, value}}]
      }
    }
  end

  defp send_and_get_task_id(channel, text) do
    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{} = task}}} =
             Lf.A2a.V1.A2AService.Stub.send_message(channel, user_message_request(text))

    assert task.status.state == :TASK_STATE_COMPLETED
    task.id
  end

  defp assert_error_info(error, expected_reason, expected_detail \\ nil) do
    assert [%Google.Protobuf.Any{type_url: "type.googleapis.com/google.rpc.ErrorInfo"} = any] =
             error.details

    info = Google.Rpc.ErrorInfo.decode(any.value)

    assert info.reason == expected_reason
    assert info.domain == "a2a-protocol.org"

    if expected_detail, do: assert(info.metadata == %{"detail" => expected_detail})

    info
  end

  # -- W1..W4: SendMessage / GetTask / CancelTask unary MUSTs over real socket -

  test "W1 SendMessage creates a real task; GetTask reads it back over the wire", %{
    channel: channel
  } do
    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{} = task}}} =
             Lf.A2a.V1.A2AService.Stub.send_message(channel, user_message_request("x15 hello"))

    assert task.id != ""
    assert task.context_id != ""
    assert task.status.state == :TASK_STATE_COMPLETED

    assert Enum.any?(task.history, fn
             %Pb.Message{parts: [%Pb.Part{content: {:text, "x15 hello"}}]} -> true
             _ -> false
           end)

    assert {:ok, %Pb.Task{} = got} =
             Lf.A2a.V1.A2AService.Stub.get_task(channel, %Pb.GetTaskRequest{id: task.id})

    assert got.id == task.id
    assert got.status.state == :TASK_STATE_COMPLETED
  end

  test "W2 GetTask with an unknown id refuses NOT_FOUND(5) with TASK_NOT_FOUND ErrorInfo over the wire", %{
    channel: channel
  } do
    assert {:error, %GRPC.RPCError{status: 5} = error} =
             Lf.A2a.V1.A2AService.Stub.get_task(
               channel,
               %Pb.GetTaskRequest{id: "tsk-x15-missing"}
             )

    assert error.message == "Task not found"
    assert_error_info(error, "TASK_NOT_FOUND", "tsk-x15-missing")
  end

  test "W3 CancelTask of a terminal task refuses FAILED_PRECONDITION(9) with TASK_NOT_CANCELABLE ErrorInfo over the wire", %{
    channel: channel
  } do
    task_id = send_and_get_task_id(channel, "x15 terminal cancel")

    assert {:error, %GRPC.RPCError{status: 9} = error} =
             Lf.A2a.V1.A2AService.Stub.cancel_task(channel, %Pb.CancelTaskRequest{id: task_id})

    assert error.message == "Task cannot be canceled"
    assert_error_info(error, "TASK_NOT_CANCELABLE")
  end

  test "W4 GetTask with missing id is a real -32602: INVALID_ARGUMENT(3) with INVALID_PARAMS ErrorInfo over the wire", %{
    channel: channel
  } do
    assert {:error, %GRPC.RPCError{status: 3} = error} =
             Lf.A2a.V1.A2AService.Stub.get_task(channel, %Pb.GetTaskRequest{})

    assert error.message == "Invalid parameters"
    assert_error_info(error, "INVALID_PARAMS")
  end

  # -- W5/W6: server-streaming MUSTs over real socket --------------------------

  test "W5 SendStreamingMessage streams snapshot plus events ending in a final TASK_STATE_COMPLETED status update", %{
    channel: channel
  } do
    Application.put_env(:ash_a2a, AshA2A.Transport.GRPC.Server,
      handler: ErrorProbeHandler,
      ctx: %{
        agent: StreamingWidgetAgent,
        opts: [],
        transport: transport_name()
      }
    )

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

    assert match?(
             %Pb.StreamResponse{payload: {:status_update, %{status: %{state: :TASK_STATE_COMPLETED}}}},
             last_event
           )
  end

  test "W6 SubscribeToTask of a terminal task refuses UNIMPLEMENTED(12) with UNSUPPORTED_OPERATION ErrorInfo over the wire", %{
    channel: channel
  } do
    task_id = send_and_get_task_id(channel, "x15 terminal resubscribe")

    error =
      rpc_error_from_stream(
        Lf.A2a.V1.A2AService.Stub.subscribe_to_task(channel, %Pb.SubscribeToTaskRequest{
          id: task_id
        })
      )

    assert error.status == 12
    assert error.message == "This operation is not supported"
    assert_error_info(error, "UNSUPPORTED_OPERATION")
  end

  # -- W7: A2A-Version metadata gate (spec §3.6.2 / -32009) --------------------

  test "W7 unsupported A2A-Version is refused UNIMPLEMENTED(12) with VERSION_NOT_SUPPORTED ErrorInfo on SendMessage and GetTask", %{
    channel: channel
  } do
    metadata = %{"a2a-version" => "99.0"}

    assert {:error, %GRPC.RPCError{status: 12} = send_error} =
             Lf.A2a.V1.A2AService.Stub.send_message(
               channel,
               user_message_request("x15 bad version"),
               metadata: metadata
             )

    assert send_error.message == "Version not supported"
    assert_error_info(send_error, "VERSION_NOT_SUPPORTED", "99.0")

    assert {:error, %GRPC.RPCError{status: 12} = get_error} =
             Lf.A2a.V1.A2AService.Stub.get_task(
               channel,
               %Pb.GetTaskRequest{id: "tsk-whatever"},
               metadata: metadata
             )

    assert get_error.message == "Version not supported"

    # The gate's ErrorInfo metadata.detail carries the REJECTED version, not
    # the request's parameters — same trailer on both RPCs.
    assert_error_info(get_error, "VERSION_NOT_SUPPORTED", "99.0")
  end

  test "W7 supported versions (1.0, 0.3) and the absent-header 0.3 default are all accepted", %{
    channel: channel
  } do
    for version <- ["1.0", "0.3"] do
      assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{}}}} =
               Lf.A2a.V1.A2AService.Stub.send_message(
                 channel,
                 user_message_request("x15 version #{version}"),
                 metadata: %{"a2a-version" => version}
               )
    end

    # Absent header processes normally (§3.6.2: missing version means "0.3").
    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{}}}} =
             Lf.A2a.V1.A2AService.Stub.send_message(
               channel,
               user_message_request("x15 no version header")
             )
  end

  # -- W8: full A2A error band over the real socket ----------------------------

  test "W8 every A2A error code -32001..-32009 maps to its §3.3.2 gRPC status with its §5.4 ErrorInfo over the wire", %{
    channel: channel
  } do
    for {code, constructor, expected_status, expected_reason} <- @error_matrix do
      ErrorProbeHandler.configure_error(apply(Error, constructor, ["x15-probe-#{code}"]))

      assert {:error, %GRPC.RPCError{status: ^expected_status} = error} =
               Lf.A2a.V1.A2AService.Stub.get_task(
                 channel,
                 %Pb.GetTaskRequest{id: "tsk-x15-probe"}
               ),
             "code #{code} (#{constructor}) must map to gRPC #{expected_status}"

      assert error.message != ""

      info = assert_error_info(error, expected_reason)

      assert info.metadata == %{"detail" => "x15-probe-#{code}"},
             "code #{code}: ErrorInfo metadata.detail must carry the A2A error's data"
    end
  end

  # -- bridge-level TaskState spelling court (stated boundary) -----------------

  test "W9 the full TaskState enum set round-trips the server's proto-JSON bridge with canonical TASK_STATE_* spellings" do
    states = [
      :TASK_STATE_UNSPECIFIED,
      :TASK_STATE_SUBMITTED,
      :TASK_STATE_WORKING,
      :TASK_STATE_COMPLETED,
      :TASK_STATE_FAILED,
      :TASK_STATE_CANCELED,
      :TASK_STATE_INPUT_REQUIRED,
      :TASK_STATE_REJECTED,
      :TASK_STATE_AUTH_REQUIRED
    ]

    for state <- states do
      pb_task = %Pb.Task{id: "tsk-x15", status: %Pb.TaskStatus{state: state}}

      # The exact bridge the server uses in to_pb!/2: Jason.encode! →
      # Protobuf.JSON.decode! (emission) and Protobuf.JSON.encode! →
      # Jason.decode! (ingestion, to_params/1).
      wire_json = Jason.encode!(%{status: %{state: Atom.to_string(state)}})
      decoded = wire_json |> Jason.decode!() |> Jason.encode!() |> Protobuf.JSON.decode!(Pb.Task)

      assert decoded.status.state == state

      # Emission: the pb proto-JSON spelling of each state is the canonical
      # TASK_STATE_* string — except the proto3 zero value, which proto3 JSON
      # omits by default (the server's ingest side still decodes it back to
      # the zero value). The internal codec's vocabulary agrees otherwise.
      emission = Protobuf.JSON.encode!(pb_task)

      if state == :TASK_STATE_UNSPECIFIED do
        # proto3 JSON default-omits the zero enum value on emission.
        refute emission =~ "TASK_STATE_"
        assert {:ok, :unknown} = AshA2A.Protocol.JSON.decode_state("TASK_STATE_UNSPECIFIED")
      else
        assert emission =~ ~s("state":"#{Atom.to_string(state)}")
        codec_state = emission |> Jason.decode!() |> get_in(["status", "state"])

        assert codec_state == Atom.to_string(state)
        assert {:ok, _} = AshA2A.Protocol.JSON.decode_state(codec_state)
      end
    end

    # The codec's emission vocabulary covers exactly the pb enum's real
    # states (its :unknown maps to TASK_STATE_UNSPECIFIED, the documented
    # Z16-F1 zero-value mapping).
    codec_states = AshA2A.Protocol.JSON.valid_state_strings()

    Enum.each(states -- [:TASK_STATE_UNSPECIFIED], fn state ->
      assert Atom.to_string(state) in codec_states
    end)
  end
end
