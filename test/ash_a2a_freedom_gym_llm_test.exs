defmodule AshA2AFreedomGymLlmTest do
  @moduledoc """
  Chicago-AI tier of the FreedomGym primitive: a REAL live call to Z.AI
  (via `ash_ai`'s `AshAi.Actions.Prompt` + `req_llm`'s native `zai_coder`
  provider), dispatched through a real supervised `A2A.Agent`, exactly like
  every other FreedomGym/rap-battle agent in this suite -- no mock LLM
  client, no canned response.

  Formerly Groq-backed; swapped 2026-09 per explicit request to replace
  this repo's Groq usage with Z.AI -- this test is now functionally
  redundant with `test/ash_a2a_freedom_gym_zai_test.exs` (same provider,
  same model), kept separate since only conversion, not consolidation, was
  asked for.

  Chicago style still applies to the *assertions*: since real LLM output is
  not literal-reproducible, this test asserts on the real structural
  invariants the action's Ash return-type contract enforces (booleans are
  booleans, topic is a string or nil), not on exact wording -- the model
  supplies content variation, the Ash action contract and this test supply
  the pass/fail boundary.

  Named, visible skip (never a silent mock substitution) when
  `ZAI_API_KEY` is not found in `~/.env`, per `testing-chicago-style.md`'s
  "real collaborator or an honest skip" discipline.
  """

  use ExUnit.Case, async: true

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.FreedomGym.LlmAvatarAgent

  # See AshA2A.Test.EnvKeyFixture's moduledoc for why this compile-time
  # extraction calls a shared *external* support module rather than a local
  # `defp` (a local call would fail to compile at this point).
  @zai_key AshA2A.Test.EnvKeyFixture.read_key("ZAI_API_KEY")

  @moduletag :external_api
  @describetag skip: is_nil(@zai_key) && "ZAI_API_KEY not found in ~/.env"

  setup_all do
    if @zai_key do
      Application.put_env(:req_llm, :zai_coder_api_key, @zai_key)
    end

    :ok
  end

  test "a real Z.AI-backed avatar responds over real A2A dispatch with a real structured shape" do
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

    # Real, state-based assertions on the real object the real Z.AI call
    # returned -- not on its exact wording.
    assert %{wants_to_speak?: wants_to_speak?, asks_for_help?: asks_for_help?} = response
    assert is_boolean(wants_to_speak?)
    assert is_boolean(asks_for_help?)
    assert is_nil(response[:topic]) or is_binary(response[:topic])
  end
end
