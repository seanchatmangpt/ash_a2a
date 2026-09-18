# WAVE-RECEIPT — agent A5r, ticket b4p-f5-02 (ash_a2a), scope item 1

Date: 2026-09-18 · Session: A5r (resumed a dead predecessor's partial work)
· Worktree: `/Users/sac/ash_a2a-wt/f5-02-hddlsolver` (isolated; no writes to
`/Users/sac/beam4pm`)

## Standing

**ALIVE** for scope item 1 (`HddlSolver` cross-VM temp-file collision) —
every claim below is an observed execution in this session against the
exact subject (`lib/ash_a2a/planning/hddl_solver.ex` + the two-`:peer`
reproduction test), with fail-before and pass-after evidence. The
inherited uncommitted work was falsified before trusting it: the fix was
stashed and the test was re-proven red on the old solver three times, in
this session, before the fix was restored and re-proven green. Ticket-level
standing stays with the coordinator (items 2+3 = sibling agent A6, landed
on `fix/commandbus-tail-latency` / `fix/router-counters-isolation`; the
beam4pm consumption gate runs after the branches merge upstream).

## Base + branch + SHAs

| branch | base | HEAD |
|---|---|---|
| `fix/hddlsolver-crossvm-tempdir` | `fa51fc8` (same base as A6's branches) | this commit — code SHA in the commit pair below; receipt itself is the trailing docs commit |

Commits: `fix(planning): make HddlSolver temp paths per-node/per-invocation
unique across VMs` (fix + test + CHANGELOG) · `docs(receipt): WAVE-RECEIPT
for b4p-f5-02 item 1 (agent A5r)`.

## Commands + exits (all run in this session, this worktree)

| command | exit | result |
|---|---|---|
| `mix deps.get` | 0 | deps resolved |
| `cd native/hddl_cli && cargo build --release --locked` | 0 | binary current (`Finished ... in 0.25s`); artifact was already present from the predecessor's build — `--locked` revalidated the lockfile this session; the fail-before/pass-after runs below exercise the real binary end to end |
| `mix test test/ash_a2a_planning_hddl_solver_crossvm_test.exs` with the fix **stashed** (`git stash push -- lib/ash_a2a/planning/hddl_solver.ex`), test kept — run 1 | 2 | **1 test, 1 failure** — real cross-contamination |
| same — run 2 | 2 | **1 test, 1 failure** (different contamination shape) |
| same — run 3 (recorded verbatim below) | 2 | **1 test, 1 failure** (different contamination shape again) |
| `git stash pop` | 0 | fix restored |
| `mix test test/ash_a2a_planning_hddl_solver_crossvm_test.exs` with fix — runs 1–4 | 0 (x4) | **1 test, 0 failures** every run |
| related suites: crossvm + hddl_deterministic_planning + hddl_solver_qualification + dsl_nested_hddl_operator + freedom_gym_hddl_plan + multinode_cluster + semantic_refusal + chicago/stress/multinode_concurrency (8 files) | 0 | **42 tests, 0 failures** |
| `mix format --check-formatted` (solver, test, helper, CHANGELOG) | 0 | clean |
| `mix test --max-cases 6` full suite, run A | 2 | 2067 tests, 3 failures, 14 invalid — triage below |
| invalid triage: 3 invalidated modules + cwd test in isolation, after `docker start ash_a2a_test_pg` | 0 | 14 tests, 0 failures |
| `mix test --max-cases 6` full suite, run B (DB up) | 2 | 2067 tests, 5 failures, 0 invalid — triage below |
| graphlaw-family isolation rerun (engine + cwd files) | 0 | 9 tests, 0 failures |

## Fail-before evidence (verbatim, recorded run 3; command:
`mix test test/ash_a2a_planning_hddl_solver_crossvm_test.exs`, exit 2,
fix stashed)

```
  1) test two concurrent peer VMs solving different HDDL pairs get outcomes consistent with their OWN inputs (no cross-VM temp-file collision) (AshA2A.PlanningHddlSolverCrossvmTest)
     test/ash_a2a_planning_hddl_solver_crossvm_test.exs:122
     node A (solvable pair) got cross-contaminated outcomes: [ok: true, ok: true, error: :hddl_solve_error, error: :hddl_solve_error, ok: true, error: :hddl_solve_error, error: :hddl_solve_error, error: :hddl_solve_error]
     code: assert results_a == List.duplicate({:ok, true}, @iterations),
     stacktrace:
       test/ash_a2a_planning_hddl_solver_crossvm_test.exs:181: (test)


Finished in 2.8 seconds (0.00s async, 2.8s sync)
1 test, 1 failure
```

Run 1 and run 2 failed with different mixes (`[error: :hddl_solve_error,
ok: true, ...]` and `[error, ok, ok, ok, ok, ok, error, error]`) — a
run-varying race signature, exactly the defect's shape, and proof the test
is not vacuous: it fails on the old code deterministically-by-race (3/3)
and passes on the new code (4/4).

## Fix summary (mechanism)

`HddlSolver.run/4` derived its temp paths from
`System.unique_integer([:positive, :monotonic])` alone — unique only
within one BEAM VM. Two fresh `:peer` VMs on one shared host start their
monotonic counters at the same value and resolve the same
`System.tmp_dir!/0`, so same-sequence solves derived identical absolute
temp paths and the concurrent `File.write!/2` + `File.rm/1` pairs
corrupted each other's solve. The fix (minimal: one changed line plus one
documented private helper) prefixes a sanitized `node()` tag to the
per-invocation unique integer — distinct nodes always have distinct
names, so paths are unique ACROSS VMs by construction and per-invocation
within a node; cleanup is unchanged and per-owner. Nothing else in the
solve path moved.

## Reproduction test shape (falsified before trusting)

Two real `:peer` nodes (`:peer.start_link` + `:code.add_pathsz`, the
established `MultinodeClusterTest` pattern) each drive the real
`HddlSolver.solve/3` — real temp files + real `hddl_cli` OS subprocess —
8 times each, over one explicitly shared `tmp_dir`, synchronized by a
cross-node wall-clock barrier (one shared host clock), node A on the
genuinely solvable `freedom_gym_meeting` pair, node B on the genuinely
unsolvable `unsolvable_qualification` pair. Asserts every outcome stayed
consistent with its own node's inputs in BOTH directions, results are
node-tagged (computed on the remote peer, not the primary), and zero temp
files survive. Disclosed forcing (in the test's own @moduledoc): the
barrier timing and the explicit shared `tmp_dir` — the latter matches
production (peer children inherit the parent's OS tmp dir); the path
naming itself is unforced and must collide on its own under the old code,
which the fail-before runs above demonstrate it does.

## Full-suite triage (both runs' deviations classified)

- Run A, 14 invalid: three modules' `setup_all` (Oban migrations) died on
  `tcp connect (localhost:55432): connection refused` — the documented
  `ash_a2a_test_pg` Postgres container was down (exited 28h prior).
  Environmental, not caused by this change. Started the container
  (the repo's own documented provisioning, `docs/how-to/test-your-ash_a2a-app.md`);
  the three modules then passed in isolation (`14 tests, 0 failures`).
- Run A + Run B, `GraphLawVendorToolVersionCwdTest` x3 (`/private/var`
  left-value): the ticket-named pre-existing flake — **hit** in both full
  runs, green in isolation.
- Run B only, `GraphlawEngineTest` x2: `GenServer.stop/3` in ExUnit
  `on_exit` teardown racing an already-dead process — same graphlaw
  family, load-dependent; green in isolation (`9 tests, 0 failures`).
- `SemanticRefusalTest` `:hddl_solve_error` flake: **not hit** (passed in
  the related-suite run and both full runs). `:eaddrinuse`: **not hit**.
- Zero failures in either full run are attributable to this change; the
  crossvm test itself passed inside both full-suite runs.

## Inherited-vs-new attribution

Inherited uncommitted from the dead predecessor (falsified, then kept):
the solver fix (`hddl_solver.ex`), the crossvm test, the
`test/support` dispatch helper, and the original CHANGELOG entry.
New in this session: all builds, the fail-before stashing + 3 red runs +
restore, the 4 green runs, the related-suite and full-suite executions
and triage, the DB-container recovery, and the CHANGELOG evidence lines
corrected to this session's observed facts (the predecessor's specific
"node B's first iteration" shape and `20 tests` count generalized to the
run-varying shapes and counts actually observed and reproducible here).

## Files changed

- `lib/ash_a2a/planning/hddl_solver.ex` (modified — the fix)
- `test/ash_a2a_planning_hddl_solver_crossvm_test.exs` (new — the two-peer reproduction)
- `test/support/hddl_solver_crossvm_dispatch.ex` (new — peer-side barrier/dispatch helper)
- `CHANGELOG.md` (modified — entry under `[26.9.17]`, house `### Fixed --` style)
- `WAVE-RECEIPT.md` (new — this receipt)

## 比 (ratio, fail-closed)

Delivered lines (final diff): ~329 across the five files above.
Hand-written: 100% — no admitted pack or generator expresses HddlSolver
temp-path naming; this surface is owned by upstream `~/ash_a2a` itself
(the repo that owns the defect), which documents hand fixes in its
CHANGELOG by its own convention; no generator owns this mutation.
Attribution within the hand-written lines: predecessor-authored ~321/329
(98% — fix, test, helper, original entry), A5r-authored 8/329 (2% —
CHANGELOG evidence-line corrections). Unknown attribution: 0.

## Falsifiers attempted

1. Inherited fix/test trust — falsified by stashing the fix and re-running
   the test on the old solver: 3/3 red with varying race shapes (test is
   non-vacuous; fix is load-bearing).
2. Test-green-by-accident — falsified by 4/4 green with the fix restored,
   including inside both full-suite runs, plus the negative-direction
   assertion (unsolvable node must never return `ok: true`).
3. Full-suite failures caused by this change — falsified by classification:
   all 8 failing/invalid outcomes across both runs are the named pre-existing
   graphlaw-family flake or the down test DB; every one green in isolation;
   no failure touches planning/HddlSolver paths.

## Remaining (not this agent's scope)

- Ticket items 2 (CommandBus tail latency) and 3 (RouterCounters
  contamination): landed by sibling agent A6 (`f68bde4`, `9f47af4`,
  `255d3dc` + receipt `96b24fb` on the A6 worktree/branches).
- Ticket History row append + the beam4pm consumption gate (`mix test
  test/beam4pm_ferroplan_test.exs test/beam4pm_ferroplan_facades_test.exs`
  against the updated dep + two-node concurrent OCEL dispatch smoke):
  coordinator-owned — `/Users/sac/beam4pm` is write-forbidden from this
  session.
- Branch merge/push upstream: coordinator-owned (this session never pushes).
- Optional follow-up recorded in the CHANGELOG entry: the stress harness's
  now-redundant `isolate_peer_unique_integer_counters/1` band mitigation
  belongs to `test/ash_a2a/chicago/stress/multinode_concurrency_test.exs`'s
  own scope, not this fix's.
