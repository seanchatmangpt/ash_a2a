# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Telemetry.RouterCountersIsolationTest do
  @moduledoc """
  Real same-node caller-isolation coverage for
  `AshA2A.Telemetry.RouterCounters` (ticket b4p-f5-02 item 3).

  The stress wave (`test/ash_a2a/chicago/stress/multinode_concurrency_test.exs`,
  "Real defect found and deliberately not re-triggered") proved for real that
  two RouterCounters instances attached at once on one node cross-contaminate:
  `:telemetry.execute/3` broadcasts `[:ash_a2a, :router, :tier_selected]` to
  EVERY attached handler, so each instance's counts included the OTHER
  instance's dispatches, and an earlier draft of that file's per-batch exact
  counts assertion failed reproducibly
  (`batch 1/1 counts %{deterministic: 3, llm: 0, phrase: 1} do not exactly
  match the 2 facts-tier / 1 phrase-tier dispatches it drove`). That file
  pruned the concurrent-batch design to stay green; this file is the fix's
  own coverage: two concurrently-running router drivers, each with its own
  attached instance, asserting genuinely DISJOINT telemetry.

  The isolation mechanism is `attach!/3`'s `:owner` option -- the same
  design, semantics, and rationale `AshA2A.Telemetry.AllocationCounters`
  already shipped for the identical broadcast problem: `:any` (default)
  counts every emitter (the long-lived production instrument), a pid counts
  only events emitted by that process (a caller that attaches and routes in
  the same process owns a genuinely private measurement). A per-instance
  event-metadata token was considered and rejected: `route/3` would have to
  thread caller identity through its emitted metadata and opts, a wider
  public-API change with no in-repo precedent, while `:owner` closes the
  observed defect with the established pattern.

  `async: false` for the same reason `request_router_telemetry_test.exs`
  is: exact counts asserted against a real, global `:telemetry` event name;
  ExUnit's serial `async: false` phase is what makes "no other module's
  `route/3` fires into these handlers mid-assertion" a guarantee. The
  concurrency inside each test is this file's own `Task.async` drivers.

  Real collaborators throughout, zero mocks: real `:telemetry` attachment,
  real `RequestRouter.route/3` through the real deterministic solver
  (facts tier, `native/hddl_cli`) and the real caller-registered phrase
  template (phrase tier, zero LLM).
  """

  use ExUnit.Case, async: false

  alias AshA2A.Planning.RequestRouter
  alias AshA2A.Telemetry.RouterCounters
  alias AshA2A.Test.Fixture.HddlDeterministicFixture

  @advance_id "AshA2A.Test.Fixture.HddlDeterministicFixture.advance"
  @unlock_id "AshA2A.Test.Fixture.HddlDeterministicFixture.unlock"

  @phrase_regex ~r/^create a labeled item$/

  # Deliberate fallback, not sloppiness: on code WITHOUT `attach!/3`, this
  # degrades to the unscoped `attach!/1` so the exact-count assertions below
  # fail with the REAL contamination numbers (each ref inflated by the other
  # driver's dispatches) instead of an UndefinedFunctionError. The fail-before
  # run of this file is therefore a demonstration of the defect itself, not a
  # missing-API crash.
  defp attach_scoped!(ref) do
    if function_exported?(RouterCounters, :attach!, 3) do
      RouterCounters.attach!(ref, make_ref(), owner: self())
    else
      RouterCounters.attach!(ref)
    end
  end

  describe "per-pid instance isolation under same-node concurrency" do
    test "two concurrently-running router drivers' instances observe disjoint telemetry" do
      driver = fn driver_idx ->
        ref = RouterCounters.new()
        handler_id = attach_scoped!(ref)

        try do
          Enum.each(1..2, fn _ -> assert {:ok, _} = route_facts_tier!(driver_idx) end)
          assert {:ok, _} = route_phrase_tier!()

          RouterCounters.counts(ref)
        after
          RouterCounters.detach(handler_id)
        end
      end

      # Both drivers run genuinely concurrently, each attaching its own
      # instance first -- the exact shape the stress wave had to prune.
      task_a = Task.async(fn -> driver.(:a) end)
      task_b = Task.async(fn -> driver.(:b) end)
      counts_a = Task.await(task_a, 60_000)
      counts_b = Task.await(task_b, 60_000)

      # The assertion the stress wave could not make: each instance's counts
      # are EXACTLY its own dispatches (2 facts + 1 phrase) -- never the
      # union of both drivers' (which would read deterministic: 4, phrase: 2).
      assert counts_a == %{deterministic: 2, llm: 0, phrase: 1}
      assert counts_b == %{deterministic: 2, llm: 0, phrase: 1}
    end

    test "a pid-scoped instance never observes another process's dispatches" do
      ref = RouterCounters.new()
      handler_id = attach_scoped!(ref)

      try do
        # Another process routes; this instance must stay at zero.
        other = Task.async(fn -> assert {:ok, _} = route_facts_tier!(:other) end)
        Task.await(other, 60_000)

        assert RouterCounters.counts(ref) == %{deterministic: 0, llm: 0, phrase: 0}

        # This process routes; now the instance counts exactly its own.
        assert {:ok, _} = route_facts_tier!(:self)
        assert RouterCounters.counts(ref) == %{deterministic: 1, llm: 0, phrase: 0}
      after
        RouterCounters.detach(handler_id)
      end
    end

    test "the default (:any) scope keeps the long-lived instrument counting every emitter" do
      ref = RouterCounters.new()
      handler_id = RouterCounters.attach!(ref)

      try do
        other = Task.async(fn -> assert {:ok, _} = route_facts_tier!(:other_any) end)
        Task.await(other, 60_000)

        assert RouterCounters.counts(ref) == %{deterministic: 1, llm: 0, phrase: 0}
      after
        RouterCounters.detach(handler_id)
      end
    end
  end

  defp route_facts_tier!(driver_idx) do
    RequestRouter.route(HddlDeterministicFixture, facts_message(driver_idx))
  end

  defp facts_message(driver_idx) do
    A2A.Message.new_user([
      A2A.Part.Data.new(%{"goal_facts" => goal_facts_envelope(driver_idx)})
    ])
  end

  defp goal_facts_envelope(driver_idx) do
    %{
      "request_id" =>
        "router-counters-isolation-#{driver_idx}-#{System.unique_integer([:positive])}",
      "domain_name" => "router-counters-isolation-domain",
      "problem_name" => "router-counters-isolation-problem",
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

  defp route_phrase_tier! do
    RequestRouter.route(HddlDeterministicFixture, A2A.Message.new_user("create a labeled item"),
      phrase_templates: [phrase_template()]
    )
  end

  defp phrase_template do
    %{regex: @phrase_regex, to_envelope: fn _captures -> goal_facts_envelope(:phrase) end}
  end
end
