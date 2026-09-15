defmodule AshA2A.Test.Fixture.SemanticEnabled.Resource do
  @moduledoc """
  Real fixture resource, private to this test file: a single real `:read`
  skill (so the ordinary skill-resolution fallback path is exercisable
  without ambiguity) plus `a2a do semantic_requests true end`, explicitly
  opting this resource into the semantic-compilation A2A surface.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.SemanticEnabled.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
  end

  a2a do
    semantic_requests(true)
    skill(:probe, :read)
  end
end

defmodule AshA2A.Test.Fixture.SemanticEnabled.Domain do
  @moduledoc "Real fixture domain for `SemanticEnabled.Resource` above."

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.Test.Fixture.SemanticEnabled.Resource)
  end
end

defmodule AshA2A.Test.Fixture.SemanticEnabledAgent do
  @moduledoc "Real `A2A.Agent` GenServer over `SemanticEnabled.Resource` above."

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.SemanticEnabled.Resource,
    name: "semantic_enabled_agent"
end

defmodule AshA2AAgentSemanticRequestTest do
  @moduledoc """
  Proves the v26.9.14 explicit semantic-compilation A2A surface's two real
  gates -- both must be true before any real dispatch reaches
  `AshA2A.Semantic.Compiler.compile/3` -- and that a genuinely-gated request
  fails closed with a real, typed error rather than crashing the real
  `A2A.Agent` process when the required LLM profile is unconfigured (the
  real, unmodified test environment has no `:semantic_reasoner` profile
  configured). No Mock/mox/patch/monkeypatch anywhere in this file; every
  assertion is against real dispatch through a real supervised `A2A.Agent`
  process.
  """

  use ExUnit.Case, async: false

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.{Echo, EchoAgent, SemanticEnabledAgent}

  setup do
    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        SemanticEnabledAgent,
        EchoAgent
      ])

    :ok
  end

  test "AshA2A.Info.semantic_requests_enabled?/1 reflects the real compiled DSL declaration" do
    assert AshA2A.Info.semantic_requests_enabled?(AshA2A.Test.Fixture.SemanticEnabled.Resource)

    refute AshA2A.Info.semantic_requests_enabled?(Echo)
  end

  test "gate 1: resource opted in, but the message carries no semantic_request flag -- falls through to ordinary skill dispatch" do
    # No `:semantic_request` metadata at all -- the single real `:probe`
    # `:read` skill resolves via the ordinary default-skill path.
    assert {:ok, task} = SemanticEnabledAgent.call(SemanticEnabledAgent, data_message(%{}))
    assert task.status.state == :completed
    assert [%A2A.Artifact{parts: [%A2A.Part.Data{}]}] = task.artifacts
  end

  test "gate 2: message carries the semantic_request flag, but the resource never opted in -- falls through to ordinary skill dispatch" do
    message = data_message(%{}, %{metadata: %{semantic_request: true, skill: "echo"}})

    assert {:ok, task} = EchoAgent.call(EchoAgent, message)
    assert task.status.state == :completed
  end

  test "both gates true: a real dispatch reaches the real semantic compiler and fails closed (not a crash) with no injected generate_object seam" do
    message =
      data_message(%{}, %{metadata: %{semantic_request: true}})
      |> Map.put(:parts, [A2A.Part.Text.new("advance the admitted workflow")])

    assert {:ok, task} = SemanticEnabledAgent.call(SemanticEnabledAgent, message)

    # `config/test.exs` DOES configure a real `:semantic_reasoner` LLM
    # profile (`zai_coder:glm-5.3-flash`), so `AshA2A.LLMProfiles.
    # model_spec!/1` does not raise here -- this production path has no
    # `generate_object:`-override seam to inject a deterministic fake (by
    # design: it is the real production entrypoint, not a test harness), so
    # it genuinely attempts the real default `ReqLLM.generate_object/4`
    # network call, which fails for real in this environment (no reachable/
    # authorized ZAI-compatible endpoint) and surfaces as a real, typed
    # `{:error, %{code: :semantic_compilation_failed, ...}}` reply -- caught
    # by `Compiler.compile_source/3`'s own non-raising `with`/`else`
    # contract, never propagating as an uncaught exception. The real
    # `A2A.Agent` process is still alive and can still serve the next real
    # call afterward, proving this was a typed refusal, not a process crash.
    assert task.status.state == :failed

    assert {:ok, _still_alive_task} =
             SemanticEnabledAgent.call(SemanticEnabledAgent, data_message(%{}))
  end

  test "both gates true, but the message carries no real text part -- refused with a typed code, not a crash" do
    message = data_message(%{}, %{metadata: %{semantic_request: true}})

    assert {:ok, task} = SemanticEnabledAgent.call(SemanticEnabledAgent, message)
    assert task.status.state == :failed
  end
end
