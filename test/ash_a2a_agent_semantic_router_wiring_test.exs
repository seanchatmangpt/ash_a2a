defmodule AshA2A.Test.Fixture.SemanticRouterWired.Resource do
  @moduledoc """
  Real fixture resource, private to this test file: the SAME two-action
  deterministic HDDL domain shape as
  `AshA2A.Test.Fixture.HddlDeterministicFixture` (`test/support/fixture.ex`
  -- `:advance`/`:unlock`, each with one real `hddl_operator` block) PLUS
  `semantic_requests(true)`, which `HddlDeterministicFixture` deliberately
  does not declare (it is shared by many other test files that assume the
  ordinary skill-resolution surface only). A new, file-local resource
  avoids touching that shared fixture while still exercising the exact
  real deterministic solver path (`AshA2A.Planning.HddlDeterministicSynthesis
  .synthesize/3`, via a real OS subprocess call to `native/hddl_cli`) a
  `goal_facts` message routed through this task's new
  `AshA2A.Agent.dispatch_semantic_goal_facts/2` wiring actually reaches.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.SemanticRouterWired.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])

    action :advance, :string do
      argument(:from, :string, allow_nil?: false)
      argument(:to, :string, allow_nil?: false)

      run(fn _input, _context -> {:ok, "ok"} end)
    end

    action :unlock, :string do
      argument(:who, :string, allow_nil?: false)

      run(fn _input, _context -> {:ok, "ok"} end)
    end
  end

  a2a do
    semantic_requests(true)

    skill :advance, :advance do
      hddl_operator do
        parameters([:from, :to])
        preconditions([{:current_phase, [:from]}])
        add_effects([{:current_phase, [:to]}])
        delete_effects([{:current_phase, [:from]}])
      end
    end

    skill :unlock, :unlock do
      hddl_operator do
        parameters([:who])
        preconditions([{:current_phase, [:who]}])
        add_effects([{:has_key, [:who]}])
      end
    end
  end
end

defmodule AshA2A.Test.Fixture.SemanticRouterWired.Domain do
  @moduledoc "Real fixture domain for `SemanticRouterWired.Resource` above."

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.Test.Fixture.SemanticRouterWired.Resource)
  end
end

defmodule AshA2A.Test.Fixture.SemanticRouterWiredAgent do
  @moduledoc "Real `A2A.Agent` GenServer over `SemanticRouterWired.Resource` above."

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.SemanticRouterWired.Resource,
    name: "semantic_router_wired_agent"
end

defmodule AshA2AAgentSemanticRouterWiringTest do
  @moduledoc """
  v26.9.16 (`docs/jira/v26.9.16/PRFAQ.md` item 1) real, Chicago-style
  end-to-end coverage for the new production call site: a real dispatch
  through the real, supervised `A2A.Agent` process
  (`AshA2AAgentSemanticRouterWiringTest`'s own `SemanticRouterWiredAgent`)
  now reaches `AshA2A.Planning.RequestRouter` for real, not just in
  `RequestRouter`'s own dedicated unit/structural tests. No Mock/mox/patch/
  monkeypatch anywhere in this file.

  Four falsifiers, matching this task's own required verification bar:

    1. A real `goal_facts` message dispatched through the real top-level
       Agent entry point produces a real, solver-synthesized
       `ExecutionPackage` reply (`standing: "candidate"`,
       `authority: "none"`, the expected `capability_ids`) -- not asserted
       from reading the code, but from the actual returned `A2A.Task`.
    2. The wired agent-level `goal_facts` path structurally never reaches
       the LLM seam. `request_router_llm_never_called_test.exs`'s own
       `raise_on_call/1` idiom injects a raising function via
       `RequestRouter.route/3`'s `:generate_object`/`:plan_generate_object`
       opts -- a seam this task's `dispatch_semantic_goal_facts/2`
       deliberately does NOT thread from the agent entry point (per this
       task's required design, it calls `RequestRouter.route(resource_or_domain,
       message)` with no opts, mirroring `dispatch_semantic_compile/2`'s own
       no-opts call to `Compiler.compile/2`), so there is no opts-based seam
       to inject *through* the agent path. Instead, this test reuses
       `AshA2A.Telemetry.RouterCounters` -- the real, already-shipped
       production instrument this exact router already emits
       `[:ash_a2a, :router, :tier_selected]` events for (task 4 of
       `RequestRouter`'s own build) -- attached for real, around a real
       agent-level dispatch: a `goal_facts` message must increment the real
       `deterministic` counter by exactly 1 and leave the real `llm` counter
       at 0. Since `RequestRouter.route/3`'s facts branch (`synthesize/3`)
       never calls `Compiler.compile_source/3` under any opts (proven
       separately, structurally, by
       `request_router_llm_never_called_test.exs`), an `llm` count of 0
       here is real, executed evidence that this specific dispatch never
       reached the LLM tier -- not an assertion taken on the router's word.
    3. An existing non-`goal_facts` semantic request still reaches the
       unchanged `dispatch_semantic_compile/2` path, in both of its real
       sub-cases: no usable input at all (`detect_tier/1` returns `:error`,
       fast, no network -- part of the default `mix test` run), and real
       text present (`detect_tier/1` returns `{:text, _}`, tagged
       `:external_api` like this repo's own established convention for a
       real, unseamed LLM round-trip, since `dispatch_semantic_compile/2`
       has no `generate_object` DI seam threaded from this call site
       either -- kept real/unseamed-at-the-solver-level rather than
       inventing a new seam this task's design does not call for).
    4. An invalid (non-map) `goal_facts` value fails closed with
       `:invalid_goal_facts` through the full wired agent-level path.
  """

  use ExUnit.Case, async: false

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Telemetry.RouterCounters
  alias AshA2A.Test.Fixture.SemanticRouterWiredAgent

  @advance_id "AshA2A.Test.Fixture.SemanticRouterWired.Resource.advance"
  @unlock_id "AshA2A.Test.Fixture.SemanticRouterWired.Resource.unlock"

  setup do
    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        SemanticRouterWiredAgent
      ])

    :ok
  end

  defp goal_facts_envelope do
    %{
      "request_id" => "router-wiring-test-#{System.unique_integer([:positive])}",
      "domain_name" => "router-wiring-test-domain",
      "problem_name" => "router-wiring-test-problem",
      "objects" => ["on", "off"],
      "init" => [%{"predicate" => "current_phase", "args" => ["on"]}],
      "goal" => [
        %{"predicate" => "current_phase", "args" => ["off"]},
        %{"predicate" => "has_key", "args" => ["off"]}
      ],
      "task_sequence" => [
        %{"capability_id" => @advance_id, "args" => ["on", "off"]},
        %{"capability_id" => @unlock_id, "args" => ["off"]}
      ]
    }
  end

  defp goal_facts_message(envelope) do
    data_message(%{"goal_facts" => envelope}, %{metadata: %{semantic_request: true}})
  end

  test "1: a real goal_facts message reaches the real deterministic router tier through the real Agent entry point" do
    message = goal_facts_message(goal_facts_envelope())

    assert {:ok, task} = SemanticRouterWiredAgent.call(SemanticRouterWiredAgent, message)
    assert task.status.state == :completed
    assert [%A2A.Artifact{parts: [%A2A.Part.Data{data: body}]}] = task.artifacts

    # Real, solver-synthesized reply body (`ExecutionPackage.to_reply/1`) --
    # never `standing: "candidate"`/`authority: "none"` by construction
    # unless a real `ExecutionPackage.new/6` fenced it that way.
    assert body["standing"] == "candidate"
    assert body["authority"] == "none"
    assert body["capability_ids"] == [@advance_id, @unlock_id]
    assert is_binary(body["hddl"])
  end

  test "2: the wired agent-level goal_facts path never reaches the LLM seam (real RouterCounters falsifier)" do
    ref = RouterCounters.new()
    handler_id = RouterCounters.attach!(ref)
    on_exit(fn -> RouterCounters.detach(handler_id) end)

    message = goal_facts_message(goal_facts_envelope())

    assert {:ok, task} = SemanticRouterWiredAgent.call(SemanticRouterWiredAgent, message)
    assert task.status.state == :completed

    # Real, executed evidence: the router's own real telemetry, emitted
    # from inside `RequestRouter.route/3` itself, right before it delegates
    # to whichever real downstream tier it selected -- a regression that
    # silently routed this goal_facts dispatch to the LLM tier would show
    # up here as `llm: 1`, not as a silent pass.
    assert RouterCounters.counts(ref) == %{deterministic: 1, llm: 0, phrase: 0}
  end

  test "3a: no goal_facts and no text still falls through to dispatch_semantic_compile/2's unchanged typed refusal (no network)" do
    message = data_message(%{}, %{metadata: %{semantic_request: true}})

    assert {:ok, task} = SemanticRouterWiredAgent.call(SemanticRouterWiredAgent, message)
    assert task.status.state == :failed
    assert A2A.Message.text(task.status.message) =~ "semantic_request_missing_text"
  end

  # Mirrors `ash_a2a_agent_semantic_request_test.exs`'s own established
  # "both gates true" convention for exercising the real, unseamed LLM
  # round-trip: no `generate_object` DI seam exists at this call site
  # (`dispatch_semantic_compile/2` calls `Compiler.compile/2` with no
  # opts, unchanged by this task), so this is a real network attempt
  # against the real `:semantic_reasoner` profile `config/test.exs`
  # configures -- tagged `:external_api` and excluded from the default
  # `mix test` run (`test/test_helper.exs`), consistent with this repo's
  # own established convention for this exact scenario.
  @tag :external_api
  @tag timeout: 180_000
  test "3b: real text with no goal_facts key still falls through to dispatch_semantic_compile/2 (real, unseamed LLM path)" do
    message =
      data_message(%{}, %{metadata: %{semantic_request: true}})
      |> Map.put(:parts, [A2A.Part.Text.new("advance the admitted workflow")])

    assert {:ok, task} =
             SemanticRouterWiredAgent.call(SemanticRouterWiredAgent, message, timeout: 170_000)

    # Real network round-trip through the real, unmodified
    # `dispatch_semantic_compile/2` -- fails closed (typed refusal, not a
    # crash) in this environment exactly like the pre-existing "both gates
    # true" test does, which is the point: the router-wiring diff changed
    # *how* this message got here (`detect_tier/1`'s `{:text, _}` branch,
    # not a direct call), never *what* happens once it arrives.
    assert task.status.state == :failed

    assert {:ok, _still_alive_task} =
             SemanticRouterWiredAgent.call(SemanticRouterWiredAgent, data_message(%{}))
  end

  test "4: an invalid (non-map) goal_facts value fails closed with :invalid_goal_facts through the full wired path" do
    message = goal_facts_message("not a map")

    assert {:ok, task} = SemanticRouterWiredAgent.call(SemanticRouterWiredAgent, message)
    assert task.status.state == :failed
    assert A2A.Message.text(task.status.message) =~ "invalid_goal_facts"
  end
end
