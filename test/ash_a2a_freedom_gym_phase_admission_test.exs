defmodule AshA2AFreedomGymPhaseAdmissionTest do
  @moduledoc """
  Proves the real SELECT-vs-DO admission gate closes the gap where the
  Facilitator's `:next_phase` action returned the HDDL-solver-selected phase
  directly as the actuation result with no independent admission check.

  Real, state-based assertions, Chicago style (no Mock/mox/patch/monkeypatch
  anywhere in this file):

  1. `PhaseAdmission.admit/1` unit-level: a real admitted phase passes
     through as `{:ok, phase}`; a deliberately unadmitted phase is refused
     with the typed `{:error, {:not_admitted, phase}}`, not silently let
     through.
  2. Integration-level, over real A2A dispatch: the real
     `AshA2A.Test.Fixture.FreedomGym.MeetingPlan` Agent (a real, live
     process, not a mock) is seeded for real with an unadmitted phase
     injected into its real plan-position state, and the Facilitator's real
     `:next_phase` skill is driven against it -- the task must fail with the
     admission gate's refusal, never complete with the unadmitted phase
     actuated.
  """

  use ExUnit.Case, async: false

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.FreedomGym.{FacilitatorAgent, MeetingPlan, PhaseAdmission}

  setup do
    # RFC-SA2A-001 S29: a transport-authenticated caller holds authority for
    # a `:change`/`:external_do` capability only when a real
    # `AshA2A.Authority.Broker` grant stands for that exact (principal,
    # capability) pair -- see `AshA2A.Authority.Grant`. Issued here for the
    # real pairs this file's own dispatches use.
    AshA2A.Test.AuthorityGrantCase.grant!([
      {"phase-admission-test-caller", AshA2A.Test.Fixture.FreedomGym.Facilitator, ["next_phase"]}
    ])

    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [FacilitatorAgent])

    :ok
  end

  describe "PhaseAdmission.admit/1 (unit, real allowlist)" do
    test "a real admitted phase passes through" do
      assert PhaseAdmission.admit(:trust_god) == {:ok, :trust_god}
      assert PhaseAdmission.admit(:close) == {:ok, :close}
    end

    test "a deliberately unadmitted phase is refused with the typed error" do
      assert PhaseAdmission.admit(:secret_backdoor_phase) ==
               {:error, {:not_admitted, :secret_backdoor_phase}}
    end

    test "admission_verdict/1 and decision/1 agree with admit/1 on both outcomes" do
      assert PhaseAdmission.admission_verdict(:open) == {:admitted, :open}
      assert %{verdict: :admitted, phase: :open} = PhaseAdmission.decision(:open)

      assert {:refused, reason} = PhaseAdmission.admission_verdict(:not_a_real_phase)
      assert reason =~ "not an admitted FreedomGym meeting phase"

      assert %{verdict: :refused, phase: :not_a_real_phase} =
               PhaseAdmission.decision(:not_a_real_phase)
    end
  end

  describe "Facilitator :next_phase over real A2A dispatch, with an unadmitted phase injected into the real plan" do
    test "an unadmitted phase popped from the real plan is refused, never actuated" do
      plan_name = :"phase_admission_test_#{System.unique_integer([:positive])}"

      # Start the real MeetingPlan Agent for real, then inject a real,
      # deliberately unadmitted phase at the front of its real in-memory
      # plan state -- a real live process's real state, not a mock/stub.
      {:ok, _pid} = MeetingPlan.start_link(plan_name)

      Agent.update(plan_name, fn state ->
        %{state | phases: [:rogue_unadmitted_phase | state.phases], index: 0}
      end)

      assert {:ok, task} =
               FacilitatorAgent.call(
                 FacilitatorAgent,
                 data_message(
                   %{plan_name: plan_name, prompt_text: "attempt to actuate an unadmitted phase"},
                   %{metadata: %{skill: "next_phase"}}
                 ),
                 metadata: %{"a2a.auth" => %{identity: "phase-admission-test-caller"}}
               )

      assert task.status.state == :failed
    end

    test "an admitted phase popped from the real plan still completes exactly as before" do
      plan_name = :"phase_admission_ok_test_#{System.unique_integer([:positive])}"

      assert {:ok, task} =
               FacilitatorAgent.call(
                 FacilitatorAgent,
                 data_message(
                   %{plan_name: plan_name, prompt_text: "first real admitted phase"},
                   %{metadata: %{skill: "next_phase"}}
                 ),
                 metadata: %{"a2a.auth" => %{identity: "phase-admission-test-caller"}}
               )

      assert task.status.state == :completed
      assert [%A2A.Artifact{parts: [%A2A.Part.Data{data: result}]}] = task.artifacts
      assert result.phase == :open
    end
  end
end
