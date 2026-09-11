defmodule AshA2AFreedomGymChicagoCoreTest do
  @moduledoc """
  Chicago-Core deterministic tier of the "FreedomGym Chicago" primitive:
  five separately-`AshA2A`-extended Ash apps (one facilitator, four
  participant avatars), each standing in for its own
  independently-deployable service, exchanging real `A2A.Message`s through
  real `A2A.Agent` GenServers under one real `A2A.AgentSupervisor` --
  exactly the cross-app pattern proven in
  `test/ash_a2a_rap_battle_integration_test.exs`.

  This tier is fully deterministic: every participant avatar's behavior is
  real Elixir logic keyed off `phase` (and, for two avatars, an explicit
  extra argument), never an LLM call and never a canned literal passed
  through untouched. Assertions are state-based over the real accumulated
  responses returned by real A2A dispatch -- no Mock/mox/patch/monkeypatch.

  An AI-backed "Chicago AI" tier -- using the newly-added `ash_ai` dependency
  for live LLM-generated avatar responses -- is a deliberate, explicit
  follow-up phase, not built here. `ash_r2rml` is likewise added to `mix.exs`
  as a forward-looking dependency only; no live RDF/R2RML mapping is wired
  up in this test.
  """

  use ExUnit.Case, async: true

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.FreedomGym.{
    FacilitatorAgent,
    NewNervousAgent,
    DrunkalogAgent,
    EverythingGreatAgent,
    HelpRequestAgent
  }

  @phases [:trust_god, :clean_house, :help_others]

  setup do
    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        FacilitatorAgent,
        NewNervousAgent,
        DrunkalogAgent,
        EverythingGreatAgent,
        HelpRequestAgent
      ])

    :ok
  end

  defp facilitator_prompt(phase) do
    assert {:ok, task} =
             FacilitatorAgent.call(
               FacilitatorAgent,
               data_message(
                 %{phase: phase, prompt_text: "facilitator prompt for #{phase}"},
                 %{metadata: %{skill: "run_phase"}}
               )
             )

    assert task.status.state == :completed
    assert [%A2A.Artifact{parts: [%A2A.Part.Data{data: result}]}] = task.artifacts
    result
  end

  defp participant_response(agent, phase, prompt_text, extra_args \\ %{}) do
    message =
      data_message(Map.merge(%{phase: phase, prompt_text: prompt_text}, extra_args))

    assert {:ok, task} = agent.call(agent, message)
    assert task.status.state == :completed
    assert [%A2A.Artifact{parts: [%A2A.Part.Data{data: result}]}] = task.artifacts
    result
  end

  test "facilitator + four independent participant apps run a real phase sequence over real A2A dispatch" do
    # Drive the real phase sequence: for each phase, ask the facilitator's
    # separate app for that phase's real prompt/invariant checklist (over
    # real A2A dispatch), then hand that real prompt_text to each of the
    # four participant apps' own real A2A dispatch and collect their real
    # responses.
    responses_by_phase =
      Map.new(@phases, fn phase ->
        facilitator_result = facilitator_prompt(phase)

        assert facilitator_result.phase == phase
        assert facilitator_result.requires_redirect_check? == (phase == :clean_house)
        assert is_binary(facilitator_result.prompt_text)

        prompt_text = facilitator_result.prompt_text

        participant_results = %{
          new_nervous: participant_response(NewNervousAgent, phase, prompt_text),
          drunkalog: participant_response(DrunkalogAgent, phase, prompt_text),
          everything_great: participant_response(EverythingGreatAgent, phase, prompt_text),
          help_request: participant_response(HelpRequestAgent, phase, prompt_text)
        }

        {phase, participant_results}
      end)

    # -- Real, state-based invariant assertions over the real accumulated
    #    responses (not canned) --

    # new_nervous wants to speak only during the low-stakes :trust_god phase.
    assert %{wants_to_speak?: true, topic: "low_stakes:" <> _} =
             responses_by_phase[:trust_god][:new_nervous]

    assert %{wants_to_speak?: false} = responses_by_phase[:clean_house][:new_nervous]
    assert %{wants_to_speak?: false} = responses_by_phase[:help_others][:new_nervous]

    # drunkalog redirects to the current state in every non-clean_house
    # phase, and rambles about history in :clean_house (absent an explicit
    # redirect flag).
    assert %{redirected_to_current_state?: true, topic: "current:" <> _} =
             responses_by_phase[:trust_god][:drunkalog]

    assert %{redirected_to_current_state?: true, topic: "current:" <> _} =
             responses_by_phase[:help_others][:drunkalog]

    assert %{redirected_to_current_state?: false, topic: "history:" <> _} =
             responses_by_phase[:clean_house][:drunkalog]

    # When the test explicitly requests a redirect on a repeat :clean_house
    # call, drunkalog's real response shows redirected_to_current_state?:
    # true and a topic starting with "current:".
    redirected_drunkalog =
      participant_response(DrunkalogAgent, :clean_house, "repeat clean_house prompt", %{
        redirected: true
      })

    assert %{redirected_to_current_state?: true, topic: "current:" <> _} = redirected_drunkalog

    # everything_great is superficial by default, but reveals a real
    # "current:" topic once challenged.
    assert %{topic: "everything_is_fine", redirected_to_current_state?: false} =
             responses_by_phase[:trust_god][:everything_great]

    challenged_everything_great =
      participant_response(
        EverythingGreatAgent,
        :clean_house,
        "challenge prompt",
        %{challenged?: true}
      )

    assert %{redirected_to_current_state?: true, topic: "current:" <> _} =
             challenged_everything_great

    # help_request asks for help exactly during :help_others, never in the
    # other two phases.
    assert %{asks_for_help?: true} = responses_by_phase[:help_others][:help_request]
    assert %{asks_for_help?: false} = responses_by_phase[:trust_god][:help_request]
    assert %{asks_for_help?: false} = responses_by_phase[:clean_house][:help_request]

    # At most one participant is a genuine help-seeker in the :help_others
    # round (only help_request's avatar policy sets asks_for_help?: true).
    help_others_round = responses_by_phase[:help_others]

    help_seekers =
      help_others_round
      |> Map.values()
      |> Enum.count(& &1.asks_for_help?)

    assert help_seekers == 1
  end

  test "same participant/phase combo is fully deterministic on repeat real A2A calls" do
    for {agent, phase, extra_args} <- [
          {NewNervousAgent, :trust_god, %{}},
          {DrunkalogAgent, :clean_house, %{}},
          {DrunkalogAgent, :clean_house, %{redirected: true}},
          {EverythingGreatAgent, :help_others, %{}},
          {EverythingGreatAgent, :help_others, %{challenged?: true}},
          {HelpRequestAgent, :help_others, %{}}
        ] do
      first = participant_response(agent, phase, "determinism check", extra_args)
      second = participant_response(agent, phase, "determinism check", extra_args)

      assert first == second
    end
  end
end
