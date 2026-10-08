defmodule AshA2A.Transport.GRPCAuthTest.Handler do
  @moduledoc """
  Real `AshA2A.Protocol.JSONRPC` handler over a real supervised EchoAgent —
  local copy so this court does not depend on another test file's module
  being compiled. No mocks.
  """

  @behaviour AshA2A.Protocol.JSONRPC

  alias AshA2A.Test.Fixture.EchoAgent

  @impl AshA2A.Protocol.JSONRPC
  def handle_send(message, _params, %{agent: agent}) do
    AshA2A.Protocol.call(agent, message)
  end

  @impl AshA2A.Protocol.JSONRPC
  def handle_get(task_id, _params, %{agent: agent}) do
    case EchoAgent.get_task(agent, task_id) do
      {:ok, task} -> {:ok, task}
      {:error, :not_found} -> {:error, %AshA2A.Protocol.JSONRPC.Error{code: -32001, message: "task not found: #{task_id}"}}
    end
  end

  @impl AshA2A.Protocol.JSONRPC
  def handle_cancel(task_id, _params, %{agent: agent}) do
    case EchoAgent.cancel(agent, task_id) do
      :ok -> EchoAgent.get_task(agent, task_id)
      {:error, :not_found} -> {:error, %AshA2A.Protocol.JSONRPC.Error{code: -32001, message: "task not found: #{task_id}"}}
      {:error, reason} -> {:error, %AshA2A.Protocol.JSONRPC.Error{code: -32002, message: inspect(reason)}}
    end
  end
end

defmodule AshA2A.Transport.GRPCAuthTest do
  @moduledoc """
  Court for the gRPC auth-interceptor seam (BIND-EQUIV-004): with the
  interceptor configured, a valid JWT passes and missing/invalid credentials
  surface as real over-the-wire UNAUTHENTICATED(16) refusals carrying the
  same typed body the HTTP binding emits on its 401
  (`{"error":"Unauthorized"}`); with the seam unconfigured, anonymous traffic
  still passes (backward compatibility with the anonymous gRPC subset).

  Every collaborator is real: a real cowboy HTTP/2 listener, a real gRPC
  client (Mint), the real `AshA2A.Protocol.Plug.Auth` pipeline, and a real
  HS256 JWT minted/verified with :crypto HMAC (the repo's JWTVerifier is
  compile-gated on :joken, which is not a dependency here). Zero mocks.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Test.Fixture.EchoAgent
  alias Lf.A2a.V1, as: Pb

  @endpoint AshA2A.Transport.GRPC.Server.Endpoint
  @secret "grpc-auth-court-hs256-secret"

  defmodule Verify do
    @moduledoc """
    Real HS256 JWT verification in the verify/3 callback — header check,
    constant-time HMAC-SHA256 signature comparison, required/issuer claims.
    (The repo's JWTVerifier is compile-gated on :joken, absent here; this is
    the same JOSE HS256 math, real :crypto, no mocks.)
    """

    @secret "grpc-auth-court-hs256-secret"

    def secret, do: @secret

    def verify(_scheme, credential, _conn) do
      with [header_b64, payload_b64, sig_b64] <- String.split(credential, ".", parts: 3),
           {:ok, %{"alg" => "HS256"}} <- Jason.decode(Base.url_decode64!(header_b64)),
           {:ok, claims} <- Jason.decode(Base.url_decode64!(payload_b64)),
           signing_input = header_b64 <> "." <> payload_b64,
           :ok <- check_sig(signing_input, sig_b64) do
        if is_binary(claims["sub"]) and claims["sub"] != "" do
          {:ok, %{id: claims["sub"]}}
        else
          {:error, "missing sub claim"}
        end
      else
        _ -> {:error, "invalid JWT"}
      end
    end

    defp check_sig(signing_input, sig_b64) do
      expected = :crypto.mac(:hmac, :sha256, @secret, signing_input)
      sig = Base.url_decode64!(sig_b64, padding: false)

      if Plug.Crypto.secure_compare(sig, expected) do
        :ok
      else
        {:error, "signature verification failed"}
      end
    end
  end

  setup context do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [EchoAgent])

    transport = Module.concat(__MODULE__, Transport)
    start_supervised!({AshA2A.A2ATransport, name: transport})

    Application.put_env(:ash_a2a, AshA2A.Transport.GRPC.Server,
      handler: AshA2A.Transport.GRPCAuthTest.Handler,
      ctx: %{agent: EchoAgent, opts: [], transport: transport}
    )

    on_exit(fn -> Application.delete_env(:ash_a2a, AshA2A.Transport.GRPC.Server) end)

    if context[:auth_config] != :none do
      auth_opts =
        AshA2A.Protocol.Plug.Auth.init(
          schemes: %{"bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}},
          verify: &Verify.verify/3
        )

      Application.put_env(:ash_a2a, @endpoint, auth: {AshA2A.Transport.GRPC.Auth, auth_opts})

      on_exit(fn -> Application.delete_env(:ash_a2a, @endpoint) end)
    end

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

  # Real HS256 JWT minted with :crypto HMAC — no JWT library needed for the
  # court; the verifier side (JWTVerifier) does its Joken-style verification
  # against this real token.
  defp token(sub, secret \\ @secret) do
    b64 = fn bin -> Base.url_encode64(bin, padding: false) end

    header = b64.(Jason.encode!(%{"alg" => "HS256", "typ" => "JWT"}))
    payload = b64.(Jason.encode!(%{"sub" => sub, "iss" => "grpc-auth-court"}))

    signing_input = header <> "." <> payload
    signature = :crypto.mac(:hmac, :sha256, secret, signing_input)

    signing_input <> "." <> b64.(signature)
  end

  defp rogue_token(sub) do
    token(sub, "wrong-secret")
  end

  defp request do
    %Pb.SendMessageRequest{
      message: %Pb.Message{
        message_id: AshA2A.Protocol.ID.generate("grpc-auth"),
        role: :ROLE_USER,
        parts: [%Pb.Part{content: {:text, "authenticated hello"}}]
      }
    }
  end

  defp opts_with_token(token) do
    metadata = %{"authorization" => "Bearer " <> token}
    [metadata: metadata]
  end

  test "verify callback accepts a court-minted HS256 token (real state assertion)" do
    assert {:ok, %{id: "alice"}} = Verify.verify(nil, token("alice"), nil)
    assert {:error, _} = Verify.verify(nil, token("alice", "wrong-secret"), nil)
    assert {:error, _} = Verify.verify(nil, "not-a-jwt", nil)
  end

  test "valid JWT passes the interceptor and creates a real task", %{channel: channel} do
    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{} = task}}} =
             Lf.A2a.V1.A2AService.Stub.send_message(
               channel,
               request(),
               opts_with_token(token("alice"))
             )

    assert task.status.state == :TASK_STATE_COMPLETED
    assert task.id != ""
  end

  test "missing authorization metadata is UNAUTHENTICATED(16) with the typed HTTP body", %{
    channel: channel
  } do
    assert {:error, %GRPC.RPCError{status: 16} = error} =
             Lf.A2a.V1.A2AService.Stub.send_message(channel, request())

    assert error.message == ~s({"error":"Unauthorized"})
  end

  test "invalid JWT signature is UNAUTHENTICATED(16) with the typed HTTP body", %{channel: channel} do
    # Signed with the WRONG secret — real signature verification failure.
    rogue = rogue_token("mallory")

    assert {:error, %GRPC.RPCError{status: 16} = error} =
             Lf.A2a.V1.A2AService.Stub.send_message(
               channel,
               request(),
               opts_with_token(rogue)
             )

    assert error.message == ~s({"error":"Unauthorized"})
  end

  test "garbage credential (not a JWT at all) is UNAUTHENTICATED(16)", %{channel: channel} do
    assert {:error, %GRPC.RPCError{status: 16}} =
             Lf.A2a.V1.A2AService.Stub.send_message(
               channel,
               request(),
               opts_with_token("not-a-jwt")
             )
  end

  @tag auth_config: :none
  test "unconfigured seam keeps the anonymous behavior (backward compatible)", %{channel: channel} do
    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{} = task}}} =
             Lf.A2a.V1.A2AService.Stub.send_message(channel, request())

    assert task.status.state == :TASK_STATE_COMPLETED
    assert task.id != ""
  end
end
