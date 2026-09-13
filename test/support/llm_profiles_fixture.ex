defmodule AshA2A.Test.Fixture.SemanticReasoner do
  @moduledoc """
  Real fixture proving `AshA2A.LLMProfiles`: this action's source names no
  provider or model -- only the role `:semantic_reasoner`, resolved at
  runtime via `AshA2A.LLMProfiles.model_spec!/1` /
  `AshA2A.LLMProfiles.req_llm_opts!/1` (config in `config/test.exs`). A
  real, live LLM call is still made (whichever provider the role currently
  resolves to) -- this fixture is deliberately separate from
  `freedom_gym_llm_fixture.ex`'s `LlmAvatar`/`ZaiLlmAvatar`, which stay
  hardcoded on purpose as direct provider evidence.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.SemanticReasonerDomain,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshA2A, AshAi]

  actions do
    action :respond_to_prompt, :map do
      argument(:prompt_text, :string, allow_nil?: false)

      constraints(
        fields: [
          answer: [type: :string, allow_nil?: false]
        ]
      )

      run(
        prompt(
          AshA2A.LLMProfiles.model_spec!(:semantic_reasoner),
          prompt: {
            "You are a semantic reasoner. Answer in one short sentence.",
            "<%= @input.arguments.prompt_text %>"
          },
          req_llm_opts: AshA2A.LLMProfiles.req_llm_opts!(:semantic_reasoner)
        )
      )
    end
  end

  a2a do
    skill(:respond_to_prompt, :respond_to_prompt)
  end
end

defmodule AshA2A.Test.Fixture.SemanticReasonerDomain do
  @moduledoc "Real fixture domain for `AshA2A.Test.Fixture.SemanticReasoner`."

  use Ash.Domain

  resources do
    resource(AshA2A.Test.Fixture.SemanticReasoner)
  end
end

defmodule AshA2A.Test.Fixture.SemanticReasonerAgent do
  @moduledoc """
  Real `A2A.Agent` for `AshA2A.Test.Fixture.SemanticReasoner`.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.SemanticReasoner,
    name: "semantic_reasoner_agent"
end
