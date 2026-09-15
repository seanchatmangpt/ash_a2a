defmodule AshA2AFreedomGymZaiTest do
  @moduledoc """
  Chicago-AI tier of the FreedomGym primitive: a REAL live call to Z.AI's
  GLM coding-plan endpoint (via `ash_ai`'s `AshAi.Actions.Prompt` +
  `req_llm`'s native `:zai_coder` provider), dispatched through a real
  supervised `A2A.Agent` -- no mock LLM client, no canned response.
  Functionally redundant with `ash_a2a_freedom_gym_llm_test.exs`'s
  `LlmAvatar` since that avatar's 2026-09 Groq->Z.AI conversion (same
  provider, same model); kept separate since only conversion, not
  consolidation, was asked for.

  `Z_AI_API_KEY` lives in `~/.env` (checked via `mix dotenvy` loading at
  boot for other keys, but this repo doesn't declare `dotenvy` as a
  runtime dep, so it is read directly from `~/.env` here) under a name
  that doesn't match what `req_llm`'s `:zai_coder` provider looks up by
  default (`ZAI_API_KEY` / `:zai_coder_api_key`, see
  `deps/req_llm/lib/req_llm/keys.ex`) -- so this test reads the real key
  from `~/.env` once in `setup_all` and installs it via
  `Application.put_env(:req_llm, :zai_coder_api_key, key)`, the
  `:application` tier of `ReqLLM.Keys`' documented lookup precedence. The
  key itself is never logged or asserted on.

  Named, visible skip (never a silent mock substitution) when
  `~/.env` has no `Z_AI_API_KEY` line, per `testing-chicago-style.md`'s
  "real collaborator or an honest skip" discipline.
  """

  use ExUnit.Case, async: true

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.FreedomGym.ZaiLlmAvatarAgent

  # See AshA2A.Test.EnvKeyFixture's moduledoc for why this compile-time
  # extraction calls a shared *external* support module rather than a local
  # `defp` (a local call would fail to compile at this point -- confirmed by
  # a real CompileError on the first attempt, before this extraction).
  @zai_key AshA2A.Test.EnvKeyFixture.read_key("Z_AI_API_KEY")

  @moduletag :external_api
  @describetag skip: is_nil(@zai_key) && "Z_AI_API_KEY not found in ~/.env"

  setup_all do
    if @zai_key do
      Application.put_env(:req_llm, :zai_coder_api_key, @zai_key)
    end

    :ok
  end

  # Real, disclosed interaction with
  # test/ash_a2a_zai_concurrency_ocel_test.exs's real 50-way concurrency
  # probe when the full suite runs with `--include external_api`: real
  # rate-limit exhaustion from that probe can make this real, unseamed live
  # LLM call exceed the default 60s on both the ExUnit test process and
  # A2A.Agent.call/3's own GenServer.call -- confirmed reproducing (this
  # exact test timed out in a real full-suite `--include external_api` run)
  # -- same fix as test/ash_a2a_agent_semantic_request_test.exs, not a code
  # defect.
  @tag timeout: 180_000
  test "a real Z.AI GLM-backed avatar responds over real A2A dispatch with a real structured shape" do
    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        ZaiLlmAvatarAgent
      ])

    message =
      data_message(%{
        phase: :trust_god,
        prompt_text:
          "This is the Trust God segment. Does anyone want to share where they've seen God at work this week?"
      })

    assert {:ok, task} = ZaiLlmAvatarAgent.call(ZaiLlmAvatarAgent, message, timeout: 170_000)
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
