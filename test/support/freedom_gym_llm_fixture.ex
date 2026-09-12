defmodule AshA2A.Test.Fixture.FreedomGym.LlmAvatar do
  @moduledoc """
  Real fixture resource for the "Chicago AI" tier of the FreedomGym
  primitive (`test/ash_a2a_freedom_gym_llm_test.exs`): a participant avatar
  whose `:respond_to_prompt` action is backed by a REAL live LLM call
  (`AshAi.Actions.Prompt`, via `ReqLLM`, against Z.AI) rather than the
  deterministic Elixir logic in `freedom_gym_fixture.ex`'s four Chicago-Core
  avatars.

  Formerly Groq-backed; swapped 2026-09 per explicit request to replace
  this repo's Groq usage with Z.AI. This makes it a near-duplicate of
  `ZaiLlmAvatar` below (same provider, same model) -- kept as its own
  module rather than merged/deleted since only conversion, not
  consolidation, was asked for; worth revisiting whether one of the two
  should be removed.

  This is deliberately a separate resource/avatar/test from Chicago-Core --
  Chicago-Core stays exact-output-assertable and CI-safe (no network, no
  API key, no non-determinism); this one is real environmental variation
  (per-Sean's "LLM = environmental variation generator, not oracle"
  framing): the model decides the actual wording/topic, the action's own
  Ash return-type contract constrains it to a real structured shape, and
  callers assert invariants over that structure -- never exact text.

  No mock: no `ReqLLM` stub, no canned HTTP response. `ZAI_API_KEY` is read
  directly from the OS environment by `req_llm`'s `zai_coder` provider --
  no key is echoed, typed into a form, or otherwise handled by this code;
  it flows straight from env var to the HTTP client.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.FreedomGym.LlmAvatarDomain,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshA2A, AshAi]

  actions do
    action :respond_to_prompt, :map do
      argument(:phase, :atom, allow_nil?: false)
      argument(:prompt_text, :string, allow_nil?: false)

      constraints(
        fields: [
          wants_to_speak?: [type: :boolean, allow_nil?: false],
          topic: [type: :string, allow_nil?: true],
          asks_for_help?: [type: :boolean, allow_nil?: false]
        ]
      )

      run(
        prompt(
          "zai_coder:glm-5.3-flash",
          prompt: {
            """
            You are simulating one participant avatar in a Chicago-style
            (deterministic-scaffold, real-LLM-content) integration test for
            a peer support meeting facilitation system. Stay in character
            as a person attending the meeting. Respond only with the
            requested structured fields -- no extra commentary.
            """,
            """
            Current meeting phase: <%= @input.arguments.phase %>
            Facilitator prompt: <%= @input.arguments.prompt_text %>

            Decide: do you want to speak right now (wants_to_speak?), what
            real, specific topic would you raise (topic, a short phrase, or
            omit if you would not speak), and are you asking the group for
            help with something (asks_for_help?).
            """
          },
          # Z.AI's `:zai_coder` provider errors on an out-of-range default
          # max_tokens ("The max_tokens parameter is illegal") -- a real
          # 400 hit and fixed against the live API, not guessed (see
          # `ZaiLlmAvatar` below, where this was first diagnosed).
          req_llm_opts: [max_tokens: 4096]
        )
      )
    end
  end

  a2a do
    skill(:respond_to_prompt, :respond_to_prompt)
  end
end

defmodule AshA2A.Test.Fixture.FreedomGym.LlmAvatarDomain do
  @moduledoc "Real fixture domain for `AshA2A.Test.Fixture.FreedomGym.LlmAvatar`."

  use Ash.Domain

  resources do
    resource(AshA2A.Test.Fixture.FreedomGym.LlmAvatar)
  end
end

defmodule AshA2A.Test.Fixture.FreedomGym.LlmAvatarAgent do
  @moduledoc """
  Real `A2A.Agent` for `AshA2A.Test.Fixture.FreedomGym.LlmAvatar`, standing
  in for "the LLM-backed participant's own independently-deployed Ash app."
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.FreedomGym.LlmAvatar,
    name: "freedom_gym_llm_avatar_agent"
end

defmodule AshA2A.Test.Fixture.FreedomGym.ZaiLlmAvatar do
  @moduledoc """
  Same "Chicago AI" avatar contract as `LlmAvatar` (both are now Z.AI-backed
  after `LlmAvatar`'s 2026-09 Groq->Z.AI conversion -- functionally
  redundant with each other; kept separate since only conversion, not
  consolidation, was asked for). Backed by a REAL live call to Z.AI's GLM
  coding-plan endpoint (`req_llm`'s native `:zai_coder` provider).

  `Z_AI_API_KEY` lives in `~/.env` (not necessarily the process
  environment), under a name that doesn't match `req_llm`'s `zai_coder`
  provider's expected `ZAI_API_KEY`/`:zai_coder_api_key` lookup (see
  `ReqLLM.Keys`) -- so `test/ash_a2a_freedom_gym_zai_test.exs` reads the
  real key from `~/.env` once, at test setup, and sets it via
  `Application.put_env(:req_llm, :zai_coder_api_key, key)` (ReqLLM.Keys'
  documented `:application` precedence tier). No key is echoed, typed into
  a form, or handled by this resource module itself.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.FreedomGym.ZaiLlmAvatarDomain,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshA2A, AshAi]

  actions do
    action :respond_to_prompt, :map do
      argument(:phase, :atom, allow_nil?: false)
      argument(:prompt_text, :string, allow_nil?: false)

      constraints(
        fields: [
          wants_to_speak?: [type: :boolean, allow_nil?: false],
          topic: [type: :string, allow_nil?: true],
          asks_for_help?: [type: :boolean, allow_nil?: false]
        ]
      )

      run(
        prompt(
          "zai_coder:glm-4.5-flash",
          prompt: {
            """
            You are simulating one participant avatar in a Chicago-style
            (deterministic-scaffold, real-LLM-content) integration test for
            a peer support meeting facilitation system. Stay in character
            as a person attending the meeting. Respond only with the
            requested structured fields -- no extra commentary.
            """,
            """
            Current meeting phase: <%= @input.arguments.phase %>
            Facilitator prompt: <%= @input.arguments.prompt_text %>

            Decide: do you want to speak right now (wants_to_speak?), what
            real, specific topic would you raise (topic, a short phrase, or
            omit if you would not speak), and are you asking the group for
            help with something (asks_for_help?).
            """
          },
          # Z.AI's `:zai_coder` provider errors on an out-of-range default
          # max_tokens ("The max_tokens parameter is illegal") -- a real
          # 400 hit and fixed against the live API, not guessed.
          req_llm_opts: [max_tokens: 4096]
        )
      )
    end
  end

  a2a do
    skill(:respond_to_prompt, :respond_to_prompt)
  end
end

defmodule AshA2A.Test.Fixture.FreedomGym.ZaiLlmAvatarDomain do
  @moduledoc "Real fixture domain for `AshA2A.Test.Fixture.FreedomGym.ZaiLlmAvatar`."

  use Ash.Domain

  resources do
    resource(AshA2A.Test.Fixture.FreedomGym.ZaiLlmAvatar)
  end
end

defmodule AshA2A.Test.Fixture.FreedomGym.ZaiLlmAvatarAgent do
  @moduledoc """
  Real `A2A.Agent` for `AshA2A.Test.Fixture.FreedomGym.ZaiLlmAvatar`,
  standing in for "the Z.AI-backed participant's own
  independently-deployed Ash app."
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.FreedomGym.ZaiLlmAvatar,
    name: "freedom_gym_zai_llm_avatar_agent"
end
