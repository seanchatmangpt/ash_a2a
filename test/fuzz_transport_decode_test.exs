# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.FuzzTransportDecodeTest do
  # Seeded fuzz of `message/send` through the real plugs: a wrong-typed member
  # is the binding's invalid-argument answer (JSON-RPC -32602, HTTP 400
  # INVALID_ARGUMENT), never a raise and never an internal error (-32603 / 500).
  use ExUnit.Case, async: true

  alias AshA2A.FuzzGen
  alias AshA2A.Protocol.JSON
  alias AshA2A.Test.PlugFixture.GreeterAgent

  @iterations 400

  @plugs [
    {"Protocol.Plug", AshA2A.Protocol.Plug},
    {"Transport.Plug", AshA2A.Transport.Plug},
    {"A2ATransport.Plug", AshA2A.A2ATransport.Plug}
  ]

  setup do
    agent = :"fuzz_transport_agent_#{System.unique_integer([:positive])}"
    {:ok, pid} = GreeterAgent.start_link(name: agent)
    on_exit(fn -> AshA2A.TestSupport.SafeStop.stop(pid) end)
    %{agent: agent}
  end

  defp post(mod, opts, path, body) do
    :post
    |> Plug.Test.conn(path, Jason.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("a2a-version", "1.1")
    |> mod.call(opts)
  end

  # Corrupted messages the decoder refuses (the ones a transport must map).
  defp refused_messages(seed) do
    FuzzGen.seed(seed)

    for _ <- 1..@iterations,
        message = FuzzGen.json_safe(FuzzGen.corrupt(FuzzGen.valid_message())),
        match?({:error, _}, JSON.decode(message, :message)),
        do: message
  end

  defp jsonrpc(message),
    do: %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "message/send",
      "params" => %{"message" => message}
    }

  for {label, mod} <- @plugs do
    test "#{label}: a message the decoder refuses is JSON-RPC -32602", %{agent: agent} do
      opts = unquote(mod).init(agent: agent, base_url: "http://x/a2a", json_rpc_path: [])
      messages = refused_messages(21)
      assert length(messages) > 50

      codes =
        for message <- messages do
          result =
            FuzzGen.run_with_deadline(fn -> post(unquote(mod), opts, "/", jsonrpc(message)) end)

          assert {:ok, conn} = result,
                 "raised on #{inspect(message, limit: 8)}: #{inspect(result, limit: 8)}"

          assert conn.status == 200
          body = Jason.decode!(conn.resp_body)
          code = get_in(body, ["error", "code"])

          # -32602 from the decoder; -32700 when the body guard already refused
          # the JSON text (an unrepresentable number). Never -32603.
          assert code in [-32_602, -32_700],
                 "#{inspect(message, limit: 8, printable_limit: 80)} answered #{inspect(body, limit: 8)}"

          code
        end

      assert Enum.count(codes, &(&1 == -32_602)) > 50
    end
  end

  test "Transport.HTTPJSON: a message the decoder refuses is HTTP 400 INVALID_ARGUMENT",
       %{agent: agent} do
    mod = AshA2A.Transport.HTTPJSON
    opts = mod.init(agent: agent, base_url: "http://x/rest")
    messages = refused_messages(22)
    assert length(messages) > 50

    for message <- messages do
      result =
        FuzzGen.run_with_deadline(fn ->
          post(mod, opts, "/message:send", %{"message" => message})
        end)

      assert {:ok, conn} = result,
             "raised on #{inspect(message, limit: 8)}: #{inspect(result, limit: 8)}"

      assert conn.status == 400,
             "#{inspect(message, limit: 8)} answered #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"

      assert get_in(Jason.decode!(conn.resp_body), ["error", "status"]) == "INVALID_ARGUMENT"
    end
  end

  test "the hand-picked wrong-typed members from the findings doc are -32602 / 400", %{
    agent: agent
  } do
    header = %{"messageId" => "m", "role" => "ROLE_USER"}

    cases = [
      1,
      "not an object",
      Map.put(header, "parts", "x"),
      Map.put(header, "parts", [1]),
      Map.merge(header, %{"parts" => [%{"text" => "hi"}], "metadata" => 5}),
      Map.merge(header, %{"parts" => [%{"text" => "hi"}], "taskId" => %{}}),
      Map.merge(header, %{"parts" => [%{"text" => 5}]}),
      Map.merge(header, %{"parts" => [%{"raw" => 5}]})
    ]

    rpc = AshA2A.Protocol.Plug.init(agent: agent, base_url: "http://x/a2a", json_rpc_path: [])
    rest = AshA2A.Transport.HTTPJSON.init(agent: agent, base_url: "http://x/rest")

    for message <- cases do
      conn = post(AshA2A.Protocol.Plug, rpc, "/", jsonrpc(message))
      assert get_in(Jason.decode!(conn.resp_body), ["error", "code"]) == -32_602, inspect(message)

      conn = post(AshA2A.Transport.HTTPJSON, rest, "/message:send", %{"message" => message})
      assert conn.status == 400, inspect(message)
    end
  end
end
