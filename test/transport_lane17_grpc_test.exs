# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.TransportLane17.GRPCFramingTest do
  @moduledoc "Lane 17 framing courts: pure codec, real zlib, no collaborators to fake."
  use ExUnit.Case, async: true

  alias AshA2A.Transport.Grpc.Framing

  test "a partial payload returns the whole frame as rest instead of an error" do
    frame = Framing.encode_frame("hello world")
    <<head::binary-size(8), tail::binary>> = frame

    assert {:ok, [], ^head} = Framing.decode_frames(head)
    assert {:ok, ["hello world"], ""} = Framing.decode_frames(head <> tail)

    two = frame <> Framing.encode_frame("second")
    cut = byte_size(two) - 2
    <<part::binary-size(cut), _::binary>> = two
    assert {:ok, ["hello world"], rest} = Framing.decode_frames(part)
    assert byte_size(rest) == cut - byte_size(frame)
  end

  test "decompressed output is bounded: a gzip bomb is refused, a small frame passes" do
    bomb = :zlib.gzip(:binary.copy(<<0>>, 2_000_000))
    frame = Framing.encode_frame(bomb, compressed: true)

    assert {:error, {:frame_too_large, _}} =
             Framing.decode_frames(frame,
               max_frame_bytes: 100_000,
               decompress: Framing.gzip_decompressor(100_000)
             )

    small = Framing.encode_frame(:zlib.gzip("tiny"), compressed: true)

    assert {:ok, ["tiny"], ""} =
             Framing.decode_frames(small, decompress: Framing.gzip_decompressor())
  end

  test "a naive decompress fun is still size-checked after the fact" do
    frame = Framing.encode_frame("x", compressed: true)

    assert {:error, {:frame_too_large, 1_000}} =
             Framing.decode_frames(frame,
               max_frame_bytes: 100,
               decompress: fn _ -> :binary.copy("a", 1_000) end
             )

    assert {:error, :decompress_failed} =
             Framing.decode_frames(frame, decompress: fn _ -> raise "boom" end)
  end
end

defmodule AshA2A.TransportLane17.GRPCServerTest do
  @moduledoc """
  Lane 17 gRPC courts over a real cowboy HTTP/2 listener and a real Mint gRPC
  client: the verified principal reaches dispatch (owner scoping over gRPC),
  the streaming RPC delivers the initial task snapshot, and a malformed auth
  env fails closed. No mocks.
  """

  use ExUnit.Case, async: false

  alias AshA2A.TransportLane17.StreamAgent
  alias Lf.A2a.V1, as: Pb

  @moduletag :serial_shard

  @endpoint AshA2A.Transport.GRPC.Server.Endpoint

  defmodule Handler do
    @moduledoc false
    @behaviour AshA2A.Protocol.JSONRPC

    @impl AshA2A.Protocol.JSONRPC
    def handle_send(message, _params, %{agent: agent}), do: AshA2A.Protocol.call(agent, message)

    @impl AshA2A.Protocol.JSONRPC
    def handle_get(task_id, _params, %{agent: agent} = ctx) do
      with {:ok, task} <- GenServer.call(agent, {:get_task, task_id}),
           true <- AshA2A.Transport.Runtime.owned_by?(task, Map.get(ctx, :principal, :anonymous)) do
        {:ok, task}
      else
        _ -> {:error, AshA2A.Protocol.JSONRPC.Error.task_not_found()}
      end
    end

    @impl AshA2A.Protocol.JSONRPC
    def handle_cancel(_task_id, _params, _ctx),
      do: {:error, AshA2A.Protocol.JSONRPC.Error.task_not_found()}

    def verify(_scheme, credential, _conn) do
      case String.split(credential, ":", parts: 2) do
        ["tok", sub] when sub != "" -> {:ok, %{sub: sub}}
        _ -> {:error, "invalid"}
      end
    end
  end

  setup do
    uniq = System.unique_integer([:positive])
    agent = :"lane17_grpc_agent_#{uniq}"
    transport = :"lane17_grpc_transport_#{uniq}"
    start_supervised!({StreamAgent, name: agent})
    start_supervised!({AshA2A.A2ATransport, name: transport})

    Application.put_env(:ash_a2a, AshA2A.Transport.GRPC.Server,
      handler: Handler,
      ctx: %{
        agent: agent,
        opts: %{authorize_task: nil},
        transport: transport,
        stream_idle_ms: 2_000
      }
    )

    auth_opts =
      AshA2A.Protocol.Plug.Auth.init(
        schemes: %{"bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}},
        verify: &Handler.verify/3
      )

    Application.put_env(:ash_a2a, @endpoint, auth: {AshA2A.Transport.GRPC.Auth, auth_opts})

    on_exit(fn ->
      Application.delete_env(:ash_a2a, AshA2A.Transport.GRPC.Server)
      Application.delete_env(:ash_a2a, @endpoint)
    end)

    {:ok, _} = DynamicSupervisor.start_link(strategy: :one_for_one, name: :"lane17_cs_#{uniq}")
    {:ok, _pid, port} = GRPC.Server.start_endpoint(@endpoint, 0)

    on_exit(fn ->
      try do
        GRPC.Server.stop_endpoint(@endpoint)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, channel} = GRPC.Stub.connect("localhost:#{port}", adapter: GRPC.Client.Adapters.Mint)
    %{channel: channel}
  end

  defp request(task_id \\ "") do
    %Pb.SendMessageRequest{
      message: %Pb.Message{
        message_id: AshA2A.Protocol.ID.generate("l17"),
        task_id: task_id,
        role: :ROLE_USER,
        parts: [%Pb.Part{content: {:text, "stream me"}}]
      }
    }
  end

  defp creds(sub), do: [metadata: %{"authorization" => "Bearer tok:" <> sub}]

  test "the streaming RPC's first frame is the initial task snapshot", %{channel: channel} do
    assert {:ok, stream} =
             Lf.A2a.V1.A2AService.Stub.send_streaming_message(channel, request(), creds("alice"))

    responses = stream |> Enum.to_list() |> Enum.map(fn {:ok, r} -> r end)
    assert [%Pb.StreamResponse{payload: {:task, %Pb.Task{id: id}}} | rest] = responses
    assert id != ""
    assert Enum.any?(rest, &match?(%Pb.StreamResponse{payload: {:status_update, _}}, &1))
  end

  test "a foreign principal cannot continue another principal's task over gRPC", %{
    channel: channel
  } do
    {:ok, stream} =
      Lf.A2a.V1.A2AService.Stub.send_streaming_message(channel, request(), creds("alice"))

    [{:ok, %Pb.StreamResponse{payload: {:task, %Pb.Task{id: id}}}} | _] = Enum.to_list(stream)

    result =
      Lf.A2a.V1.A2AService.Stub.send_streaming_message(channel, request(id), creds("bob"))

    error =
      case result do
        {:error, %GRPC.RPCError{} = e} ->
          e

        {:ok, stream} ->
          Enum.find_value(stream, fn
            {:error, e} -> e
            _ -> nil
          end)
      end

    assert %GRPC.RPCError{status: 5} = error
  end

  test "unary dispatch carries the verified principal: owner reads, foreign principal is NOT_FOUND",
       %{channel: channel} do
    {:ok, stream} =
      Lf.A2a.V1.A2AService.Stub.send_streaming_message(channel, request(), creds("alice"))

    [{:ok, %Pb.StreamResponse{payload: {:task, %Pb.Task{id: id}}}} | _] = Enum.to_list(stream)
    get = %Pb.GetTaskRequest{id: id}

    assert {:ok, %Pb.Task{id: ^id}} =
             Lf.A2a.V1.A2AService.Stub.get_task(channel, get, creds("alice"))

    assert {:error, %GRPC.RPCError{status: 5}} =
             Lf.A2a.V1.A2AService.Stub.get_task(channel, get, creds("bob"))
  end

  test "a malformed (non-list) endpoint env fails closed instead of admitting", %{
    channel: channel
  } do
    Application.put_env(:ash_a2a, @endpoint, %{auth: :oops})

    assert {:error, %GRPC.RPCError{status: status}} =
             Lf.A2a.V1.A2AService.Stub.get_task(channel, %Pb.GetTaskRequest{id: "x"})

    assert status == 13
  end
end
