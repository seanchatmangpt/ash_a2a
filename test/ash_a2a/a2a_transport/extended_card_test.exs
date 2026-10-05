# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.A2ATransport.ExtendedCardTest do
  @moduledoc """
  `agent/getAuthenticatedExtendedCard` through the real
  `AshA2A.A2ATransport.Plug` fronting a real `AshA2A.Agent` GenServer. The
  identity is placed on the conn with `AshA2A.Protocol.Plug.Auth.put_identity/2` -- the
  exact slot the real `AshA2A.Protocol.Plug.Auth` writes after verifying a credential.
  No mocks.
  """
  use ExUnit.Case, async: true

  alias AshA2A.A2ATransport.Plug, as: TransportPlug
  alias AshA2A.Test.PlugFixture.GreeterAgent

  setup do
    name = :"ext_card_agent_#{System.unique_integer([:positive])}"
    {:ok, pid} = GreeterAgent.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    %{agent: name}
  end

  def add_admin_skill(identity, card) do
    skill = %{
      "id" => "admin",
      "name" => "Admin",
      "description" => "for #{identity.sub}",
      "tags" => []
    }

    {:ok, Map.update!(card, "skills", &(&1 ++ [skill]))}
  end

  defp rpc(opts, method, identity \\ nil) do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 7, "method" => method, "params" => %{}})

    conn =
      :post
      |> Plug.Test.conn("/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    conn = if identity, do: AshA2A.Protocol.Plug.Auth.put_identity(conn, identity), else: conn
    conn = TransportPlug.call(conn, opts)
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp opts(agent, extra),
    do: TransportPlug.init([agent: agent, base_url: "http://x/a2a"] ++ extra)

  test "no provider configured is -32007 (not configured), not -32004", %{agent: agent} do
    assert {200, %{"error" => %{"code" => -32_007}}} =
             rpc(opts(agent, []), "agent/getAuthenticatedExtendedCard", %{sub: "u1"})
  end

  test "unauthenticated caller is HTTP 401", %{agent: agent} do
    o = opts(agent, extended_card: &__MODULE__.add_admin_skill/2)

    assert {401, %{"error" => %{"code" => -32_600}}} =
             rpc(o, "agent/getAuthenticatedExtendedCard")
  end

  test "authenticated caller receives the provider's extended card", %{agent: agent} do
    o = opts(agent, extended_card: {__MODULE__, :add_admin_skill, []})

    assert {200, %{"result" => card}} = rpc(o, "GetExtendedAgentCard", %{sub: "u1"})
    ids = Enum.map(card["skills"], & &1["id"])
    assert "admin" in ids
    assert List.last(card["skills"])["description"] == "for u1"
    # v1.0 wire shape: the serving URL and protocol version ride inside
    # `supportedInterfaces` (protocolVersion 1.0, the Version single source of
    # truth); the card carries no top-level `url` or `protocolVersion`.
    assert [%{"protocolVersion" => "1.0", "url" => url} | _] = card["supportedInterfaces"]
    assert is_binary(url)
    refute Map.has_key?(card, "url")
    refute Map.has_key?(card, "protocolVersion")
  end

  test "a provider error or crash never falls back to the public card", %{agent: agent} do
    failing = opts(agent, extended_card: fn _, _ -> {:error, :denied} end)
    crashing = opts(agent, extended_card: fn _, _ -> raise "boom" end)

    assert {200, %{"error" => %{"code" => -32_007}}} =
             rpc(failing, "agent/getAuthenticatedExtendedCard", %{sub: "u1"})

    assert {200, %{"error" => %{"code" => -32_007}}} =
             rpc(crashing, "agent/getAuthenticatedExtendedCard", %{sub: "u1"})
  end

  test "the public card advertises extendedAgentCard only with a provider", %{agent: agent} do
    card = fn o ->
      :get
      |> Plug.Test.conn("/.well-known/agent-card.json")
      |> TransportPlug.call(o)
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()
    end

    assert card.(opts(agent, extended_card: &__MODULE__.add_admin_skill/2))["capabilities"][
             "extendedAgentCard"
           ] ==
             true

    refute card.(opts(agent, []))["capabilities"]["extendedAgentCard"]
  end

  test "an invalid provider is rejected at init", %{agent: agent} do
    assert_raise ArgumentError, fn -> opts(agent, extended_card: :nope) end
  end
end
