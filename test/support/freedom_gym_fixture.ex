defmodule AshA2A.Test.Fixture.FreedomGym.Facilitator do
  @moduledoc """
  Real fixture resource for the Chicago-Core deterministic tier of the
  "FreedomGym Chicago" primitive
  (`test/ash_a2a_freedom_gym_chicago_core_test.exs`): a meeting facilitator,
  standing in for its own independently-deployable Ash app, exactly like the
  contestants/judge-panel pattern in `test/support/rap_battle_fixture.ex`.

  A generic `:action` skill (no data-layer persistence needed for a pure,
  stateless "give me this phase's prompt/checklist" capability, so
  `Ash.DataLayer.Simple` is used rather than ETS) -- real, deterministic
  Elixir logic, no LLM call, no fabricated randomness, so the test can
  assert on exact real output.

  `:run_phase` (unchanged, still used by the existing Chicago-Core test)
  trivially echoes a caller-supplied phase. `:next_phase` and `:reset_plan`
  are the new, additive real-plan-driven actions: `:next_phase` consults
  `AshA2A.Test.Fixture.FreedomGym.MeetingPlan`'s real in-memory plan
  position -- itself derived from a real `hddl_solve` run over a real HDDL
  domain/problem (`test/support/hddl/freedom_gym_meeting/`), never a
  hardcoded phase list -- then runs the popped phase through
  `AshA2A.Test.Fixture.FreedomGym.PhaseAdmission.admit/1` (a real,
  independent SELECT-vs-DO admission gate, the local equivalent of
  beam4pm's `BeamPM.Actuation` fail-closed allowlist check) before
  returning it, refusing with a typed `{:error, {:not_admitted, phase}}`
  for anything the plan produces that isn't on the real admitted-phase
  allowlist -- never actuating an unadmitted phase silently.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.FreedomGym.FacilitatorDomain,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshA2A]

  actions do
    action :run_phase, :map do
      argument(:phase, :atom, allow_nil?: false)
      argument(:prompt_text, :string, default: "")

      run(fn input, _context ->
        phase = input.arguments.phase
        prompt_text = input.arguments.prompt_text

        {:ok,
         %{
           phase: phase,
           prompt_text: prompt_text,
           requires_redirect_check?: phase == :clean_house
         }}
      end)
    end

    action :next_phase, :map do
      argument(:plan_name, :atom, allow_nil?: false)
      argument(:prompt_text, :string, default: "")

      run(fn input, _context ->
        plan_name = input.arguments.plan_name
        prompt_text = input.arguments.prompt_text

        with {:ok, phase} <- AshA2A.Test.Fixture.FreedomGym.MeetingPlan.next_phase(plan_name),
             {:ok, admitted_phase} <-
               AshA2A.Test.Fixture.FreedomGym.PhaseAdmission.admit(phase) do
          {:ok,
           %{
             phase: admitted_phase,
             prompt_text: prompt_text,
             requires_redirect_check?: admitted_phase == :clean_house
           }}
        else
          {:error, :plan_exhausted} ->
            {:error, "real HDDL plan exhausted for #{inspect(plan_name)}"}

          {:error, {:not_admitted, phase}} ->
            {:error, "phase #{inspect(phase)} refused by PhaseAdmission gate (not_admitted)"}
        end
      end)
    end

    action :reset_plan, :map do
      argument(:plan_name, :atom, allow_nil?: false)

      run(fn input, _context ->
        :ok = AshA2A.Test.Fixture.FreedomGym.MeetingPlan.reset(input.arguments.plan_name)
        {:ok, %{reset: true}}
      end)
    end
  end

  a2a do
    skill(:run_phase, :run_phase)
    skill(:next_phase, :next_phase)
    skill(:reset_plan, :reset_plan)
  end
end

defmodule AshA2A.Test.Fixture.FreedomGym.FacilitatorDomain do
  @moduledoc "Real fixture domain for `AshA2A.Test.Fixture.FreedomGym.Facilitator`."

  use Ash.Domain

  resources do
    resource(AshA2A.Test.Fixture.FreedomGym.Facilitator)
  end
end

defmodule AshA2A.Test.Fixture.FreedomGym.NewNervous do
  @moduledoc """
  Participant avatar `:new_nervous`: a real, deterministic behavioral
  policy (NOT LLM-backed) -- wants to speak only during the low-stakes
  `:trust_god` phase, and never asks for help or rambles about history.
  This is the first of four independent Ash apps in the Chicago-Core
  FreedomGym integration test, each standing in for its own
  independently-deployed participant service.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.FreedomGym.NewNervousDomain,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshA2A]

  actions do
    action :respond_to_prompt, :map do
      argument(:phase, :atom, allow_nil?: false)
      argument(:prompt_text, :string, default: "")

      run(fn input, _context ->
        phase = input.arguments.phase

        wants_to_speak? = phase == :trust_god

        {:ok,
         %{
           wants_to_speak?: wants_to_speak?,
           topic: if(wants_to_speak?, do: "low_stakes:first_day_nerves", else: nil),
           asks_for_help?: false,
           redirected_to_current_state?: false
         }}
      end)
    end
  end

  a2a do
    skill(:respond_to_prompt, :respond_to_prompt)
  end
end

defmodule AshA2A.Test.Fixture.FreedomGym.NewNervousDomain do
  @moduledoc "Real fixture domain for `AshA2A.Test.Fixture.FreedomGym.NewNervous`."

  use Ash.Domain

  resources do
    resource(AshA2A.Test.Fixture.FreedomGym.NewNervous)
  end
end

defmodule AshA2A.Test.Fixture.FreedomGym.Drunkalog do
  @moduledoc """
  Participant avatar `:drunkalog`: a real, deterministic behavioral policy
  -- outside the `:clean_house` phase it always redirects itself to the
  current state (`topic` starting with `"current:"`,
  `redirected_to_current_state?: true`); inside `:clean_house` it may ramble
  about history (`topic` starting with `"history:"`) unless the caller
  passes `redirected: true`, in which case it redirects to the current
  state exactly like every other phase. Fully deterministic: same
  `{phase, redirected}` input always produces the same real output.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.FreedomGym.DrunkalogDomain,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshA2A]

  actions do
    action :respond_to_prompt, :map do
      argument(:phase, :atom, allow_nil?: false)
      argument(:prompt_text, :string, default: "")
      argument(:redirected, :boolean, default: false)

      run(fn input, _context ->
        phase = input.arguments.phase
        redirected? = input.arguments.redirected

        redirect_to_current? = phase != :clean_house or redirected?

        {:ok,
         %{
           wants_to_speak?: true,
           topic:
             if(redirect_to_current?,
               do: "current:staying_present",
               else: "history:old_drinking_story"
             ),
           asks_for_help?: false,
           redirected_to_current_state?: redirect_to_current?
         }}
      end)
    end
  end

  a2a do
    skill(:respond_to_prompt, :respond_to_prompt)
  end
end

defmodule AshA2A.Test.Fixture.FreedomGym.DrunkalogDomain do
  @moduledoc "Real fixture domain for `AshA2A.Test.Fixture.FreedomGym.Drunkalog`."

  use Ash.Domain

  resources do
    resource(AshA2A.Test.Fixture.FreedomGym.Drunkalog)
  end
end

defmodule AshA2A.Test.Fixture.FreedomGym.EverythingGreat do
  @moduledoc """
  Participant avatar `:everything_great`: a real, deterministic behavioral
  policy -- by default returns a superficial topic
  (`"everything_is_fine"`), but when the caller passes `challenged?: true`
  returns a real topic starting with `"current:"` instead. Fully
  deterministic: same `{phase, challenged?}` input always produces the same
  real output.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.FreedomGym.EverythingGreatDomain,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshA2A]

  actions do
    action :respond_to_prompt, :map do
      argument(:phase, :atom, allow_nil?: false)
      argument(:prompt_text, :string, default: "")
      argument(:challenged?, :boolean, default: false)

      run(fn input, _context ->
        challenged? = input.arguments.challenged?

        {:ok,
         %{
           wants_to_speak?: true,
           topic: if(challenged?, do: "current:actually_struggling", else: "everything_is_fine"),
           asks_for_help?: false,
           redirected_to_current_state?: challenged?
         }}
      end)
    end
  end

  a2a do
    skill(:respond_to_prompt, :respond_to_prompt)
  end
end

defmodule AshA2A.Test.Fixture.FreedomGym.EverythingGreatDomain do
  @moduledoc "Real fixture domain for `AshA2A.Test.Fixture.FreedomGym.EverythingGreat`."

  use Ash.Domain

  resources do
    resource(AshA2A.Test.Fixture.FreedomGym.EverythingGreat)
  end
end

defmodule AshA2A.Test.Fixture.FreedomGym.HelpRequest do
  @moduledoc """
  Participant avatar `:help_request`: a real, deterministic behavioral
  policy -- asks for help (`asks_for_help?: true`) exactly when
  `phase == :help_others`, and never otherwise. Fully deterministic: same
  `phase` input always produces the same real output.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.FreedomGym.HelpRequestDomain,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshA2A]

  actions do
    action :respond_to_prompt, :map do
      argument(:phase, :atom, allow_nil?: false)
      argument(:prompt_text, :string, default: "")

      run(fn input, _context ->
        phase = input.arguments.phase
        asks_for_help? = phase == :help_others

        {:ok,
         %{
           wants_to_speak?: asks_for_help?,
           topic: if(asks_for_help?, do: "current:need_support", else: nil),
           asks_for_help?: asks_for_help?,
           redirected_to_current_state?: false
         }}
      end)
    end
  end

  a2a do
    skill(:respond_to_prompt, :respond_to_prompt)
  end
end

defmodule AshA2A.Test.Fixture.FreedomGym.HelpRequestDomain do
  @moduledoc "Real fixture domain for `AshA2A.Test.Fixture.FreedomGym.HelpRequest`."

  use Ash.Domain

  resources do
    resource(AshA2A.Test.Fixture.FreedomGym.HelpRequest)
  end
end

defmodule AshA2A.Test.Fixture.FreedomGym.FacilitatorAgent do
  @moduledoc """
  Real `A2A.Agent` for `AshA2A.Test.Fixture.FreedomGym.Facilitator`,
  standing in for "the facilitator's own independently-deployed Ash app" in
  the Chicago-Core FreedomGym integration test.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.FreedomGym.Facilitator,
    name: "freedom_gym_facilitator_agent"
end

defmodule AshA2A.Test.Fixture.FreedomGym.NewNervousAgent do
  @moduledoc """
  Real `A2A.Agent` for `AshA2A.Test.Fixture.FreedomGym.NewNervous`, standing
  in for "the new/nervous participant's own independently-deployed Ash app."
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.FreedomGym.NewNervous,
    name: "freedom_gym_new_nervous_agent"
end

defmodule AshA2A.Test.Fixture.FreedomGym.DrunkalogAgent do
  @moduledoc """
  Real `A2A.Agent` for `AshA2A.Test.Fixture.FreedomGym.Drunkalog`, standing
  in for "the drunkalog participant's own independently-deployed Ash app."
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.FreedomGym.Drunkalog,
    name: "freedom_gym_drunkalog_agent"
end

defmodule AshA2A.Test.Fixture.FreedomGym.EverythingGreatAgent do
  @moduledoc """
  Real `A2A.Agent` for `AshA2A.Test.Fixture.FreedomGym.EverythingGreat`,
  standing in for "the everything's-great participant's own
  independently-deployed Ash app."
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.FreedomGym.EverythingGreat,
    name: "freedom_gym_everything_great_agent"
end

defmodule AshA2A.Test.Fixture.FreedomGym.HelpRequestAgent do
  @moduledoc """
  Real `A2A.Agent` for `AshA2A.Test.Fixture.FreedomGym.HelpRequest`,
  standing in for "the help-requesting participant's own
  independently-deployed Ash app."
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.FreedomGym.HelpRequest,
    name: "freedom_gym_help_request_agent"
end
