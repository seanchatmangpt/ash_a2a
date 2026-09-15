defmodule AshA2ALLMProfilesTest do
  @moduledoc """
  Real, live proof that `AshA2A.LLMProfiles` role-based resolution works
  end to end: `AshA2A.Test.Fixture.SemanticReasoner`'s action source names
  only the role `:semantic_reasoner`, real config
  (`config/test.exs`) resolves it to a real provider, and a real live A2A
  dispatch makes a real call through that resolved provider.

  Named, visible skip when `ZAI_API_KEY` is absent from `~/.env` (the role
  currently resolves to `zai_coder` in this repo's config) -- never a
  silent mock substitution.
  """

  use ExUnit.Case, async: true

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.SemanticReasonerAgent

  @zai_key AshA2A.Test.EnvKeyFixture.read_key("ZAI_API_KEY")

  @moduletag :external_api
  @describetag skip: is_nil(@zai_key) && "ZAI_API_KEY not found in ~/.env"

  setup_all do
    if @zai_key do
      Application.put_env(:req_llm, :zai_coder_api_key, @zai_key)
    end

    :ok
  end

  test "AshA2A.LLMProfiles.model_spec!/1 resolves the real configured provider" do
    assert AshA2A.LLMProfiles.model_spec!(:semantic_reasoner) == "zai_coder:glm-5.3-flash"
    assert AshA2A.LLMProfiles.req_llm_opts!(:semantic_reasoner) == [max_tokens: 4096]
  end

  test "an unconfigured role fails closed with a real, named ArgumentError" do
    assert_raise ArgumentError, ~r/no LLM profile configured for role :nonexistent_role/, fn ->
      AshA2A.LLMProfiles.model_spec!(:nonexistent_role)
    end
  end

  # Real, disclosed interaction with
  # test/ash_a2a_zai_concurrency_ocel_test.exs's real 50-way concurrency
  # probe when the full suite runs with `--include external_api`: real
  # rate-limit exhaustion from that probe can make this real, unseamed live
  # LLM call exceed the default 60s on both the ExUnit test process and
  # A2A.Agent.call/3's own GenServer.call -- same fix as
  # test/ash_a2a_agent_semantic_request_test.exs, not a code defect.
  @tag timeout: 180_000
  test "a role-resolved action dispatches to a real live LLM call over real A2A" do
    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        SemanticReasonerAgent
      ])

    message = data_message(%{prompt_text: "What color is the sky on a clear day?"})

    assert {:ok, task} =
             SemanticReasonerAgent.call(SemanticReasonerAgent, message, timeout: 170_000)

    assert task.status.state == :completed

    assert [%A2A.Artifact{parts: [%A2A.Part.Data{data: %{answer: answer}}]}] = task.artifacts
    assert is_binary(answer)
    assert String.length(answer) > 0
  end
end
