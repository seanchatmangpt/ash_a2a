# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.W12Tenant.Fixture do
  @moduledoc false

  use Ash.Resource,
    domain: AshA2A.W12Tenant.FixtureDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  actions do
    action :converse, :map do
      run(fn _input, _context -> {:ok, %{text: "ok"}} end)
    end
  end

  a2a do
    skill(:converse, :converse, consequence: :observe)
  end
end

defmodule AshA2A.W12Tenant.FixtureDomain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.W12Tenant.Fixture)
  end
end

defmodule AshA2A.W12Tenant.Agent do
  @moduledoc false

  use AshA2A.Agent,
    resource_or_domain: AshA2A.W12Tenant.Fixture,
    name: "w12_tenant_agent"

  @impl AshA2A.Protocol.Agent
  def handle_message(message, _context) do
    case AshA2A.Protocol.Message.text(message) do
      "park" -> {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
      text -> {:reply, [AshA2A.Protocol.Part.Text.new("ok: " <> text)]}
    end
  end
end

defmodule AshA2A.W12TenantIsolationTest do
  @moduledoc """
  Tenant plumbing in the transport runtime: a task created under tenant T is
  invisible (indistinguishable from unknown) to other tenants and to
  untenanted callers; with no tenant, behaviour is unchanged. Real agent,
  real GenServer calls, no mocks.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.Message
  alias AshA2A.Transport.{Principal, Runtime}
  alias AshA2A.W12Tenant.Agent

  setup do
    name = :"w12_tenant_#{System.unique_integer([:positive])}"
    {:ok, pid} = Agent.start_link(name: name)

    on_exit(fn ->
      try do
        if Process.alive?(pid), do: GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, agent: name}
  end

  defp send_as(agent, text, tenant, extra \\ []) do
    metadata = if tenant, do: %{"ash_a2a.tenant" => tenant}, else: %{}
    Agent.call(agent, Message.new_user(text), [metadata: metadata] ++ extra)
  end

  test "Principal.tenant/1 and scope/2" do
    assert Principal.tenant(%{"ash_a2a.tenant" => "acme"}) == "acme"
    assert Principal.tenant(%{"a2a.tenant" => "beta"}) == "beta"
    assert Principal.tenant(%{}) == nil
    assert Principal.scope("sub:u1", nil) == "sub:u1"
    assert Principal.scope("sub:u1", "acme") == {"sub:u1", "acme"}
    assert Principal.key({"sub:u1", "acme"}) == "sub:u1"
  end

  test "a tenant-A task cannot be continued or read by tenant B or untenanted callers", %{agent: agent} do
    assert {:ok, task} = send_as(agent, "park", "acme")
    assert task.status.state == :input_required
    assert Runtime.task_tenant(task) == "acme"

    assert {:error, :not_found} = send_as(agent, "hi", "beta", task_id: task.id)
    assert {:error, :not_found} = send_as(agent, "hi", nil, task_id: task.id)

    assert {:ok, _} = GenServer.call(agent, {:ash_a2a_get_task, Principal.scope(:anonymous, "acme"), task.id})
    assert {:error, :not_found} =
             GenServer.call(agent, {:ash_a2a_get_task, Principal.scope(:anonymous, "beta"), task.id})

    # Negative control: the right tenant continues to completion.
    assert {:ok, done} = send_as(agent, "hi", "acme", task_id: task.id)
    assert done.status.state == :completed
  end

  test "nil tenant keeps default behaviour", %{agent: agent} do
    assert {:ok, task} = send_as(agent, "park", nil)
    assert Runtime.task_tenant(task) == nil
    assert {:ok, done} = send_as(agent, "hi", nil, task_id: task.id)
    assert done.status.state == :completed
  end

  test "tenant is stripped from wire tasks", %{agent: agent} do
    assert {:ok, task} = send_as(agent, "park", "acme")
    refute Map.has_key?(Runtime.wire_task(task).metadata, "ash_a2a.tenant")
  end
end
