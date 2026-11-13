defmodule W15RegistryDiscoveryTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias AshA2A.Protocol.Registry
  alias AshA2A.Protocol.Registry.Plug, as: RegPlug

  defmodule AgentA, do: nil
  defmodule AgentB, do: nil
  defmodule Bare, do: nil

  @card_a %{
    name: "a",
    provider: %{organization: "Acme"},
    capabilities: %{streaming: true},
    default_input_modes: ["text/plain"],
    default_output_modes: ["application/json"],
    skills: [%{id: "a.price", tags: ["pricing"]}]
  }
  @card_b %{
    name: "b",
    provider: %{organization: "Beta"},
    capabilities: %{streaming: false},
    default_input_modes: ["image/png"],
    default_output_modes: ["text/plain"],
    skills: [%{id: "b.risk", tags: ["risk", "pricing"]}]
  }

  setup do
    name = :"w15_reg_#{System.unique_integer([:positive])}"

    disclose = fn card, principal ->
      case principal do
        "id:trusted" -> card
        _ -> Map.drop(card, [:provider])
      end
    end

    {:ok, _} = start_supervised({Registry, name: name, disclose: disclose})
    :ok = Registry.register(name, AgentA, @card_a)
    :ok = Registry.register(name, AgentB, @card_b)
    :ok = Registry.register(name, Bare, %{name: "bare"})
    %{reg: name}
  end

  test "card without skills does not crash find_by_skill", %{reg: reg} do
    assert Enum.sort(Registry.find_by_skill(reg, "pricing")) == [AgentA, AgentB]
  end

  test "multi-criteria find", %{reg: reg} do
    assert [{AgentB, _}] = Registry.find(reg, %{tag: "risk", capabilities: %{streaming: false}})
    assert [{AgentA, _}] = Registry.find(reg, %{provider: "Acme", input_mode: "text/plain"})
    assert [{AgentA, _}] = Registry.find(reg, %{skill_id: "a.price", output_mode: "application/json"})
    assert [] = Registry.find(reg, %{tag: "pricing", provider: "Nobody"})
  end

  test "disclosure differs per principal", %{reg: reg} do
    {:ok, trusted} = Registry.get_for(reg, AgentA, "id:trusted")
    {:ok, other} = Registry.get_for(reg, AgentA, "id:other")
    assert Map.has_key?(trusted, :provider)
    refute Map.has_key?(other, :provider)
    assert {:error, :not_found} = Registry.get_for(reg, Nope, "id:other")
  end

  defp get(reg, path, headers \\ []) do
    conn = conn(:get, path)
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    RegPlug.call(conn, RegPlug.init(registry: reg))
  end

  test "plug 200 list, filter, 404 and ETag 304", %{reg: reg} do
    conn = get(reg, "/registry/agents?tag=risk")
    assert conn.status == 200
    assert [cc] = get_resp_header(conn, "cache-control")
    assert cc =~ "max-age"
    assert %{"agents" => [%{"id" => id}]} = Jason.decode!(conn.resp_body)
    assert id == inspect(AgentB)

    [etag] = get_resp_header(conn, "etag")
    again = get(reg, "/registry/agents?tag=risk", [{"if-none-match", etag}])
    assert again.status == 304

    one = get(reg, "/registry/agents/" <> inspect(AgentA))
    assert one.status == 200
    assert %{"card" => %{"name" => "a"}} = Jason.decode!(one.resp_body)

    assert get(reg, "/registry/agents/Missing.Agent").status == 404
  end
end
