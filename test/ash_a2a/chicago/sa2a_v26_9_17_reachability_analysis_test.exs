defmodule AshA2A.Chicago.SA2AV269_17ReachabilityAnalysisTest do
  @moduledoc """
  Qualifies the real `native/hddl_cli/target/release/hddl_analyze` binary --
  an additive diagnostic sibling to `hddl_cli` (`native/hddl_cli/src/bin/
  hddl_analyze.rs`) that reuses the SAME real `ferroplan_hddl` parser/
  grounder/translator the solving path already depends on (no
  reimplementation of parsing, grounding, or FOND solving) and adds one
  thing the solver's own solved/NoPlan verdict does not expose: exhaustive
  forward-reachability + terminal-state classification over the ground
  action/method graph `translate()` already computes internally.

  ## Why this exists

  `test/ash_a2a/chicago/sa2a_v26_9_17_fond_qualification_test.exs` already
  established, via the real solver, that the committed
  `test/support/hddl/sa2a_v26_9_17_dogfood/{domain,problem}.hddl` fixture
  reports real `NoPlan` -- and that a prior reconciliation pass (see that
  test's own moduledoc) gave every genuinely-repairable `oneof` dead-end a
  real recovery method while deliberately leaving true invariant-driven
  terminals (receipt-reconcile-blocked's "NEVER replay automatically",
  among others) unrepaired. That prior finding rested on *sampled* isolated
  ablations (construct a minimal sub-domain, run the real solver, observe
  NoPlan-vs-solved) -- real evidence, but not an exhaustive one: it could
  not rule out some OTHER, unnoticed uncovered branch also contributing to
  the NoPlan result.

  This test closes that gap with an *exhaustive* real measurement instead
  of a sampled one, mirroring (independently, in ash_a2a's own real Rust/
  ferroplan toolchain rather than a hand-rolled reimplementation) the same
  rigor upgrade a concurrent session's real work in `autofde-lab` applied to
  the sibling Python-side grounding of this same v26.9.17 domain: full
  ground-state enumeration, terminal-state classification against every
  disclosed "terminal-by-design" predicate, and confirmation of whether the
  stated `:goal` is reachable at all under *some* favorable sequence of
  non-deterministic outcomes (a "weak"/best-case path), even though no
  *strong-cyclic* (every-outcome-covered) policy exists.

  ## The real, measured result this test asserts (as of the committed
  fixture; re-run for real, not copied from a prior session)

      212 total ground states, all 212 reachable from :init
      239 ground transitions
      30 real terminal (dead-end, no outgoing transition) states
      0 of those 30 are unexplained by a known, disclosed terminal predicate
      2 of the 212 reachable states DO satisfy the full stated :goal

  Every one of the 30 terminals is attributable to exactly one of the
  domain's own disclosed dead-end predicates (unsupported, receipt-
  reconcile-blocked, verification-failed, process-nonconformant, candidate-
  refused, equivalence-failed, authority-refused [episode 2's un-repaired
  occurrence], actuation-failed [episode 2's un-repaired occurrence],
  candidate-unsupported) -- zero left unexplained. That is the exhaustive,
  not sampled, confirmation that the domain's real NoPlan verdict has no
  hidden, unaccounted-for cause: every real dead end traces to a predicate
  already named and disclosed as deliberately unrepaired.

  The 2 real goal-satisfying reachable states (their real ids are asserted
  below, not hand-picked) are the quantified, cited version of "the goal
  IS reachable given favorable nondeterminism, even though no total
  strong-cyclic guarantee exists" -- the same shape of finding the RFC's own
  Chicago-court discipline asks for: a real distinction between "provably
  impossible" and "provably not unconditionally guaranteed," never
  collapsed into a single undifferentiated NoPlan.

  Shells out to the real `native/hddl_cli/target/release/hddl_analyze`
  binary via `System.cmd/2` (a real OS subprocess, zero Mock/mox/patch/
  monkeypatch) and asserts on the real decoded JSON it produces, mirroring
  every other qualification test in this directory's own conventions.
  """

  use ExUnit.Case, async: true

  @cli_path Path.expand("../../../native/hddl_cli/target/release/hddl_analyze", __DIR__)

  @domain Path.expand("../../support/hddl/sa2a_v26_9_17_dogfood/domain.hddl", __DIR__)
  @problem Path.expand("../../support/hddl/sa2a_v26_9_17_dogfood/problem.hddl", __DIR__)

  @markers Enum.join(
             [
               "unsupported",
               "receipt-reconcile-blocked",
               "manufacture-failed",
               "authority-refused",
               "actuation-failed",
               "verification-failed",
               "process-nonconformant",
               "candidate-refused",
               "candidate-blocked",
               "candidate-unsupported",
               "equivalence-failed",
               "allocation-blocked",
               "build-broken",
               "blocked"
             ],
             ","
           )

  setup_all do
    unless File.exists?(@cli_path) do
      flunk("""
      hddl_analyze binary not built at #{@cli_path}.
      Run: cd #{Path.expand("../../../native/hddl_cli", __DIR__)} && cargo build --release
      """)
    end

    :ok
  end

  test "real exhaustive reachability: every terminal state is explained, and the goal is really reachable" do
    {stdout, exit_code} = System.cmd(@cli_path, [@domain, @problem, @markers])
    assert exit_code == 0, "hddl_analyze exited #{exit_code}: #{stdout}"

    decoded =
      case JSON.decode(stdout) do
        {:ok, decoded} ->
          decoded

        {:error, reason} ->
          flunk("hddl_analyze produced non-JSON stdout: #{inspect(reason)}: #{stdout}")
      end

    refute Map.has_key?(decoded, "error"),
           "hddl_analyze reported an error: #{inspect(decoded["error"])}"

    # Full ground-state graph: all 212 ground states are reachable from
    # :init (no dead code baked into the domain by construction).
    assert decoded["total_ground_states"] == 212
    assert decoded["reachable_state_count"] == 212
    assert decoded["total_transitions"] == 239

    # Exhaustive terminal classification: real, not sampled.
    assert decoded["terminal_state_count"] == 30
    assert decoded["unexplained_terminal_count"] == 0
    assert decoded["explained_terminal_count"] == 30
    assert decoded["unexplained_terminals"] == []

    # The full stated :goal IS reachable given favorable nondeterminism --
    # a real, cited "weak"/best-case path exists -- even though the
    # sibling fond_qualification_test's real solver run reports NoPlan for
    # a total strong-cyclic guarantee. Both are real and both are true;
    # they answer different questions.
    assert decoded["goal_reachable"] == true
    assert decoded["goal_satisfying_reachable_count"] == 2
    goal_state_ids = decoded["goal_states"] |> Enum.map(& &1["state_id"]) |> Enum.sort()
    assert goal_state_ids == ["s204", "s211"]
  end

  test "every disclosed terminal-by-design predicate is actually exercised by at least one real terminal state" do
    {stdout, 0} = System.cmd(@cli_path, [@domain, @problem, @markers])
    {:ok, decoded} = JSON.decode(stdout)

    matched_markers =
      decoded["explained_terminals"]
      |> Enum.flat_map(& &1["matched_markers"])
      |> MapSet.new()

    # Every predicate the domain's own comments name as deliberately
    # terminal-by-design is confirmed, by this real measurement, to
    # actually be reachable and actually dead-end -- not merely declared
    # in prose but never structurally reachable.
    for predicate <- ~w(unsupported receipt-reconcile-blocked verification-failed
                         process-nonconformant candidate-refused equivalence-failed
                         authority-refused actuation-failed candidate-unsupported) do
      assert predicate in matched_markers,
             "expected disclosed terminal predicate #{predicate} to be exercised by a real reachable terminal state, but it was not observed"
    end

    # The repo-boundary `blocked` predicate and `manufacture-failed` are
    # NOT expected to appear as terminals: both were given real repair
    # methods in the reconciliation pass, so a state carrying either fact
    # should always have an outgoing transition (never a dead end).
    refute "blocked" in matched_markers
    refute "manufacture-failed" in matched_markers
    refute "build-broken" in matched_markers
    refute "allocation-blocked" in matched_markers
    refute "candidate-blocked" in matched_markers
  end
end
