# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Sim.InvalidAgentResponseTest do
  @moduledoc """
  InvalidAgentResponseError (-32006): the agent's reply is not a valid A2A
  response. The sim skill `bad_reply` answers with a value that is not a JSON
  value; every binding must refuse the send with the specification's mapping
  (5.4: JSON-RPC -32006, HTTP 500, gRPC INTERNAL) and the ErrorInfo reason
  INVALID_AGENT_RESPONSE, and the agent's value must not reach the caller.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Sim.Server
  alias Lf.A2a.V1, as: Pb
  alias Lf.A2a.V1.A2AService.Stub

  @moduletag timeout: 120_000
  @moduletag capture_log: true

  setup_all do
    {:ok, server} = Server.start_link()
    info = Server.info()
    on_exit(fn -> if Process.alive?(server), do: Server.stop(server) end)
    {:ok, info: info}
  end

  defp params do
    %{
      "message" => %{
        "messageId" => "msg-bad-reply-" <> Integer.to_string(System.unique_integer([:positive])),
        "role" => "ROLE_USER",
        "parts" => [%{"text" => "go"}],
        "metadata" => %{"skill" => "bad_reply"}
      }
    }
  end

  defp post(info, url, json) do
    Req.post!(url,
      json: json,
      headers: [
        {"authorization", "Bearer " <> info.tokens.writer},
        {"a2a-version", "1.1"}
      ],
      retry: false,
      decode_body: false
    )
  end

  defp reasons(error_data) do
    for %{"reason" => reason} <- List.wrap(error_data), do: reason
  end

  for mount <- ["a2a", "jsonrpc"] do
    test "JSON-RPC mount /#{mount}: -32006 with ErrorInfo INVALID_AGENT_RESPONSE", %{info: info} do
      url = if unquote(mount) == "a2a", do: info.a2a_url, else: info.jsonrpc_url

      body =
        %{"jsonrpc" => "2.0", "id" => 1, "method" => "message/send", "params" => params()}

      resp = post(info, url, body)
      assert %{"error" => error} = Jason.decode!(resp.body)
      assert error["code"] == -32_006
      assert reasons(error["data"]) == ["INVALID_AGENT_RESPONSE"]
      refute resp.body =~ "#PID"
    end
  end

  test "HTTP+JSON: HTTP 500 INTERNAL with reason INVALID_AGENT_RESPONSE", %{info: info} do
    resp = post(info, info.rest_url <> "/message:send", params())
    assert resp.status == 500
    assert %{"error" => error} = Jason.decode!(resp.body)
    assert error["status"] == "INTERNAL"
    assert reasons(error["details"]) == ["INVALID_AGENT_RESPONSE"]
    refute resp.body =~ "#PID"
  end

  test "gRPC: INTERNAL (13) with ErrorInfo INVALID_AGENT_RESPONSE", %{info: info} do
    {:ok, channel} = GRPC.Stub.connect(info.grpc_target, adapter: GRPC.Client.Adapters.Mint)

    request = params() |> Jason.encode!() |> Protobuf.JSON.decode!(Pb.SendMessageRequest)

    opts = [
      metadata: %{"a2a-version" => "1.1", "authorization" => "Bearer " <> info.tokens.writer},
      timeout: 20_000
    ]

    assert {:error, %GRPC.RPCError{status: 13} = error} =
             Stub.send_message(channel, request, opts)

    refute to_string(error.message) =~ "#PID"
    GRPC.Stub.disconnect(channel)
  end

  test "the handler's reply validator accepts A2A parts and refuses the rest" do
    alias AshA2A.Protocol.{AgentReply, Part}

    assert :ok = AgentReply.validate_parts([Part.Text.new("hi"), Part.Data.new(%{"a" => 1})])
    assert {:error, _} = AgentReply.validate_parts([Part.Data.new(%{pid: self()})])
    assert {:error, _} = AgentReply.validate_parts(["a bare string"])
    assert {:error, _} = AgentReply.validate_parts(:not_a_list)
  end
end
