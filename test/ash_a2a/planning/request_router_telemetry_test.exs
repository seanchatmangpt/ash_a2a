defmodule AshA2A.Planning.RequestRouterTelemetryTest do
  @moduledoc """
  Real, Chicago-style coverage for task 4's telemetry instrumentation: a
  real `[:ash_a2a, :router, :tier_selected]` event fires at both of
  `AshA2A.Planning.RequestRouter.route/3`'s real branch points -- the
  facts (deterministic) tier and the text (LLM) tier -- and a real
  `AshA2A.Telemetry.RouterCounters` instance attached to that event
  increments the correct slot under real dispatch through the router.

  This is the concrete, buildable answer to impossible-item #6: this
  codebase cannot know a real Fortune-5 deployment's actual
  deterministic-vs-LLM request split, but it can build, and this test
  proves working, the real in-process instrument that would measure it.

  Real collaborators throughout, no test doubles: a real `:telemetry.attach/4`
  handler forwarding to `self()` (the same pattern
  `test/ash_a2a_cancel_inflight_test.exs` already uses for
  `[:ash_a2a, :agent, :cancel]`), a real compiled fixture resource
  (`AshA2A.Test.Fixture.HddlDeterministicFixture`), a real facts-tier
  dispatch through the real deterministic solver subprocess
  (`AshA2A.Planning.HddlDeterministicSynthesis.synthesize/3` ->
  `native/hddl_cli`), and a real text-tier dispatch through the real
  `AshA2A.Semantic.Compiler.compile_source/3` pipeline (with the same
  `:generate_object`/`:plan_generate_object` dependency-injection seam
  `request_router_test.exs` already uses standing in for the live network
  LLM call -- no network I/O). The real repo-wide banned-pattern sweep
  (`grep -rn "Mock\\|mox\\|patch("`, zero matches over this file) is part
  of this task's own reported verification evidence, not asserted here.

  `async: false` deliberately: `[:ash_a2a, :router, :tier_selected]` is a
  real, global `:telemetry` event name, and `RouterCounters.counts/1`
  asserts *exact* values below. ExUnit runs every `async: true` module
  concurrently in one phase, then every `async: false` module serially,
  strictly after that phase completes (see `ExUnit.Case`'s own documented
  scheduling) -- marking this module `async: false` is what makes "no
  other test process's `route/3` call fires into these same handlers
  while this module's exact-count assertions run" a real guarantee rather
  than an assumption. `request_router_test.exs` and
  `request_router_llm_never_called_test.exs` (both `async: true`) are
  therefore guaranteed to have already finished before this module starts.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Planning.RequestRouter
  alias AshA2A.Semantic.IR
  alias AshA2A.Telemetry.RouterCounters
  alias AshA2A.Test.Fixture.HddlDeterministicFixture

  @advance_id "AshA2A.Test.Fixture.HddlDeterministicFixture.advance"
  @unlock_id "AshA2A.Test.Fixture.HddlDeterministicFixture.unlock"

  defp goal_facts_envelope do
    %{
      "request_id" => "router-telemetry-test-#{System.unique_integer([:positive])}",
      "domain_name" => "router-telemetry-test-domain",
      "problem_name" => "router-telemetry-test-problem",
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

  # A real, fixed-response `:generate_object` seam function (schema-valid
  # extraction output, `source_quote` a verbatim substring of `text` so
  # `Admission.admit/2`'s real grounding check passes) -- identical to
  # `request_router_test.exs`'s own helper.
  defp fixed_extraction(text) do
    fn _model_spec, _prompt, _schema, _llm_opts ->
      {:ok,
       IR.fields()
       |> Map.new(&{Atom.to_string(&1), []})
       |> Map.put("authority", "none")
       |> Map.put("goals", [
         %{
           "id" => "advance-and-unlock",
           "kind" => "goal",
           "description" => "advance and unlock the gate",
           "source_quote" => text
         }
       ])}
    end
  end

  defp fixed_plan(request_id) do
    fn _model_spec, _prompt, _schema, _llm_opts ->
      {:ok,
       %{
         "request_id" => request_id,
         "authority" => "none",
         "capability_ids" => [@advance_id, @unlock_id],
         "hddl" => "(:task advance-and-unlock)",
         "fond" => "(:policy observe-or-replan)"
       }}
    end
  end

  defp route_text_tier!(text) do
    request_id = "router-telemetry-text-#{System.unique_integer([:positive])}"

    RequestRouter.route(HddlDeterministicFixture, text_message(text),
      generate_object: fixed_extraction(text),
      plan_generate_object: fixed_plan(request_id)
    )
  end

  describe "[:ash_a2a, :router, :tier_selected] telemetry" do
    test "fires with tier: :facts at the facts branch point, tier: :text at the text branch point" do
      handler_id = {__MODULE__, make_ref()}
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:ash_a2a, :router, :tier_selected],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:ash_a2a_router_telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, _package} =
               RequestRouter.route(HddlDeterministicFixture, facts_message(goal_facts_envelope()))

      assert_receive {:ash_a2a_router_telemetry, %{}, facts_metadata}
      assert facts_metadata.tier == :facts
      assert facts_metadata.resource_or_domain == HddlDeterministicFixture

      assert {:ok, _package} = route_text_tier!("The goal is to advance and unlock the gate.")

      assert_receive {:ash_a2a_router_telemetry, %{}, text_metadata}
      assert text_metadata.tier == :text
      assert text_metadata.resource_or_domain == HddlDeterministicFixture
    end

    test "never fires on the fail-closed no-input branch" do
      handler_id = {__MODULE__, make_ref()}
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:ash_a2a, :router, :tier_selected],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:ash_a2a_router_telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      no_input_message = A2A.Message.new_user([A2A.Part.Data.new(%{"unrelated_key" => "value"})])

      assert {:error, %{code: :request_router_missing_input}} =
               RequestRouter.route(HddlDeterministicFixture, no_input_message)

      refute_receive {:ash_a2a_router_telemetry, _measurements, _metadata}, 50
    end
  end

  describe "AshA2A.Telemetry.RouterCounters" do
    test "increments the deterministic slot for a real facts-tier dispatch, the llm slot for a real text-tier dispatch" do
      ref = RouterCounters.new()
      handler_id = RouterCounters.attach!(ref)
      on_exit(fn -> RouterCounters.detach(handler_id) end)

      assert RouterCounters.counts(ref) == %{deterministic: 0, llm: 0}

      assert {:ok, _} =
               RequestRouter.route(HddlDeterministicFixture, facts_message(goal_facts_envelope()))

      assert {:ok, _} =
               RequestRouter.route(HddlDeterministicFixture, facts_message(goal_facts_envelope()))

      assert {:ok, _} = route_text_tier!("The goal is to advance and unlock the gate.")

      assert RouterCounters.counts(ref) == %{deterministic: 2, llm: 1}
    end

    test "two independently-attached instances never interfere with each other's counts" do
      ref_a = RouterCounters.new()
      ref_b = RouterCounters.new()
      handler_a = RouterCounters.attach!(ref_a)
      handler_b = RouterCounters.attach!(ref_b)
      on_exit(fn -> RouterCounters.detach(handler_a) end)
      on_exit(fn -> RouterCounters.detach(handler_b) end)

      assert {:ok, _} =
               RequestRouter.route(HddlDeterministicFixture, facts_message(goal_facts_envelope()))

      assert {:ok, _} = route_text_tier!("The goal is to advance and unlock the gate.")

      assert RouterCounters.counts(ref_a) == %{deterministic: 1, llm: 1}
      assert RouterCounters.counts(ref_b) == %{deterministic: 1, llm: 1}
    end

    test "an unattached, freshly-created reference never observes events from a real dispatch" do
      unattached_ref = RouterCounters.new()

      assert {:ok, _} =
               RequestRouter.route(HddlDeterministicFixture, facts_message(goal_facts_envelope()))

      assert RouterCounters.counts(unattached_ref) == %{deterministic: 0, llm: 0}
    end
  end
end
