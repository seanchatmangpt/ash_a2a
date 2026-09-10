defmodule AshA2ARegistryTest do
  @moduledoc """
  Chicago-style multi-agent `A2A.Registry` collision test (ash_a2a task #22).

  Compiles two distinct real fixture resources
  (`AshA2A.Test.Fixture.Echo`/`AshA2A.Test.Fixture.Widget`,
  `test/support/fixture.ex`) into two distinct real `AshA2A.Agent` modules
  (`EchoAgent`/`WidgetAgent`), starts both under one real
  `A2A.AgentSupervisor` (the same child spec `AshA2A.Application.start/2`
  wires in) with its integrated `A2A.Registry`, and asserts on the real
  registry state -- no Mock/mox/patch, no hand-built registry entries.
  """

  use ExUnit.Case

  alias AshA2A.Test.Fixture.{EchoAgent, WidgetAgent}

  test "two distinct AshA2A.Agent modules register distinct A2A.Registry identities" do
    sup_name = :"#{__MODULE__}.Sup"
    registry_name = :"#{__MODULE__}.Registry"

    {:ok, sup} =
      A2A.AgentSupervisor.start_link(
        agents: [EchoAgent, WidgetAgent],
        name: sup_name,
        registry: registry_name
      )

    on_exit(fn ->
      try do
        Supervisor.stop(sup)
      catch
        :exit, _ -> :ok
      end
    end)

    # Both agent processes are real, independently-supervised children of
    # the same real supervisor -- not the same process under two names.
    children = Supervisor.which_children(sup)
    assert length(children) == 3

    echo_pid = GenServer.whereis(EchoAgent)
    widget_pid = GenServer.whereis(WidgetAgent)

    assert is_pid(echo_pid)
    assert is_pid(widget_pid)
    refute echo_pid == widget_pid

    # `A2A.Registry` keys its ETS table by agent *module* (registry.ex:104-111),
    # populated at real `init/1` time from each agent's own real
    # `agent_card/0` -- assert on the actual registered entries, not on the
    # agent modules' identity alone.
    assert {:ok, echo_card} = A2A.Registry.get(registry_name, EchoAgent)
    assert {:ok, widget_card} = A2A.Registry.get(registry_name, WidgetAgent)

    assert echo_card.name == "echo_agent"
    assert widget_card.name == "widget_agent"
    refute echo_card == widget_card

    # The real skill sets baked into each card (via
    # `AshA2A.Info.agent_card/2` -> the resource/domain's own compiled
    # capability index) are likewise distinct -- confirms the two entries
    # are genuinely different agents, not one card registered twice.
    assert [%{id: "echo", name: "echo"}] = echo_card.skills
    assert [%{id: "inspect", name: "inspect"}] = widget_card.skills

    all_entries = A2A.Registry.all(registry_name)
    registered_modules = Enum.map(all_entries, fn {mod, _card} -> mod end)

    assert length(all_entries) == 2
    assert Enum.sort(registered_modules) == Enum.sort([EchoAgent, WidgetAgent])
    # No collision: as many distinct registry keys as distinct agent modules.
    assert length(Enum.uniq(registered_modules)) == 2

    # Both agents are independently dispatchable through the shared
    # supervisor/registry -- distinct identity, not just distinct metadata.
    echo_message = A2A.Message.new_user([A2A.Part.Data.new(%{})])
    widget_message = A2A.Message.new_user([A2A.Part.Data.new(%{})])

    assert {:ok, echo_task} = EchoAgent.call(EchoAgent, echo_message)
    assert {:ok, widget_task} = WidgetAgent.call(WidgetAgent, widget_message)

    assert echo_task.status.state == :completed
    assert widget_task.status.state == :completed
    refute echo_task.id == widget_task.id
  end
end
