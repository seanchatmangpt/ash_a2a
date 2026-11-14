# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.MultiAgentPm4Test.IntakeResource do
  use Ash.Resource,
    domain: AshA2A.MultiAgentPm4Test.IntakeDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:work, :read)
  end
end

defmodule AshA2A.MultiAgentPm4Test.IntakeDomain do
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.MultiAgentPm4Test.IntakeResource)
  end
end

defmodule AshA2A.MultiAgentPm4Test.IntakeAgent do
  use AshA2A.Agent,
    resource_or_domain: AshA2A.MultiAgentPm4Test.IntakeResource,
    name: "multi_agent_pm4_intake"
end

defmodule AshA2A.MultiAgentPm4Test.ReviewResource do
  use Ash.Resource,
    domain: AshA2A.MultiAgentPm4Test.ReviewDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:work, :read)
  end
end

defmodule AshA2A.MultiAgentPm4Test.ReviewDomain do
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.MultiAgentPm4Test.ReviewResource)
  end
end

defmodule AshA2A.MultiAgentPm4Test.ReviewAgent do
  use AshA2A.Agent,
    resource_or_domain: AshA2A.MultiAgentPm4Test.ReviewResource,
    name: "multi_agent_pm4_review"
end

defmodule AshA2A.MultiAgentPm4Test.FulfilResource do
  use Ash.Resource,
    domain: AshA2A.MultiAgentPm4Test.FulfilDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:work, :read)
  end
end

defmodule AshA2A.MultiAgentPm4Test.FulfilDomain do
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.MultiAgentPm4Test.FulfilResource)
  end
end

defmodule AshA2A.MultiAgentPm4Test.FulfilAgent do
  use AshA2A.Agent,
    resource_or_domain: AshA2A.MultiAgentPm4Test.FulfilResource,
    name: "multi_agent_pm4_fulfil"
end

defmodule AshA2A.MultiAgentPm4Test do
  @moduledoc """
  Process-conformance of three real `AshA2A.Agent`s (intake, review, fulfil)
  interacting over real HTTP+JSON (Bandit loopback, `AshA2A.Protocol.Client`).
  Events are emitted only from observed outcomes of real client calls: the task
  ids and states come back from the remote agents, and the cross-agent hand-off
  is driven by those returned ids.

  ash_a2a also ships an ash_pplan-backed durability adapter (`adapter: :pplan`
  behind the `TaskStore` seam); ash_pplan is a test-only dependency here.
  """
  use ExUnit.Case, async: false
  use Pm4ExUnit

  @moduletag :pm4exunit
  @moduletag :serial_shard

  alias AshA2A.Protocol.{Client, Task}
  alias AshA2A.Test.{AgentSupervisorCase, EphemeralHttp}
  alias AshA2A.Transport.HTTPJSON, as: Binding

  @agents %{
    intake: AshA2A.MultiAgentPm4Test.IntakeAgent,
    review: AshA2A.MultiAgentPm4Test.ReviewAgent,
    fulfil: AshA2A.MultiAgentPm4Test.FulfilAgent
  }

  setup do
    {_sup, _reg} =
      AgentSupervisorCase.start_supervised_agents!(__MODULE__, Map.values(@agents))

    clients =
      Map.new(@agents, fn {role, agent} ->
        server =
          EphemeralHttp.start!(
            {Binding, Binding.init(agent: agent, base_url: "http://127.0.0.1/#{role}")}
          )

        {role, {server.base_url, Client.new(server.base_url, transport: :http_json)}}
      end)

    urls = Map.new(clients, fn {r, {u, _}} -> {r, u} end)
    clients = Map.new(clients, fn {r, {_, cl}} -> {r, cl} end)
    %{clients: clients, urls: urls}
  end

  defp ev(session, activity, attrs) do
    emit_event(session, "e#{System.unique_integer([:positive, :monotonic])}", activity, attrs)
  end

  # One real hop: call the agent, emit the event only from the returned task.
  defp hop(session, client, activity, text, opts \\ []) do
    assert {:ok, %Task{} = task} = Client.send_message(client, text, opts)
    assert task.status.state == :completed
    ev(session, activity, resource: task.id)
    task
  end

  test "intake -> review -> fulfil hand-off, each hop a distinct real task", %{
    pm4_session: session,
    clients: c
  } do
    t1 = hop(session, c.intake, :intake_done, "new order")
    t2 = hop(session, c.review, :review_done, "review #{t1.id}")
    t3 = hop(session, c.fulfil, :fulfil_done, "fulfil #{t2.id}")

    assert length(Enum.uniq([t1.id, t2.id, t3.id])) == 3

    # Each agent owns its task: foreign agents do not know the other's task id.
    assert {:ok, %Task{id: id}} = Client.get_task(c.intake, t1.id)
    assert id == t1.id
    assert {:error, _} = Client.get_task(c.review, t1.id)

    assert_conformance(session, [[:intake_done, :review_done, :fulfil_done]], min_fitness: 1.0)
  end

  test "skipping review violates the hand-off model", %{pm4_session: session, clients: c} do
    hop(session, c.intake, :intake_done, "new order")
    hop(session, c.fulfil, :fulfil_done, "fulfil without review")

    refute_conformance(session, [[:intake_done, :review_done, :fulfil_done]], min_fitness: 1.0)
  end

  test "three agents served concurrently each complete exactly their own task", %{
    pm4_session: session,
    clients: c
  } do
    results =
      [intake: :intake_done, review: :review_done, fulfil: :fulfil_done]
      |> Elixir.Task.async_stream(
        fn {role, activity} ->
          {:ok, %Task{} = t} = Client.send_message(Map.fetch!(c, role), "parallel #{role}")
          {activity, t}
        end,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.all?(results, fn {_a, t} -> t.status.state == :completed end)
    assert length(Enum.uniq(Enum.map(results, fn {_a, t} -> t.id end))) == 3

    for {activity, t} <- results, do: ev(session, activity, resource: t.id)

    # Concurrent arrival order is unconstrained: any permutation of the three is lawful.
    perms =
      for a <- [:intake_done, :review_done, :fulfil_done],
          b <- [:intake_done, :review_done, :fulfil_done] -- [a],
          cc <- [:intake_done, :review_done, :fulfil_done] -- [a, b],
          do: [a, b, cc]

    assert_conformance(session, perms)
  end

  test "agent cards are distinct per agent", %{urls: urls} do
    names =
      for {_role, url} <- urls do
        {:ok, card} = Client.discover(url)
        card.name
      end

    assert length(Enum.uniq(names)) == 3
  end
end
