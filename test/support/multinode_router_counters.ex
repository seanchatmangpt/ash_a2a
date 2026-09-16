# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Test.MultinodeRouterCounters do
  @moduledoc """
  Real helper executed ON a real peer BEAM node via `:erpc.call/4` by
  `AshA2A.MultinodeRouterCountersTest`, driving real facts-tier and
  phrase-tier dispatches through `AshA2A.Planning.RequestRouter.route/3`
  and reporting back a real, node-local
  `AshA2A.Telemetry.RouterCounters.counts/1` snapshot -- the small,
  concrete cross-node compose-ability proof for the new `:phrase` slot:
  two independent real peer nodes each attach their own instance, drive
  their own real dispatches, and report their own real counts; the
  primary test process (the caller) merges both real per-node maps with
  plain addition. No new distributed aggregation protocol is built here.

  Lives under `test/support/` for the same real, load-bearing reason
  `AshA2A.Test.MultinodeDispatch`'s own @moduledoc documents:
  `elixirc_paths(:test) = ["lib", "test/support"]` (`mix.exs`) is what
  makes this module -- and the phrase-tier template closure `drive_and_report/3`
  builds internally -- loadable by a freshly-started `:peer` node's
  extended code path (`:code.add_pathsz/1`). A closure captured inside a
  `*_test.exs` module would be unloadable there and would fail on the
  peer with a real `{badfun, ...}`/undef error; a closure whose enclosing
  module is this one, already on the peer's extended code path, loads and
  runs there without issue.

  Not a mock or a stand-in for `RouterCounters`/`RequestRouter`: every
  call below is the real, unmodified public API of both, executed for
  real on whichever node this MFA actually runs -- zero LLM call (the
  phrase tier is deterministic by construction), zero network I/O.

  ## Real, empirically-found prerequisite: the `:telemetry` application

  `drive_and_report/3` calls `Application.ensure_all_started(:telemetry)`
  before attaching -- a real, necessary step, not defensive boilerplate:
  a freshly-started `:peer` node never starts any OTP application on its
  own (only its code path is extended), and `:telemetry.attach/4` is
  backed by a real GenServer (`:telemetry_handler_table`) that only
  exists once `:telemetry` has actually been started. An earlier version
  of this module omitted this call and every real peer-node dispatch
  failed with a real
  `{:noproc, {:gen_server, :call, [:telemetry_handler_table, ...]}}}`
  error -- caught by this task's own real `mix test` run, not asserted
  here as a hypothetical.
  """

  alias AshA2A.Planning.RequestRouter
  alias AshA2A.Telemetry.RouterCounters

  @advance_id "AshA2A.Test.Fixture.HddlDeterministicFixture.advance"
  @unlock_id "AshA2A.Test.Fixture.HddlDeterministicFixture.unlock"

  @phrase_regex ~r/^create a labeled item$/

  @doc """
  Attaches a fresh, node-local `RouterCounters` instance, drives
  `facts_count` real facts-tier dispatches and `phrase_count` real
  phrase-tier dispatches (via a real, module-local structured-phrase
  template -- zero LLM call) through `RequestRouter.route/3` against
  `resource_or_domain`, detaches, and returns `{node(), counts}` --
  `node()` captured on whichever node this MFA actually executes, the
  same real cross-node proof pattern
  `MultinodeDispatch.admit_on_this_node/2` already established.
  """
  @spec drive_and_report(module(), non_neg_integer(), non_neg_integer()) ::
          {node(),
           %{
             deterministic: non_neg_integer(),
             llm: non_neg_integer(),
             phrase: non_neg_integer()
           }}
  def drive_and_report(resource_or_domain, facts_count, phrase_count)
      when is_integer(facts_count) and facts_count >= 0 and is_integer(phrase_count) and
             phrase_count >= 0 do
    # Real, empirically-found prerequisite: `:telemetry.attach/4` is backed
    # by a real GenServer (`:telemetry_handler_table`) that only exists
    # once the `:telemetry` OTP application has actually been started on
    # THIS node -- a freshly-started `:peer` node has its code path
    # extended (`:code.add_pathsz/1`) but never starts any application, so
    # an unconditional `attach!/1` here previously failed for real with
    # `{:noproc, {:gen_server, :call, [:telemetry_handler_table, ...]}}}`.
    # `ensure_all_started/1` is idempotent and safe to call redundantly on
    # the primary test node too (where `:telemetry` is already started via
    # the full `:ash_a2a` application tree).
    {:ok, _apps} = Application.ensure_all_started(:telemetry)

    ref = RouterCounters.new()
    handler_id = RouterCounters.attach!(ref)

    try do
      Enum.each(1..facts_count//1, fn _ ->
        assert_ok(RequestRouter.route(resource_or_domain, facts_message()))
      end)

      Enum.each(1..phrase_count//1, fn _ ->
        assert_ok(
          RequestRouter.route(resource_or_domain, phrase_message(),
            phrase_templates: [phrase_template()]
          )
        )
      end)

      {node(), RouterCounters.counts(ref)}
    after
      RouterCounters.detach(handler_id)
    end
  end

  defp assert_ok({:ok, _package}), do: :ok

  defp assert_ok(other),
    do:
      raise(
        "AshA2A.Test.MultinodeRouterCounters real dispatch did not succeed: #{inspect(other)}"
      )

  defp facts_message do
    A2A.Message.new_user([A2A.Part.Data.new(%{"goal_facts" => goal_facts_envelope()})])
  end

  defp phrase_message, do: A2A.Message.new_user("create a labeled item")

  defp phrase_template do
    %{regex: @phrase_regex, to_envelope: fn _captures -> goal_facts_envelope() end}
  end

  defp goal_facts_envelope do
    %{
      "request_id" => "multinode-router-counters-#{System.unique_integer([:positive])}",
      "domain_name" => "multinode-router-counters-domain",
      "problem_name" => "multinode-router-counters-problem",
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
end
