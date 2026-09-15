defmodule AshA2A.Planning.RequestRouterLLMNeverCalledTest do
  @moduledoc """
  Dedicated, standalone, permanently re-runnable structural proof closing
  the "by default" claim of impossible-item #2's default request router:
  a real typed-facts (`goal_facts`) request submitted through
  `AshA2A.Planning.RequestRouter.route/3` never invokes the LLM path, by
  default or otherwise.

  This is deliberately split out of `request_router_test.exs` (which
  covers general tier-detection and wiring) so this specific proof stands
  on its own as a citable, individually re-runnable artifact -- not one
  assertion among many in a broader coverage file.

  ## Mechanism (real, not code-inspection)

  `AshA2A.Semantic.Compiler.compile_source/3` is the sole call site in
  this codebase that can invoke the real LLM: it defaults `:generate_object`
  to the real `&ReqLLM.generate_object/4` (`lib/ash_a2a/semantic/compiler.ex`)
  and calls whatever function is bound to that key as the very first step
  of its `with` pipeline, unconditionally, before any admission/ontology/
  planning logic runs. That key -- and its planning-time sibling
  `:plan_generate_object` -- are real 4-arity dependency-injection seams
  documented on `Compiler`'s own moduledoc, not a call into any mocking
  library.

  Test 1 (the closing proof) binds `:generate_object` and
  `:plan_generate_object` to real anonymous functions that unconditionally
  `raise` on invocation, then routes a real typed-facts `A2A.Message.t()`
  through `RequestRouter.route/3` using the exact same `opts` keyword list
  the router would forward to `Compiler.compile_source/3` if (and only if)
  a future regression made the facts tier fall through to the text/LLM
  tier. The call returns real `{:ok, %ExecutionPackage{}}` success. A real
  crash -- an uncaught `RuntimeError` propagating out of `route/3` and
  failing this test loudly -- is what a regression would produce; its
  absence is real, executed evidence of non-invocation, not an assertion
  taken on the code's word.

  Test 2 is the adversarial completeness check this idiom needs to avoid
  being vacuously true: it proves the exact same raising functions, passed
  the exact same way, DO raise when the router's *text* tier is the one
  exercised instead. Without this companion test, test 1 could pass for
  the wrong reason (a typo'd option key, a function that silently swallows
  its own raise, a routing bug that never calls the functions at all
  regardless of tier) and nobody would notice. Test 2 closes that gap by
  making the raise fire for real, on this exact codepath, at least once.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Planning.RequestRouter
  alias AshA2A.Semantic.ExecutionPackage
  alias AshA2A.Test.Fixture.HddlDeterministicFixture

  @advance_id "AshA2A.Test.Fixture.HddlDeterministicFixture.advance"
  @unlock_id "AshA2A.Test.Fixture.HddlDeterministicFixture.unlock"

  defp goal_facts_envelope do
    %{
      "request_id" => "llm-never-called-test-#{System.unique_integer([:positive])}",
      "domain_name" => "llm-never-called-test-domain",
      "problem_name" => "llm-never-called-test-problem",
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

  defp facts_message(envelope) do
    A2A.Message.new_user([A2A.Part.Data.new(%{"goal_facts" => envelope})])
  end

  defp text_message(text) do
    A2A.Message.new_user(text)
  end

  defp raise_on_call(label) do
    fn _model_spec, _prompt, _schema, _llm_opts ->
      raise "structural non-invocation proof violated: #{label} was invoked"
    end
  end

  test "a real typed-facts request through the router never invokes the LLM path, by default" do
    envelope = goal_facts_envelope()

    assert {:ok, %ExecutionPackage{} = package} =
             RequestRouter.route(HddlDeterministicFixture, facts_message(envelope),
               generate_object: raise_on_call("generate_object"),
               plan_generate_object: raise_on_call("plan_generate_object")
             )

    # Real success, real solver-produced plan -- not a stub, not an
    # inspection claim. If the facts tier had reached
    # `Compiler.compile_source/3` (the LLM path's sole entry point) via
    # these same opts, one of the two injected functions above would have
    # raised and this test would have failed loudly instead.
    assert package.standing == :candidate
    assert package.authority == :none
    assert package.plan_candidate.capability_ids == [@advance_id, @unlock_id]
  end

  test "adversarial completeness: the same injected functions genuinely raise on the LLM path they guard" do
    text = "The goal is to advance and unlock the gate."

    assert_raise RuntimeError, ~r/generate_object was invoked/, fn ->
      RequestRouter.route(HddlDeterministicFixture, text_message(text),
        generate_object: raise_on_call("generate_object"),
        plan_generate_object: raise_on_call("plan_generate_object")
      )
    end
  end
end
