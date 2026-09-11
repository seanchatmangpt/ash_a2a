defmodule AshA2AFreedomGymLlmTest do
  @moduledoc """
  Chicago-AI tier of the FreedomGym primitive: a REAL live call to Groq
  (via `ash_ai`'s `AshAi.Actions.Prompt` + `req_llm`'s Groq provider),
  dispatched through a real supervised `A2A.Agent`, exactly like every
  other FreedomGym/rap-battle agent in this suite -- no mock LLM client,
  no canned response.

  Chicago style still applies to the *assertions*: since real LLM output is
  not literal-reproducible, this test asserts on the real structural
  invariants the action's Ash return-type contract enforces (booleans are
  booleans, topic is a string or nil), not on exact wording -- the model
  supplies content variation, the Ash action contract and this test supply
  the pass/fail boundary.

  Named, visible skip (never a silent mock substitution) when `GROQ_API_KEY`
  is absent from the environment, per `testing-chicago-style.md`'s
  "real collaborator or an honest skip" discipline.
  """

  use ExUnit.Case, async: true

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.FreedomGym.LlmAvatarAgent

  @moduletag :external_api
  @describetag skip: is_nil(System.get_env("GROQ_API_KEY")) && "GROQ_API_KEY not set"

  test "a real Groq-backed avatar responds over real A2A dispatch with a real structured shape" do
    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        LlmAvatarAgent
      ])

    message =
      data_message(%{
        phase: :help_others,
        prompt_text:
          "This is the Help Others segment. Does anyone need support with something right now?"
      })

    assert {:ok, task} = LlmAvatarAgent.call(LlmAvatarAgent, message)
    assert task.status.state == :completed

    assert [%A2A.Artifact{parts: [%A2A.Part.Data{data: response}]}] = task.artifacts

    # Real, state-based assertions on the real object the real Groq call
    # returned -- not on its exact wording.
    assert %{wants_to_speak?: wants_to_speak?, asks_for_help?: asks_for_help?} = response
    assert is_boolean(wants_to_speak?)
    assert is_boolean(asks_for_help?)
    assert is_nil(response[:topic]) or is_binary(response[:topic])
  end
end
