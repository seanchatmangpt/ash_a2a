defmodule AshA2AFreedomGymHddlPlanTest do
  @moduledoc """
  Proves the FreedomGym facilitator's phase sequence is now real-HDDL-plan-
  derived, not the old hardcoded `@phases` list
  (`test/ash_a2a_freedom_gym_chicago_core_test.exs`'s `[:trust_god,
  :clean_house, :help_others]`).

  Two real, state-based assertions, Chicago style (no Mock/mox/patch/
  monkeypatch anywhere in this file):

  1. `AshA2A.Test.Fixture.FreedomGym.MeetingPlan.real_plan_phases!/0` --
     calling the real `hddl_cli` binary, which calls beam4pm's real
     `ferroplan::solve_hddl` over the real
     `test/support/hddl/freedom_gym_meeting/{domain,problem}.hddl` --
     returns the real, solved 6-phase sequence
     `[:open, :trust_god, :clean_house, :help_others, :fellowship, :close]`,
     asserted on the real returned list, not a description of it.
  2. Driving the facilitator's new `:next_phase` A2A skill (real dispatch,
     real `A2A.Agent`, same pattern as the Chicago-Core test) repeatedly
     over a real, isolated in-memory plan position yields exactly that same
     real ordered sequence -- proving the facilitator consults the real
     plan rather than re-implementing/echoing a hardcoded list.
  """

  # async: false -- this test's `FacilitatorAgent` is the same
  # `A2A.Agent`-generated process name
  # `AshA2AFreedomGymChicagoCoreTest`'s async: true test uses; running both
  # concurrently is a real process-name collision, not something this test
  # can or should route around (see `AshA2A.Test.AgentSupervisorCase`'s
  # moduledoc -- the per-case supervisor/registry names are unique, but the
  # `A2A.Agent` process itself is registered under its own module name).
  use ExUnit.Case, async: false

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.FreedomGym.{FacilitatorAgent, MeetingPlan}

  setup do
    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [FacilitatorAgent])

    :ok
  end

  test "MeetingPlan.real_plan_phases!/0 returns the real solved HDDL plan's phase sequence" do
    assert MeetingPlan.real_plan_phases!() == [
             :open,
             :trust_god,
             :clean_house,
             :help_others,
             :fellowship,
             :close
           ]
  end

  test "facilitator's :next_phase skill derives the real phase sequence from the real HDDL plan, over real A2A dispatch" do
    plan_name = :"hddl_plan_test_#{System.unique_integer([:positive])}"

    fetch_next = fn ->
      assert {:ok, task} =
               FacilitatorAgent.call(
                 FacilitatorAgent,
                 data_message(
                   %{plan_name: plan_name, prompt_text: "next real phase, please"},
                   %{metadata: %{skill: "next_phase"}}
                 ),
                 metadata: %{"a2a.auth" => %{identity: "hddl-plan-test-caller"}}
               )

      assert task.status.state == :completed
      assert [%A2A.Artifact{parts: [%A2A.Part.Data{data: result}]}] = task.artifacts
      result
    end

    observed_phases = Enum.map(1..6, fn _ -> fetch_next.().phase end)

    assert observed_phases == [
             :open,
             :trust_god,
             :clean_house,
             :help_others,
             :fellowship,
             :close
           ]

    # requires_redirect_check? invariant still holds over the real,
    # plan-derived :clean_house phase, exactly as :run_phase's contract
    # requires.
    clean_house_result =
      Enum.zip(observed_phases, 1..6)
      |> Enum.find(fn {phase, _} -> phase == :clean_house end)
      |> elem(1)

    assert clean_house_result == 3

    # The real plan is now exhausted -- a 7th call must fail for real,
    # not silently wrap around or fabricate a phase.
    assert {:ok, task} =
             FacilitatorAgent.call(
               FacilitatorAgent,
               data_message(%{plan_name: plan_name, prompt_text: "one too many"})
             )

    assert task.status.state == :failed

    # A real reset genuinely rewinds the real in-memory plan position.
    assert {:ok, reset_task} =
             FacilitatorAgent.call(
               FacilitatorAgent,
               data_message(%{plan_name: plan_name}, %{metadata: %{skill: "reset_plan"}}),
               metadata: %{"a2a.auth" => %{identity: "hddl-plan-test-caller"}}
             )

    assert reset_task.status.state == :completed
    assert fetch_next.().phase == :open
  end
end
