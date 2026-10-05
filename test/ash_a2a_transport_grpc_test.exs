defmodule AshA2A.GrpcLane.Probe do
  @moduledoc false

  use Ash.Resource,
    domain: AshA2A.GrpcLane.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  actions do
    action :whoami, :map do
      run(fn _input, _context ->
        {:ok, %{"subject" => nil}}
      end)
    end
  end

  a2a do
    skill(:whoami, :whoami, consequence: :observe)
  end
end

defmodule AshA2A.GrpcLane.Domain do
  @moduledoc false

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.GrpcLane.Probe)
  end
end

defmodule AshA2A.GrpcLane.Agent do
  @moduledoc false

  use AshA2A.Agent,
    resource_or_domain: AshA2A.GrpcLane.Probe,
    name: "grpc_lane_agent",
    public_skills: [:whoami]
end

defmodule AshA2A.TransportGrpcTest do
  use ExUnit.Case, async: false

  alias AshA2A.Transport.Grpc.{Dispatch, Framing}

  # The SAME handler the HTTP binding uses, driven Plug-free: a bare
  # handler/ctx pair, no socket, no server.
  setup do
    name = :"grpc_lane_agent_#{System.unique_integer([:positive])}"
    agent = start_supervised!({AshA2A.GrpcLane.Agent, name: name}, id: name)

    opts = AshA2A.Transport.Plug.init(agent: name, base_url: "http://127.0.0.1/a2a")
    ctx = %{agent: name, opts: opts, conn: %Plug.Conn{}, principal: :anonymous}

    %{agent: agent, name: name, ctx: ctx, handler: AshA2A.Transport.Plug}
  end

  defp wire_message do
    msg = %{
      AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{})])
      | metadata: %{"skill" => "whoami"}
    }

    {:ok, json} = AshA2A.Protocol.JSON.encode(msg)
    json
  end

  defp send_message(ctx, handler) do
    assert {:ok, %{"task" => %{"id" => task_id} = task}} =
             Dispatch.call("SendMessage", %{"message" => wire_message()}, handler, ctx)

    assert "tsk-" <> _ = task_id
    assert %{"status" => %{"state" => "TASK_STATE_COMPLETED"}} = task
    task_id
  end

  # -- Framing ----------------------------------------------------------------

  describe "Framing length-prefixed codec" do
    test "round-trips a payload through the 5-byte header" do
      frame = Framing.encode_frame("hello")

      assert <<0::size(8), 5::unsigned-big-integer-size(32), "hello">> = frame
      assert {:ok, ["hello"], ""} = Framing.decode_frames(frame)
    end

    test "splits and reassembles multi-frame buffers" do
      bytes =
        ["a", "bb", "ccc"]
        |> Enum.map(&Framing.encode_frame/1)
        |> IO.iodata_to_binary()

      assert {:ok, ["a", "bb", "ccc"], ""} = Framing.decode_frames(bytes)
    end

    test "buffers a partial frame until its bytes arrive" do
      frame = Framing.encode_frame("hello")
      <<prefix::binary-size(3), tail::binary>> = frame

      assert {:ok, [], ^prefix} = Framing.decode_frames(prefix)
      assert {:ok, ["hello"], ""} = Framing.decode_frames(prefix <> tail)
    end

    test "returns early frames alongside an incomplete tail" do
      bytes = Framing.encode_frame("a") <> Framing.encode_frame("bcd")
      <<head::binary-size(7), rest::binary>> = bytes

      assert {:ok, ["a"], buffered} = Framing.decode_frames(head)
      assert byte_size(buffered) < 5

      # The host resumes the stream: buffered tail + the next chunk received.
      # Frame "a" was already delivered by the first decode call.
      assert {:ok, ["bcd"], ""} = Framing.decode_frames(buffered <> rest)
    end

    test "refuses oversized declared lengths" do
      frame = Framing.encode_frame(String.duplicate("x", 10))

      assert {:error, {:frame_too_large, 10}} =
               Framing.decode_frames(frame, max_frame_bytes: 5)
    end

    test "refuses compressed frames without a negotiated decompressor" do
      frame = Framing.encode_frame("hello", compressed: true)
      assert {:error, :compression_unsupported} = Framing.decode_frames(frame)
    end

    test "decompresses compressed frames when the host supplies the encoding" do
      payload = :zlib.compress("hello")
      frame = <<1::size(8), byte_size(payload)::unsigned-big-integer-size(32), payload::binary>>

      assert {:ok, ["hello"], ""} = Framing.decode_frames(frame, decompress: &:zlib.uncompress/1)
    end

    test "refuses an unknown compressed flag" do
      frame = <<2::size(8), 0::unsigned-big-integer-size(32)>>
      assert {:error, :bad_compressed_flag} = Framing.decode_frames(frame)
    end

    test "trailer maps round-trip with grpc-status as integer" do
      trailers = %{"grpc-status" => 5, "grpc-message" => "Task not found"}
      encoded = Framing.encode_trailers(trailers) |> IO.iodata_to_binary()

      assert encoded =~ "grpc-status: 5\r\n"
      assert encoded =~ "grpc-message: Task not found\r\n"
      assert {:ok, ^trailers} = Framing.parse_trailers(encoded)
    end

    test "non-integer grpc-status is a typed refusal" do
      assert {:error, {:bad_grpc_status, "five"}} = Framing.parse_trailers("grpc-status: five\r\n")
    end
  end

  # -- Dispatch ---------------------------------------------------------------

  describe "Dispatch method table" do
    test "exposes the a2a.A2AService method table" do
      names = Enum.map(Dispatch.methods(), & &1.name)

      assert names == [
               "SendMessage",
               "SendStreamingMessage",
               "GetTask",
               "CancelTask",
               "ListTasks",
               "SubscribeToTask",
               "CreateTaskPushNotificationConfig",
               "GetTaskPushNotificationConfig",
               "ListTaskPushNotificationConfigs",
               "DeleteTaskPushNotificationConfig",
               "GetExtendedAgentCard"
             ]

      assert Dispatch.service() == "a2a.A2AService"
      assert Enum.all?(Dispatch.methods(), &is_binary(&1.internal))
    end
  end

  describe "Dispatch over a real agent, Plug-free" do
    test "SendMessage creates a real task; GetTask reads it back", %{ctx: ctx, handler: handler} do
      task_id = send_message(ctx, handler)

      assert {:ok, %{"id" => ^task_id}} =
               Dispatch.call("GetTask", %{"id" => task_id}, handler, ctx)
    end

    test "a real -32001 maps to NOT_FOUND(5)", %{ctx: ctx, handler: handler} do
      assert {:error, 5, "Task not found"} =
               Dispatch.call("GetTask", %{"id" => "tsk-does-not-exist"}, handler, ctx)
    end

    test "CancelTask of a terminal task maps -32002 to FAILED_PRECONDITION(9)", %{ctx: ctx, handler: handler} do
      task_id = send_message(ctx, handler)

      assert {:error, 9, "Task cannot be canceled"} =
               Dispatch.call("CancelTask", %{"id" => task_id}, handler, ctx)
    end

    test "missing params map to INVALID_ARGUMENT(3)", %{ctx: ctx, handler: handler} do
      assert {:error, 3, "Invalid parameters"} =
               Dispatch.call("GetTask", %{}, handler, ctx)
    end

    test "an unknown RPC name maps to UNIMPLEMENTED(12)", %{handler: handler} do
      assert {:error, 12, message} = Dispatch.call("a2a.A2AService/Nope", %{}, handler, %{})
      assert message =~ "Nope"
    end

    test "push config CRUD without handler callbacks maps -32003 to UNIMPLEMENTED(12)", %{ctx: ctx, handler: handler} do
      task_id = send_message(ctx, handler)

      assert {:error, 12, "Push Notification is not supported"} =
               Dispatch.call("CreateTaskPushNotificationConfig", %{
                 "taskId" => task_id,
                 "pushNotificationConfig" => %{"url" => "https://example.com/hook"}
               }, handler, ctx)
    end

    test "GetExtendedAgentCard maps -32004 to UNIMPLEMENTED(12)", %{ctx: ctx, handler: handler} do
      assert {:error, 12, "This operation is not supported"} =
               Dispatch.call("GetExtendedAgentCard", %{}, handler, ctx)
    end

    test "SendStreamingMessage returns the stream intent, message already validated", %{ctx: ctx, handler: handler} do
      assert {:stream, "message/stream", params, id} =
               Dispatch.call("SendStreamingMessage", %{"message" => wire_message()}, handler, ctx)

      assert %AshA2A.Protocol.Message{} = params["message"]
      assert is_binary(id)
    end

    test "ListTasks is served owner-scoped: anonymous lists nothing", %{ctx: ctx, handler: handler} do
      task_id = send_message(ctx, handler)

      assert {:ok, %{"tasks" => tasks, "totalSize" => 0}} =
               Dispatch.call("ListTasks", %{}, handler, ctx)

      refute Enum.any?(tasks, &(&1["id"] == task_id))
    end

    test "trailers/1 and status_name/1 cover the mapped statuses" do
      assert %{"grpc-status" => 0} = Dispatch.trailers({:ok, %{}})
      assert %{"grpc-status" => 5, "grpc-message" => "Task not found"} =
               Dispatch.trailers({:error, 5, "Task not found"})

      assert Dispatch.status_name(3) == "INVALID_ARGUMENT"
      assert Dispatch.status_name(5) == "NOT_FOUND"
      assert Dispatch.status_name(9) == "FAILED_PRECONDITION"
      assert Dispatch.status_name(12) == "UNIMPLEMENTED"
      assert Dispatch.status_name(13) == "INTERNAL"
    end
  end
end
