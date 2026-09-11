defmodule AshA2AFreedomGymZaiTest do
  @moduledoc """
  Chicago-AI tier of the FreedomGym primitive, second real provider: a REAL
  live call to Z.AI's GLM coding-plan endpoint (via `ash_ai`'s
  `AshAi.Actions.Prompt` + `req_llm`'s native `:zai_coder` provider),
  dispatched through a real supervised `A2A.Agent` -- no mock LLM client,
  no canned response, exactly like `ash_a2a_freedom_gym_llm_test.exs`'s
  Groq-backed avatar.

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

  @env_path Path.expand("~/.env")

  # Module-attribute evaluation runs at compile time, before any `defp` in
  # this module is invocable, so the real key-extraction logic is inlined
  # here directly (a local function call at this point would fail to
  # compile -- confirmed by a real CompileError on the first attempt).
  @zai_key (case File.exists?(@env_path) && File.read(@env_path) do
              {:ok, contents} ->
                case Regex.run(~r/^Z_AI_API_KEY=(.+)$/m, contents) do
                  [_, key] -> String.trim(key)
                  nil -> nil
                end

              _ ->
                nil
            end)

  @moduletag :external_api
  @describetag skip: is_nil(@zai_key) && "Z_AI_API_KEY not found in ~/.env"

  setup_all do
    if @zai_key do
      Application.put_env(:req_llm, :zai_coder_api_key, @zai_key)
    end

    :ok
  end

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

    assert {:ok, task} = ZaiLlmAvatarAgent.call(ZaiLlmAvatarAgent, message)
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
