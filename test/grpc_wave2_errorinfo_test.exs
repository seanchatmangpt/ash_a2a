defmodule AshA2A.GRPCWave2ErrorInfoTest.ExtInvalid do
  @moduledoc false
  @behaviour AshA2A.Protocol.Extension
  def uri, do: "https://example.com/ext/w2-invalid"

  @impl true
  def declaration(_state), do: %AshA2A.Protocol.AgentExtension{uri: uri(), description: "w2"}

  @impl true
  def activate(_requested, _ctx, _state),
    do: {:error, %AshA2A.Protocol.JSONRPC.Error{code: -32_602, message: "bad ext params"}}
end

defmodule AshA2A.GRPCWave2ErrorInfoTest.ExtOpaque do
  @moduledoc false
  @behaviour AshA2A.Protocol.Extension
  def uri, do: "https://example.com/ext/w2-opaque"

  @impl true
  def declaration(_state), do: %AshA2A.Protocol.AgentExtension{uri: uri(), description: "w2"}

  @impl true
  def activate(_requested, _ctx, _state),
    do: {:error, %AshA2A.Protocol.JSONRPC.Error{code: -32_099, message: "opaque failure"}}
end

defmodule AshA2A.GRPCWave2ErrorInfoTest.Required do
  @moduledoc false
  @behaviour AshA2A.Protocol.Extension
  def uri, do: "https://example.com/ext/w2-required"

  @impl true
  def declaration(_state),
    do: %AshA2A.Protocol.AgentExtension{uri: uri(), description: "w2", required: true}

  @impl true
  def activate(_requested, _ctx, _state), do: {:ok, :active}
end

defmodule AshA2A.GRPCWave2ErrorInfoTest do
  @moduledoc """
  W2-08: real cowboy HTTP/2 listener + real Mint gRPC
  client asserting the version-gate and extension-gate refusals carry a
  google.rpc.ErrorInfo (reason, domain, metadata), activation failures too,
  and the Dispatch service label.
  """

  use ExUnit.Case, async: false

  alias AshA2A.GRPCWave2ErrorInfoTest.{ExtInvalid, ExtOpaque, Required}
  alias AshA2A.GRPCExtensionGateTest.Handler
  alias AshA2A.Test.Fixture.EchoAgent
  alias Lf.A2a.V1, as: Pb
  alias Lf.A2a.V1.A2AService.Stub

  @server AshA2A.Transport.GRPC.Server
  @endpoint AshA2A.Transport.GRPC.Server.Endpoint

  setup do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [EchoAgent])

    transport = Module.concat(__MODULE__, Transport)
    start_supervised!({AshA2A.A2ATransport, name: transport})

    on_exit(fn ->
      Application.delete_env(:ash_a2a, @server)
      Application.delete_env(:ash_a2a, @endpoint)
    end)

    {:ok, transport: transport}
  end

  defp listen(transport, extra) do
    Application.put_env(
      :ash_a2a,
      @server,
      Keyword.merge(
        [
          handler: Handler,
          ctx: %{agent: EchoAgent, opts: [], transport: transport, test_pid: self()}
        ],
        extra
      )
    )

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

  defp request do
    %Pb.SendMessageRequest{
      message: %Pb.Message{
        message_id: AshA2A.Protocol.ID.generate("w2"),
        role: :ROLE_USER,
        parts: [%Pb.Part{content: {:text, "hi"}}]
      }
    }
  end

  defp infos(%GRPC.RPCError{details: details}) do
    for %Google.Protobuf.Any{type_url: "type.googleapis.com/google.rpc.ErrorInfo", value: v} <-
          List.wrap(details),
        do: Google.Rpc.ErrorInfo.decode(v)
  end

  test "unsupported a2a-version -> UNIMPLEMENTED(12) + ErrorInfo VERSION_NOT_SUPPORTED", %{
    transport: t
  } do
    ch = listen(t, [])

    assert {:error, %GRPC.RPCError{status: 12} = e} =
             Stub.send_message(ch, request(), metadata: %{"a2a-version" => "99.0"})

    assert [%Google.Rpc.ErrorInfo{reason: "VERSION_NOT_SUPPORTED", domain: "a2a-protocol.org"} = i] =
             infos(e)

    assert i.metadata["detail"] =~ "99"
  end

  test "missing required extension -> FAILED_PRECONDITION(9) + ErrorInfo", %{transport: t} do
    ch = listen(t, extensions: [Required])

    assert {:error, %GRPC.RPCError{status: 9} = e} = Stub.send_message(ch, request())

    assert [%Google.Rpc.ErrorInfo{reason: "EXTENSION_SUPPORT_REQUIRED", domain: "a2a-protocol.org"} = i] =
             infos(e)

    assert i.metadata["detail"] =~ Required.uri()
  end

  test "extension activate failure with an A2A code carries that code's ErrorInfo", %{
    transport: t
  } do
    ch = listen(t, extensions: [ExtInvalid])

    assert {:error, %GRPC.RPCError{status: 3, message: "bad ext params"} = e} =
             Stub.send_message(ch, request(), metadata: %{"a2a-extensions" => ExtInvalid.uri()})

    assert [%Google.Rpc.ErrorInfo{reason: "INVALID_PARAMS", domain: "a2a-protocol.org"}] =
             infos(e)
  end

  test "extension activate failure with an unmapped code gets EXTENSION_ACTIVATION_FAILED", %{
    transport: t
  } do
    ch = listen(t, extensions: [ExtOpaque])

    assert {:error, %GRPC.RPCError{message: "opaque failure"} = e} =
             Stub.send_message(ch, request(), metadata: %{"a2a-extensions" => ExtOpaque.uri()})

    assert [
             %Google.Rpc.ErrorInfo{
               reason: "EXTENSION_ACTIVATION_FAILED",
               domain: "a2a-protocol.org",
               metadata: %{"detail" => "opaque failure"}
             }
           ] = infos(e)
  end

  test "Dispatch service label is the proto name; legacy alias kept" do
    assert AshA2A.Transport.Grpc.Dispatch.service() == "lf.a2a.v1.A2AService"
    assert AshA2A.Transport.Grpc.Dispatch.legacy_service() == "a2a.A2AService"
  end
end
