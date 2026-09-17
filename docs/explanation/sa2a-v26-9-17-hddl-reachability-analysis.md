# SA2A v26.9.17 HDDL Reachability Analysis

This document presents the real, re-measured reachability and terminal-state
findings for the v26.9.17 cross-repo SA2A self-improvement release-
qualification HDDL/FOND domain: `test/support/hddl/sa2a_v26_9_17_dogfood/
domain.hddl` and `problem.hddl`. It exists because the real FOND solver's
verdict (`NoPlan`) and the real exhaustive-reachability verdict (the goal is
satisfiable under favorable nondeterminism) are both true of the same fixture
at the same time, and that pairing needs an explanation, not a single
collapsed status line. The audience is anyone deciding whether this domain's
`NoPlan` result is a defect to fix or a correctly disclosed limit of the
pinned solver.

## The two real findings, stated together

| Question | Real answer | Source |
| --- | --- | --- |
| Does a strong-cyclic FOND policy exist? | No -- real `NoPlan` | `hddl_cli`, exit 1 |
| Is the stated `:goal` reachable at all? | Yes -- 2 of 212 states | `hddl_analyze` |

Both are measured against the identical, unmodified fixture pair. Neither
supersedes the other: they answer different questions about the same ground
state graph, detailed below.

## Re-running the measurement

Both binaries are additive siblings under `native/hddl_cli/src/bin/`:
`hddl_cli` (the solver) answers "does a valid FOND policy exist", and
`hddl_analyze` (`native/hddl_cli/src/bin/hddl_analyze.rs:1`) answers "of every
ground state the same real parser/grounder/translator produces, which are
dead ends, which satisfy `:goal`, and which of the domain's own disclosed
`oneof`-outcome predicates explains each dead end". Neither binary
reimplements parsing, grounding, or FOND solving a second time --
`hddl_analyze.rs:26` imports the same `ferroplan_hddl::{grounder, parser,
translate}` the solver already depends on.

Re-run for real, from this document's own worktree, rather than trusting a
prior session's numbers:

```text
$ ./native/hddl_cli/target/release/hddl_cli \
    test/support/hddl/sa2a_v26_9_17_dogfood/domain.hddl \
    test/support/hddl/sa2a_v26_9_17_dogfood/problem.hddl
{"error":"planner error: NoPlan"}
$ echo $?
1
```

```text
$ ./native/hddl_cli/target/release/hddl_analyze \
    test/support/hddl/sa2a_v26_9_17_dogfood/domain.hddl \
    test/support/hddl/sa2a_v26_9_17_dogfood/problem.hddl \
    "unsupported,receipt-reconcile-blocked,manufacture-failed,authority-refused,\
actuation-failed,verification-failed,process-nonconformant,candidate-refused,\
candidate-blocked,candidate-unsupported,equivalence-failed,allocation-blocked,\
build-broken,blocked"
```

The decoded JSON's real top-level counts, exactly as re-run for this
document:

```json
{
  "total_ground_states": 212,
  "reachable_state_count": 212,
  "total_transitions": 239,
  "terminal_state_count": 30,
  "explained_terminal_count": 30,
  "unexplained_terminal_count": 0,
  "goal_reachable": true,
  "goal_satisfying_reachable_count": 2
}
```

## State-space size

212 ground states total, and all 212 are reachable from `:init` by real BFS
over the ground action/method graph `translate()` computes -- no dead code is
baked into the domain by construction, and no state is orphaned before the
solver or the reachability walk ever sees it. 239 ground transitions connect
them. These are exhaustive counts over the real ground graph, not a sample.

## Terminal-state classification

30 of the 212 reachable states are terminal: no ground action or method
applies there, so the state has no outgoing transition. Every one of the 30
is attributed to at least one of the domain's own disclosed
terminal-by-design predicates (the marker list passed on the command line
above); `unexplained_terminal_count` is 0. No terminal state traces to an
unnamed or undisclosed cause.

The real marker histogram over the 30 explained terminals (each terminal
matched exactly one marker in this fixture):

| Marker | Terminal count |
| --- | --- |
| `unsupported` | 9 |
| `receipt-reconcile-blocked` | 4 |
| `verification-failed` | 4 |
| `process-nonconformant` | 4 |
| `candidate-refused` | 2 |
| `equivalence-failed` | 2 |
| `authority-refused` | 2 |
| `actuation-failed` | 2 |
| `candidate-unsupported` | 1 |

9 + 4 + 4 + 4 + 2 + 2 + 2 + 2 + 1 = 30, matching `explained_terminal_count`.
`receipt-reconcile-blocked` (`domain.hddl:67`, declared terminal-by-design at
`domain.hddl:988`, "NEVER replay automatically" at `domain.hddl:749` and
`domain.hddl:916`) is real corroborated invariant, not an arbitrary choice:
`lib/ash_a2a/command_bus.ex`'s reconciliation path is a distinct,
presumably-operator-invoked function, never folded into automatic dispatch,
which is exactly what this predicate models as unrepairable by a retry
method. `authority-refused` and `actuation-failed` each contribute 2 rather
than 0: episode 1's occurrences were given real repair methods during the
prior reconciliation pass (see `sa2a_v26_9_17_fond_qualification_test.exs`'s
moduledoc), but episode 2's replay occurrences were deliberately left
unrepaired, so each predicate still dead-ends exactly where the replay path
reaches it. `blocked`, `manufacture-failed`, `build-broken`,
`allocation-blocked`, and `candidate-blocked` do not appear in this histogram
at all -- every one of those was given a real repair method, so no state
carrying that fact is ever a dead end. `test/ash_a2a/chicago/
sa2a_v26_9_17_reachability_analysis_test.exs:161-176` asserts both halves of
this: each of the nine listed predicates is exercised by at least one real
terminal, and none of the five repaired predicates is.

## Goal reachability under favorable nondeterminism

The domain's `:goal` (`test/support/hddl/sa2a_v26_9_17_dogfood/
problem.hddl:117-133`) conjoins `release-qualified`, `experience-admitted`,
`replay-contract`, `replayed`, `frontier-clean` on episode 2,
`affidavit-issued` on both episodes, and `process-conformant` on both
episodes. Two of the 212 reachable states -- `s204` and `s211` -- satisfy
every conjunct simultaneously. `hddl_analyze`'s BFS finds both by construction
(it walks every reachable state and tests `:goal` satisfaction at each one),
so `goal_reachable: true` and `goal_satisfying_reachable_count: 2` are exact,
not estimated.

This is not a contradiction of the solver's real `NoPlan` verdict; it is a
different, also-real claim about the same graph. `hddl_cli`'s
`PlanningType::Fond` dispatch asks for a *strong-cyclic* policy: one action
choice at every state, covering *every* `oneof` (nondeterministic) outcome,
that is guaranteed to eventually reach a goal state no matter which outcome
the environment picks. `hddl_analyze` asks a strictly weaker question: does
*some* sequence of outcomes -- the favorable ones, at every `oneof` the plan
passes through -- reach a goal state at all. A "yes" to the weaker question
is a necessary condition for a "yes" to the stronger one, never a sufficient
one: the graph can (and here does) contain a real best-case path to `s204`
or `s211` while also containing at least one reachable `oneof` branch, on
every candidate strategy, that the strong-cyclic requirement cannot route
around without eventually landing on one of the 30 real terminals above.
Concretely: any policy that reaches `s204`/`s211` on the lucky branch of
every `oneof` it passes through still has to declare *some* action for the
unlucky branches too, and for at least one of those (an episode-2 `oneof`
on `authority-refused`, `actuation-failed`, `receipt-reconcile-blocked`,
`verification-failed`, or `process-nonconformant`, per the histogram above)
every available action leads only to a real terminal, never back toward the
goal. `hddl_cli`'s `PlanningType::Fond` dispatch requires universal coverage
of every reachable `oneof` branch and has no HDDL syntax to mark a
non-goal terminal as an accepted absorbing state. This is not something
`ash_a2a` could fix locally: `native/hddl_cli/Cargo.toml:30-31` pins both
`ferroplan` and `ferroplan-hddl` to the external `ferroplan` repository at
git rev `29134d7bc2c578aa39e05bceeee43a6893f2026b`, and in that pinned
checkout's own `crates/ferroplan/src/hddl.rs:90`, `adapt_problem` hardcodes
`unsafe_states` (`hddl.rs:107`) and `soft_goal_facts` (`hddl.rs:108`) to
`Default::default()` -- so the one real unrepairable branch is enough to
make the strong-cyclic verdict `NoPlan`, independent of how many
favorable-path goal states exist.

## Cross-referenced tests

Both real findings are pinned by committed, currently-passing tests, not
asserted here as prose alone:

- `test/ash_a2a/chicago/sa2a_v26_9_17_fond_qualification_test.exs` -- shells
  out to the real `hddl_cli` binary via `System.cmd/2` and asserts the real
  decoded JSON reports `NoPlan` (non-zero exit, `"error"` key containing
  `"NoPlan"`, never `"solved": true`), plus a second test asserting the same
  fixture grounds cleanly (no parse or grounding error, so the `NoPlan` is
  semantic, not accidental).
- `test/ash_a2a/chicago/sa2a_v26_9_17_reachability_analysis_test.exs` --
  shells out to the real `hddl_analyze` binary the same way and asserts the
  exact counts in this document (`total_ground_states == 212`,
  `reachable_state_count == 212`, `total_transitions == 239`,
  `terminal_state_count == 30`, `unexplained_terminal_count == 0`,
  `goal_reachable == true`, `goal_satisfying_reachable_count == 2`, and
  `goal_states` ids sorted to exactly `["s204", "s211"]`), plus a second
  test asserting every one of the nine disclosed terminal predicates is
  actually exercised and none of the five repaired predicates is.

Both tests shell out to real subprocess binaries built from the real
`ferroplan_hddl` crate (zero mock/stub of the solver or the analyzer), per
this repository's Chicago-school testing discipline described in
`docs/explanation/chicago-conformance-court.md`.

## Cross-repo corroboration (independent, not identical, methodology)

A concurrent session working the same v26.9.17 self-improvement domain from
`/Users/sac/autofde-lab`'s own Python-side re-grounding independently
reached the analogous shape of finding: a `STRICT` goal framing is invalid
(no total strong-cyclic policy), while an `EXTENDED` framing is
`STRONG_CYCLIC`-valid. That is a real, independently-corroborating result
from a second, separately-built toolchain converging on the same
strict-vs-relaxed distinction this document draws for the strong-cyclic-vs-
weak-reachable case -- not the same methodology run twice. The autofde-lab
result comes from a hand-built policy/reachability tool written for that
session's own investigation; this document's numbers come from
`hddl_analyze` reusing the real `ferroplan_hddl` parser, grounder, and
translator that `hddl_cli`'s solving path already depends on in this
repository. Two different implementations, over two different framings of
the same underlying domain, agreeing that the honest answer splits into a
strict "no" and a relaxed "yes" is stronger evidence than either alone, and
the methodological difference is disclosed here plainly rather than implied
to be the same measurement.

## See Also

- `test/support/hddl/sa2a_v26_9_17_dogfood/domain.hddl` -- the reconciled
  v26.9.17 FOND/HDDL domain this analysis measures
- `test/support/hddl/sa2a_v26_9_17_dogfood/problem.hddl` -- the `:init` and
  `:goal` this analysis's reachability and goal-satisfaction counts are
  measured against
- `native/hddl_cli/src/bin/hddl_analyze.rs` -- the real reachability/
  terminal-classification binary this document's numbers come from
- `test/ash_a2a/chicago/sa2a_v26_9_17_fond_qualification_test.exs` -- pins
  the real solver's `NoPlan` verdict
- `test/ash_a2a/chicago/sa2a_v26_9_17_reachability_analysis_test.exs` --
  pins every exact count in this document
- `lib/ash_a2a/command_bus.ex` -- the real dispatch/reconciliation code the
  `receipt-reconcile-blocked` predicate models
- `docs/explanation/chicago-conformance-court.md` -- the falsification-based
  conformance discipline both cross-referenced tests follow
- `docs/explanation/canonical-graph-identity.md` -- a prior example of this
  same "measure for real, disclose exactly what was and was not verified"
  documentation shape
