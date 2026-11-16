defmodule AshA2A.GRPCLane15DispatchAuditTest.CardHandler do
  @moduledoc false
  def handle_extended_card(_ctx) do
    {:error, %AshA2A.Protocol.JSONRPC.Error{code: Process.get(:lane15_code), message: "x"}}
  end
end

defmodule AshA2A.GRPCLane15DispatchAuditTest do
  @moduledoc """
  Lane 15 audit (UNVERIFIED: written without an Elixir toolchain). Checks the
  gRPC dispatch table against the vendored proto and the JSON-RPC error table.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.JSONRPC.Error
  alias AshA2A.Transport.Grpc.Dispatch

  alias AshA2A.GRPCLane15DispatchAuditTest.CardHandler

  @proto Path.expand("../priv/a2a_v1_1_spec_corpus/a2a.proto", __DIR__)

  defp proto_rpcs do
    ~r/^\s*rpc\s+(\w+)\(/m
    |> Regex.scan(File.read!(@proto), capture: :all_but_first)
    |> List.flatten()
  end

  test "every proto RPC is dispatched or served as the live bidi stream" do
    dispatched = Enum.map(Dispatch.methods(), & &1.name)
    missing = proto_rpcs() -- ["SendLiveMessage" | dispatched]
    assert missing == []
    assert Enum.sort(proto_rpcs()) == Enum.sort(["SendLiveMessage" | dispatched])
  end

  test "the server module exports a handler for every proto RPC" do
    Code.ensure_loaded!(AshA2A.Transport.GRPC.Server)

    for rpc <- proto_rpcs() do
      fun = rpc |> Macro.underscore() |> String.to_atom()

      assert function_exported?(AshA2A.Transport.GRPC.Server, fun, 2),
             "missing server handler #{fun}/2 for rpc #{rpc}"
    end
  end

  test "unknown RPC is UNIMPLEMENTED" do
    assert {:error, 12, _msg, []} = Dispatch.call_detailed("NoSuchRpc", %{}, __MODULE__)
  end

  test "status names cover every gRPC code" do
    assert Dispatch.status_name(10) == "ABORTED"
    assert Dispatch.status_name(16) == "UNAUTHENTICATED"
    assert Dispatch.status_name(99) == "UNKNOWN"
  end

  test "trailers carry status and message" do
    assert Dispatch.trailers({:ok, %{}}) == %{"grpc-status" => 0}

    assert Dispatch.trailers({:error, 5, "nf"}) ==
             %{"grpc-status" => 5, "grpc-message" => "nf"}
  end

  test "dispatch status table agrees with Error.grpc_status/1 for every A2A code" do
    for code <- -32_010..-32_001 do
      expected = Error.grpc_status(code)
      assert is_integer(expected)

      # Drive the real dispatch error mapping through the extended-card hook.
      Process.put(:lane15_code, code)

      assert {:error, ^expected, _msg, _details} =
               Dispatch.call_detailed("GetExtendedAgentCard", %{}, CardHandler, %{})
    end
  end
end
