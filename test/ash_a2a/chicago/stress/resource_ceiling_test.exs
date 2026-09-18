defmodule AshA2A.Chicago.Stress.ResourceCeilingTest do
  @moduledoc """
  Real resource-ceiling stress for `AshA2A.Semantic.Episode` (RFC-SA2A-002
  Gate 6): drive a real bounded episode toward its real configured resource
  ceiling under real sustained load and confirm it reaches a real lawful
  terminal state (`completed | quiescent | refused | resource_exhausted |
  bound_reached`) rather than hanging, crashing, or silently exceeding its
  envelope.

  Chicago style throughout, reusing the real collaborators the Gate-6 court
  (`AshA2A.Chicago.Courts.AutonomousExecution`) already exercises for
  correctness: the real `AshA2A.Semantic.Episode` executor and
  `Episode.Ledger`, the real `AshA2A.CommandBus`, a real
  `AshA2A.ReceiptStore.Memory`, a real `AshA2A.Authority.Broker.InMemory`,
  and the real ETS-backed `Step` Ash resource
  (`AshA2A.Chicago.Fixtures.AutonomyBounds`, `F` below). No mock, no stub, no
  `Process.sleep`-only fake -- every actuation this file counts is a real
  `Ash.create!/1` row read back independently through `F.rows/1`, never the
  episode's own self-reported counters alone.

  This file is *stress*, not correctness: `AshA2A.Chicago.Courts.
  ResourceBounds` (`SA2A-BOUNDS`) already falsifies each refusal code in
  isolation at small scale. What that court does not cover, and what this
  file adds, is real *sustained* load -- many real round trips through the
  full CommandBus/authority/receipt-store/ETS stack in one episode, and a
  recursive real subtask-delegation chain (`Episode.delegate/2` called
  repeatedly from inside a running episode, the path `AshA2A.Chicago.
  Fixtures.AutonomyBounds` itself never drives at more than a handful of
  calls) -- pushed until a real configured ceiling is actually reached.

  ExUnit's own default per-test timeout is itself a real falsifier for
  "does not hang": a stress case that never reaches a terminal state fails
  the suite on timeout rather than silently passing, so a passing test here
  is real evidence of real bounded termination, not merely an unraised
  exception.

  `async: false` to match `AshA2A.Chicago.AutonomyBoundsTest`, which shares
  the same real ETS `Step` resource.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Chicago.Fixtures.AutonomyBounds, as: F
  alias AshA2A.Semantic.Episode

  describe "max_ceiling/0 -- the representable boundary itself" do
    test "an envelope issued at the real maximum representable ceiling on every dimension is admitted" do
      ceiling = Episode.max_ceiling()
      assert ceiling == 9_223_372_036_854_775_807

      spec = [
        fan_out: ceiling,
        depth: ceiling,
        parallelism: ceiling,
        capabilities: [],
        executions: ceiling,
        memory_bytes: ceiling,
        tokens: ceiling,
        money_micros: ceiling,
        external_requests: ceiling,
        retries: ceiling,
        wall_time_ms: ceiling
      ]

      assert {:ok, envelope} = Episode.issue({:host, :stress_ceiling_boundary}, spec)
      assert {:ok, snapshot} = Episode.snapshot(envelope)

      assert snapshot.fan_out == ceiling
      assert snapshot.depth == ceiling
      assert snapshot.parallelism == ceiling
      assert snapshot.executions.limit == ceiling
      assert snapshot.executions.remaining == ceiling
      assert snapshot.memory_bytes == ceiling
      assert snapshot.spend.limits.tokens == ceiling
      assert snapshot.spend.limits.wall_time_ms == ceiling
    end

    test "one dimension one past the ceiling is refused, never silently clamped" do
      ceiling = Episode.max_ceiling()

      base = [
        fan_out: 1,
        depth: 1,
        parallelism: 1,
        capabilities: [],
        executions: 1,
        memory_bytes: 1,
        tokens: 1,
        money_micros: 1,
        external_requests: 1,
        retries: 1,
        wall_time_ms: 1
      ]

      for dimension <- [:tokens, :executions, :memory_bytes, :wall_time_ms, :external_requests] do
        over = Keyword.put(base, dimension, ceiling + 1)

        assert {:error,
                %{
                  code: :episode_envelope_ceiling_overflow,
                  detail: %{fields: fields, max: ^ceiling}
                }} = Episode.issue({:host, :stress_ceiling_boundary}, over)

        assert dimension in fields,
               "#{dimension} one past max_ceiling/0 must be named in the refusal, got #{inspect(fields)}"
      end
    end
  end

  describe "sustained real subtask-delegation load against a real executions ceiling" do
    test "many real subtask delegations drive a root envelope to its executions ceiling " <>
           "and terminate :refused, not by hanging or overrunning it" do
      ceiling = 100
      attempted_delegations = 130
      tag = "stress-delegate-#{System.unique_integer([:positive])}"

      F.with_env(fn env ->
        leaf_package = F.static_package!(F.projection(), 1)
        leaf_bind = F.bind(&F.record(tag, &1))

        root_package =
          F.static_package!(F.projection(), attempted_delegations,
            max_depth: attempted_delegations + 10,
            resource_envelope: %{
              max_wall_ms: 60_000,
              max_memory_bytes: 1_000_000_000,
              max_invocations: attempted_delegations * 2
            }
          )

        root_envelope = F.envelope!(executions: ceiling, depth: attempted_delegations + 10)

        subtask_bind = fn
          "step:" <> n ->
            case Integer.parse(n) do
              {i, ""} ->
                {:ok,
                 %{
                   kind: :subplan,
                   package: leaf_package,
                   bind: leaf_bind,
                   control: F.control(max_steps: 5, max_wall_time_ms: 5_000),
                   delegate: [
                     executions: 1,
                     capabilities: [F.record_capability()],
                     fan_out: 1,
                     parallelism: 1
                   ],
                   stage: i
                 }}

              _ ->
                {:error, {:unbound, n}}
            end

          other ->
            {:error, {:unbound, other}}
        end

        {wall_us, result} =
          :timer.tc(fn ->
            F.run!(root_package, root_envelope, env,
              principal: env.granted,
              bind: subtask_bind,
              control: F.control(max_steps: attempted_delegations + 10, max_wall_time_ms: 60_000)
            )
          end)

        real_rows = F.rows(tag)

        IO.puts("""
          [sa2a-stress resource_ceiling delegation] real measured numbers:
            executions ceiling (root envelope)  = #{ceiling}
            subtask delegations attempted       = #{attempted_delegations}
            subtask delegations committed       = #{result.committed}
            real Step rows independently read   = #{length(real_rows)}
            episode stages_run                  = #{result.stages_run}
            episode outcome / code               = #{result.outcome} / #{inspect(result.code)}
            real wall time                       = #{Float.round(wall_us / 1000, 2)} ms
        """)

        # Lawful terminal state -- never :error, never a raise, never a hang
        # (ExUnit's own test timeout is the falsifier for "hang").
        assert result.outcome in [
                 :completed,
                 :quiescent,
                 :refused,
                 :resource_exhausted,
                 :bound_reached
               ]

        # It got there specifically by hitting the real configured executions
        # ceiling on the delegating (root) envelope, not some other bound.
        assert result.outcome == :refused
        assert result.code == :bounds_delegation_not_narrowing

        # Exactly `ceiling` subtask delegations were admitted -- not one more
        # (would prove the envelope leaks) and not fewer (would prove it
        # refused before it was actually exhausted).
        assert result.committed == ceiling

        # Independent post-state proof: the real ETS resource shows exactly
        # `ceiling` real rows, corroborating the episode's own self-reported
        # `committed` count from an observer that does not trust it.
        assert length(real_rows) == ceiling

        # The refused (ceiling + 1)-th attempt is real evidence the executor
        # kept going one stage past the ceiling to *discover* the refusal --
        # it did not stop early and it did not overrun.
        assert result.stages_run == ceiling + 1

        # Real wall clock: bounded and positive, not a hang.
        assert wall_us > 0
        assert wall_us < 60_000_000

        # And an independent snapshot of the (now-exhausted) root envelope
        # confirms zero executions remain -- the ceiling was really reached,
        # not merely a count that happens to match. `executions.consumed`
        # itself stays 0 here: that counter tracks direct `:command`
        # charges on THIS envelope (`Episode`'s `charge/3`), and every
        # charge in this run happened on child envelopes the root
        # delegated to -- the root's own ledger entry was only ever
        # debited by `Bounds.delegate/2`, which moves `remaining`, not
        # `consumed`. Asserting `remaining == 0` (not `consumed`) is the
        # real, correct falsifier for "the root's pool is exhausted".
        assert {:ok, snapshot} = Episode.snapshot(root_envelope)
        assert snapshot.executions.limit == ceiling
        assert snapshot.executions.remaining == 0
      end)
    end
  end

  describe "sustained real actuation load against a real wall_time_ms ceiling" do
    test "real elapsed wall-clock time under sustained per-step delay drives an episode " <>
           "to its wall_time_ms ceiling and terminates :resource_exhausted" do
      step_count = 12
      delay_ms = 120
      wall_ceiling_ms = 400
      uninterrupted_us = step_count * delay_ms * 1000
      tag = "stress-walltime-#{System.unique_integer([:positive])}"

      F.with_env(fn env ->
        package =
          F.static_package!(F.projection(), step_count,
            max_depth: step_count + 5,
            resource_envelope: %{
              max_wall_ms: wall_ceiling_ms,
              max_memory_bytes: 1_000_000_000,
              max_invocations: step_count * 2
            }
          )

        envelope = F.envelope!(depth: step_count + 5)

        {wall_us, result} =
          :timer.tc(fn ->
            F.run!(package, envelope, env,
              principal: env.granted,
              bind: F.bind(&F.record(tag, &1, delay_ms: delay_ms)),
              control: F.control(max_steps: step_count + 5, max_wall_time_ms: 60_000)
            )
          end)

        real_rows = F.rows(tag)

        IO.puts("""
          [sa2a-stress resource_ceiling wall_time] real measured numbers:
            configured wall_time_ms ceiling      = #{wall_ceiling_ms}
            steps offered / real delay per step  = #{step_count} / #{delay_ms} ms
            uninterrupted-run estimate           = #{div(uninterrupted_us, 1000)} ms
            episode committed / stages_run       = #{result.committed} / #{result.stages_run}
            real Step rows independently read    = #{length(real_rows)}
            episode outcome / code / resource    = #{result.outcome} / #{inspect(result.code)} / #{inspect(result.resource)}
            real wall time                       = #{Float.round(wall_us / 1000, 2)} ms
        """)

        assert result.outcome in [
                 :completed,
                 :quiescent,
                 :refused,
                 :resource_exhausted,
                 :bound_reached
               ]

        # It specifically hit the real wall_time_ms ceiling -- not a crash,
        # not silent completion of all `step_count` steps.
        assert result.outcome == :resource_exhausted
        assert result.code == :bounds_resource_exhausted
        assert result.resource == :wall_time_ms

        # Real, partial progress: some steps really ran before the real
        # elapsed clock exceeded the ceiling; not all of them did.
        assert result.committed >= 1
        assert result.committed < step_count

        # Independent post-state proof, same discipline as the delegation
        # stress above: the real ETS row count matches the episode's own
        # `committed` count exactly.
        assert length(real_rows) == result.committed

        # The real measured wall time is materially less than what running
        # every step to completion would have cost -- proof the ceiling
        # really stopped it early rather than merely being a label on a
        # full, uninterrupted run.
        assert wall_us > 0
        assert wall_us < uninterrupted_us
      end)
    end
  end
end
