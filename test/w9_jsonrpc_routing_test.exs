# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.W9JSONRPCRoutingTest do
  @moduledoc """
  W9 items 3 and 8: JSON-RPC routing hardening on `AshA2A.A2ATransport.Plug`
  (unknown method -> -32601, optional `:strict_pascal_case`, the
  `tasks/subscribe` alias, push methods with push disabled -> -32003), the
  alias-table parity court against `AshA2A.Protocol.JSONRPC`'s own source, and
  `GetExtendedAgentCard` with `params` absent. Real conns, real agent.
  """

  use ExUnit.Case, async: true

  alias AshA2A.A2ATransport.Plug, as: TransportPlug
  alias AshA2A.Test.PlugFixture.GreeterAgent

  setup do
    agent = :"w9_routing_agent_#{System.unique_integer([:positive])}"
    {:ok, pid} = GreeterAgent.start_link(name: agent)
    on_exit(fn -> AshA2A.TestSupport.SafeStop.stop(pid) end)
    %{agent: agent}
  end

  def provider(identity, card), do: {:ok, Map.put(card, "w9_sub", identity.sub)}

  defp opts(agent, extra \\ []),
    do: TransportPlug.init([agent: agent, base_url: "http://x/a2a"] ++ extra)

  defp message do
    {:ok, encoded} = AshA2A.Protocol.JSON.encode(AshA2A.Protocol.Message.new_user("hi"))
    encoded
  end

  defp rpc(mod, opts, method, params, identity \\ nil) do
    envelope = %{"jsonrpc" => "2.0", "id" => 1, "method" => method}
    envelope = if params == :absent, do: envelope, else: Map.put(envelope, "params", params)

    conn =
      :post
      |> Plug.Test.conn("/", Jason.encode!(envelope))
      |> Plug.Conn.put_req_header("content-type", "application/json")

    conn = if identity, do: AshA2A.Protocol.Plug.Auth.put_identity(conn, identity), else: conn
    conn = mod.call(conn, opts)
    {conn, Jason.decode!(conn.resp_body)}
  end

  defp code({_conn, body}), do: get_in(body, ["error", "code"])

  describe "unknown methods" do
    test "PascalCase and slash unknowns answer -32601, not a delegate crash", %{agent: agent} do
      o = opts(agent)

      for method <- ["NoSuchMethod", "message/nope", "tasks/unknown", "foo", "agent/other"] do
        assert code(rpc(TransportPlug, o, method, %{})) == -32_601, "method #{inspect(method)}"
      end
    end

    test "an unknown method is still version-gated first (-32009 beats -32601)", %{agent: agent} do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "NoSuchMethod",
          "params" => %{}
        })

      conn =
        :post
        |> Plug.Test.conn("/", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("a2a-version", "9.9")
        |> TransportPlug.call(opts(agent))

      assert %{"error" => %{"code" => -32_009}} = Jason.decode!(conn.resp_body)
    end
  end

  describe ":strict_pascal_case" do
    test "default (off) accepts both spellings", %{agent: agent} do
      o = opts(agent)

      for method <- ["message/send", "SendMessage"] do
        {_conn, body} = rpc(TransportPlug, o, method, %{"message" => message()})
        assert %{"result" => _} = body, method
      end
    end

    test "on: legacy slash names are -32601, PascalCase names still route", %{agent: agent} do
      o = opts(agent, strict_pascal_case: true)

      for method <- [
            "message/send",
            "message/stream",
            "tasks/get",
            "tasks/list",
            "tasks/resubscribe",
            "tasks/subscribe",
            "agent/getAuthenticatedExtendedCard"
          ] do
        assert code(rpc(TransportPlug, o, method, %{"id" => "t"})) == -32_601, method
      end

      assert {_, %{"result" => _}} =
               rpc(TransportPlug, o, "SendMessage", %{"message" => message()})

      # PascalCase still routes: an owner-scoped miss is -32001, not -32601.
      assert code(rpc(TransportPlug, o, "GetTask", %{"id" => "no-such-task"})) == -32_001
    end
  end

  describe "tasks/subscribe alias" do
    test "routes to tasks/resubscribe on A2ATransport.Plug (unknown task -> -32001)", %{
      agent: agent
    } do
      # Transport instance not running -> the resubscribe is delegated to the
      # vendored plug (which needs `streaming` declared to reach the task lookup).
      o =
        opts(agent,
          transport: :"w9_not_running_#{System.unique_integer([:positive])}",
          agent_card_opts: [capabilities: %{streaming: true}]
        )

      assert code(rpc(TransportPlug, o, "tasks/subscribe", %{"id" => "no-such-task"})) == -32_001

      assert code(rpc(TransportPlug, o, "tasks/resubscribe", %{"id" => "no-such-task"})) ==
               -32_001

      assert code(rpc(TransportPlug, o, "SubscribeToTask", %{"id" => "no-such-task"})) == -32_001
    end

    test "routes to tasks/resubscribe on Transport.Plug (unknown task -> -32001)", %{agent: agent} do
      o = AshA2A.Transport.Plug.init(agent: agent, base_url: "http://x/a2a")

      assert code(rpc(AshA2A.Transport.Plug, o, "tasks/subscribe", %{"id" => "no-such-task"})) ==
               -32_001
    end
  end

  describe "alias-table parity" do
    @jsonrpc_src "lib/ash_a2a/protocol/jsonrpc.ex"

    test "the transport routing table equals JSONRPC's alias table" do
      src = File.read!(@jsonrpc_src)
      [_, block] = Regex.run(~r/@method_aliases %\{(.*?)\n  \}/s, src)

      jsonrpc_aliases =
        ~r/"(\w+)" => "([^"]+)"/
        |> Regex.scan(block)
        |> Map.new(fn [_, k, v] -> {k, v} end)

      assert TransportPlug.method_aliases() == jsonrpc_aliases
    end

    test "the canonical methods the transport routes equal JSONRPC's dispatch clauses" do
      src = File.read!(@jsonrpc_src)

      dispatched =
        ~r/defp dispatch\(\s*%Request\{method: "([^"]+)"\}/
        |> Regex.scan(src)
        |> Enum.map(fn [_, m] -> m end)
        |> Enum.sort()

      assert dispatched != []
      assert TransportPlug.canonical_methods() == dispatched

      assert TransportPlug.canonical_methods() ==
               TransportPlug.method_aliases() |> Map.values() |> Enum.sort()
    end

    test "extra (slash) aliases are routing-only and target a canonical method" do
      extra = TransportPlug.extra_method_aliases()
      assert extra["tasks/subscribe"] == "tasks/resubscribe"

      for {alias_name, canonical} <- extra do
        assert canonical in TransportPlug.canonical_methods()
        refute Map.has_key?(TransportPlug.method_aliases(), alias_name)
      end
    end
  end

  describe "push methods with push disabled" do
    @push_methods [
      {"tasks/pushNotificationConfig/set",
       %{
         "taskId" => "t",
         "pushNotificationConfig" => %{"id" => "c", "url" => "https://93.184.215.14/h"}
       }},
      {"tasks/pushNotificationConfig/get", %{"id" => "t", "pushNotificationConfigId" => "c"}},
      {"tasks/pushNotificationConfig/list", %{"id" => "t"}},
      {"tasks/pushNotificationConfig/delete", %{"id" => "t", "pushNotificationConfigId" => "c"}},
      {"CreateTaskPushNotificationConfig",
       %{
         "taskId" => "t",
         "pushNotificationConfig" => %{"id" => "c", "url" => "https://93.184.215.14/h"}
       }},
      {"ListTaskPushNotificationConfigs", %{"id" => "t"}}
    ]

    test "default (push_notifications: false) answers -32003", %{agent: agent} do
      for {method, params} <- @push_methods do
        assert code(rpc(TransportPlug, opts(agent), method, params)) == -32_003, method
      end
    end

    test "push_notifications: true without a running transport instance still answers -32003",
         %{agent: agent} do
      o =
        opts(agent,
          push_notifications: true,
          transport: :"w9_not_running_#{System.unique_integer([:positive])}"
        )

      for {method, params} <- @push_methods do
        assert code(rpc(TransportPlug, o, method, params)) == -32_003, method
      end
    end

    test "Transport.Plug answers -32003 for push methods (no provider)", %{agent: agent} do
      o = AshA2A.Transport.Plug.init(agent: agent, base_url: "http://x/a2a")

      for {method, params} <- @push_methods do
        assert code(rpc(AshA2A.Transport.Plug, o, method, params)) == -32_003, method
      end
    end
  end

  describe "GetExtendedAgentCard with params absent (upstream #2425)" do
    test "serves the extended card on both spellings with no params member", %{agent: agent} do
      o = opts(agent, extended_card: &__MODULE__.provider/2)

      for method <- ["GetExtendedAgentCard", "agent/getAuthenticatedExtendedCard"] do
        {_conn, body} = rpc(TransportPlug, o, method, :absent, %{sub: "u9"})
        assert %{"result" => %{"w9_sub" => "u9", "name" => _}} = body, method
      end
    end

    test "also with params: null and params: {}", %{agent: agent} do
      o = opts(agent, extended_card: &__MODULE__.provider/2)

      for params <- [nil, %{}] do
        {_conn, body} = rpc(TransportPlug, o, "GetExtendedAgentCard", params, %{sub: "u9"})
        assert %{"result" => %{"w9_sub" => "u9"}} = body
      end
    end

    test "absent params without a provider is -32007, never a crash", %{agent: agent} do
      assert code(rpc(TransportPlug, opts(agent), "GetExtendedAgentCard", :absent, %{sub: "u9"})) ==
               -32_007
    end
  end
end
