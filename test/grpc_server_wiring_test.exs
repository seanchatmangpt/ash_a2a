defmodule AshA2A.GRPCServerWiringTest.Handler do
  @moduledoc false
  # Hand-written real JSON-RPC handler over the real EchoAgent: forwards the
  # call opts the gRPC binding binds (task/context ids, metadata) to
  # `AshA2A.Protocol.call/3` and returns the agent's RAW refusal reasons, which
  # the gRPC SendMessage wrapper must map to typed statuses.
  @behaviour AshA2A.Protocol.JSONRPC

  alias AshA2A.Protocol.JSONRPC.Error
  alias AshA2A.Transport.Runtime

  @impl true
  def handle_send(%{parts: [%{text: "ctype"} | _]}, _params, _ctx),
    do: {:error, {:content_type_not_supported, %{acceptedOutputModes: ["application/x-w27"]}}}

  def handle_send(message, params, %{agent: agent} = ctx) do
    md = ctx |> Map.get(:opts, %{}) |> Map.get(:metadata, %{})

    opts =
      [
        task_id: params["id"] || message.task_id,
        context_id: params["contextId"] || message.context_id
      ]
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Keyword.put(:metadata, md)

    case AshA2A.Protocol.call(agent, message, opts) do
      {:ok, %AshA2A.Protocol.Task{} = task} -> {:ok, Runtime.wire_task(task)}
      {:ok, other} -> {:ok, other}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def handle_get(task_id, _params, ctx) do
    case GenServer.call(ctx.agent, {:ash_a2a_get_task, ctx.principal, task_id}) do
      {:ok, task} -> {:ok, Runtime.wire_task(task)}
      _ -> {:error, Error.task_not_found()}
    end
  end

  @impl true
  def handle_cancel(_task_id, _params, _ctx), do: {:error, Error.task_not_found()}
end

defmodule AshA2A.GRPCServerWiringTest do
  @moduledoc """
  W27 courts over a real cowboy HTTP/2 listener (supervised, ephemeral port 0)
  and a real Mint gRPC client: tenant isolation, send-path refusal statuses
  (context mismatch, content type), W3C trace propagation into the dispatcher's
  correlation metadata, and the per-RPC request span.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Test.Fixture.EchoAgent
  alias AshA2A.GRPCServerWiringTest.Handler
  alias Lf.A2a.V1, as: Pb
  alias Lf.A2a.V1.A2AService.Stub

  @server AshA2A.Transport.GRPC.Server
  @traceparent "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"

  def forward(event, measurements, meta, pid),
    do: send(pid, {:telemetry, event, measurements, meta})

  setup do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [EchoAgent])

    transport = Module.concat(__MODULE__, Transport)
    start_supervised!({AshA2A.A2ATransport, name: transport})
    on_exit(fn -> Application.delete_env(:ash_a2a, @server) end)
    {:ok, transport: transport}
  end

  defp connect(handler, transport, name) do
    sup =
      start_supervised!(
        {AshA2A.Transport.GRPC.Supervisor,
         port: 0,
         handler: handler,
         ctx: %{agent: EchoAgent, opts: %{}, transport: transport, principal: :anonymous},
         name: name}
      )

    port = AshA2A.Transport.GRPC.Supervisor.port(sup)
    {:ok, ch} = GRPC.Stub.connect("localhost:#{port}", adapter: GRPC.Client.Adapters.Mint)
    ch
  end

  defp message(text, extra \\ []) do
    struct(
      %Pb.Message{
        message_id: AshA2A.Protocol.ID.generate("w27"),
        role: :ROLE_USER,
        parts: [%Pb.Part{content: {:text, text}}]
      },
      extra
    )
  end

  defp send_req(text, extra \\ [], tenant \\ ""),
    do: %Pb.SendMessageRequest{tenant: tenant, message: message(text, extra)}

  test "tenant isolation: a task is visible only under the tenant that created it", %{
    transport: t
  } do
    ch = connect(AshA2A.Transport.Plug, t, __MODULE__.TenantSup)

    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{id: id}}}} =
             Stub.send_message(ch, send_req("hi", [], "acme"))

    assert {:ok, %Pb.Task{id: ^id}} =
             Stub.get_task(ch, %Pb.GetTaskRequest{id: id, tenant: "acme"})

    assert {:error, %GRPC.RPCError{status: 5}} =
             Stub.get_task(ch, %Pb.GetTaskRequest{id: id, tenant: "globex"})

    assert {:error, %GRPC.RPCError{status: 5}} = Stub.get_task(ch, %Pb.GetTaskRequest{id: id})
  end

  test "client-supplied tenant metadata cannot cross tenants", %{transport: t} do
    ch = connect(AshA2A.Transport.Plug, t, __MODULE__.ForgeSup)

    forged =
      send_req(
        "hi",
        [
          metadata: %Google.Protobuf.Struct{
            fields: %{"ash_a2a.tenant" => %Google.Protobuf.Value{kind: {:string_value, "acme"}}}
          }
        ],
        ""
      )

    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{id: id}}}} =
             Stub.send_message(ch, forged)

    # The forged message metadata was dropped, so the task is untenanted.
    assert {:ok, %Pb.Task{id: ^id}} = Stub.get_task(ch, %Pb.GetTaskRequest{id: id})

    assert {:error, %GRPC.RPCError{status: 5}} =
             Stub.get_task(ch, %Pb.GetTaskRequest{id: id, tenant: "acme"})
  end

  test "context mismatch on a continuation -> INVALID_ARGUMENT(3)", %{transport: t} do
    ch = connect(Handler, t, __MODULE__.CtxSup)

    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{id: id}}}} =
             Stub.send_message(ch, send_req("hi"))

    assert {:error, %GRPC.RPCError{status: 3}} =
             Stub.send_message(
               ch,
               send_req("again", task_id: id, context_id: "ctx-not-the-tasks")
             )
  end

  test "content type not supported -> INVALID_ARGUMENT(3) CONTENT_TYPE_NOT_SUPPORTED", %{
    transport: t
  } do
    ch = connect(Handler, t, __MODULE__.CtypeSup)

    assert {:error, %GRPC.RPCError{status: 3, details: details}} =
             Stub.send_message(ch, send_req("ctype"))

    reasons =
      for %Google.Protobuf.Any{value: v} <- List.wrap(details),
          do: Google.Rpc.ErrorInfo.decode(v).reason

    assert "CONTENT_TYPE_NOT_SUPPORTED" in reasons
  end

  test "traceparent gRPC metadata reaches the dispatcher correlation metadata", %{transport: t} do
    ch = connect(AshA2A.Transport.Plug, t, __MODULE__.TraceSup)
    id = "w27-trace-#{System.unique_integer([:positive])}"
    :telemetry.attach(id, [:ash_a2a, :dispatch, :start], &__MODULE__.forward/4, self())
    on_exit(fn -> :telemetry.detach(id) end)

    assert {:ok, %Pb.SendMessageResponse{}} =
             Stub.send_message(ch, send_req("hi"), metadata: %{"traceparent" => @traceparent})

    assert_receive {:telemetry, [:ash_a2a, :dispatch, :start], _m, %{traceparent: @traceparent}},
                   5_000
  end

  test "each RPC runs inside a :grpc request span; error statuses emit the error event", %{
    transport: t
  } do
    ch = connect(AshA2A.Transport.Plug, t, __MODULE__.SpanSup)
    id = "w27-span-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      id,
      [[:ash_a2a, :transport, :request, :stop], [:ash_a2a, :transport, :request, :error]],
      &__MODULE__.forward/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(id) end)

    assert {:error, %GRPC.RPCError{status: 5}} = Stub.get_task(ch, %Pb.GetTaskRequest{id: "nope"})

    assert_receive {:telemetry, [:ash_a2a, :transport, :request, :stop], _,
                    %{binding: :grpc, rpc: "GetTask"}},
                   5_000

    assert_receive {:telemetry, [:ash_a2a, :transport, :request, :error], _,
                    %{binding: :grpc, rpc: "GetTask"}},
                   5_000
  end
end
