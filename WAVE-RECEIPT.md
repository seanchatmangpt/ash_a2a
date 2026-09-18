# WAVE-RECEIPT — b4p-f5-01 scope item 3 (wire the 7 orphaned benchmark modules)

- agent: A4r (resumed dead predecessor's partial work)
- date: 2026-09-18
- standing: PARTIAL_ALIVE (bench wiring gate ALIVE in-session; suite gate carries the known pre-existing VendorCwd flake, triaged below)
- worktree: /Users/sac/ash_a2a-wt/f5-01-bench-wiring, branch `chore/f5-01-bench-wiring`
- base: `fa51fc8` (docs(changelog): fold Unreleased docs pass into [26.9.17])
- head: this receipt is committed at the branch tip of `chore/f5-01-bench-wiring` (commit "chore(bench): wire the 7 orphaned RFC-SA2A-002 benchmark modules into the run-all dispatch"; a commit cannot contain its own SHA — read the tip with `git rev-parse HEAD`, observed `7de9f2b` before the final receipt-only amend)

## 1. Inherited work — judged before trusted (偽)

Four uncommitted files inherited from the dead predecessor. Verdict per file:

| file | judgement |
|---|---|
| `lib/ash_a2a/chicago/bench.ex` | CORRECT WIRING. Adds B2/B3/B4/B6/B7/B8/B10 to `@benchmarks` + aliases + moduledoc. No logic change; `run/1`, `select/1`, `measure/2` untouched. |
| `lib/ash_a2a/chicago/bench/b6_reactive_cascade.ex` | DOCS ONLY. Replaces the "Not yet wired into the run-all dispatch" moduledoc section with the wired statement. Zero executable change. |
| `lib/ash_a2a/chicago/bench/environment.ex` | STRING ONLY. Updates the `model_provider.reason` disclosure text from "B1/B5/B9" to "all 10 … (B1-B10)". Zero executable change. |
| `lib/mix/tasks/ash_a2a.chicago.bench.ex` | DOCS ONLY. `@shortdoc` + `--only` help text now say all 10. No switch/flow change. |

Falsification performed: every one of the 7 modules was checked against the
REAL dispatch contract — `AshA2A.Chicago.Bench.run/1` calls `module.run(opts)`
(expecting `{:ok, map()} | {:blocked, String.t()}`) and `module.id()`. All 7
(`B2LogicClosure`, `B3HookReflex`, `B4Planning`, `B6ReactiveCascade`,
`B7CrossRuntime`, `B8Replay`, `B10Recovery`) expose exactly `id/0` + `run/1`
with the same return shape as the already-wired B1/B5/B9. The predecessor did
NOT edit any module logic to force-fit; the wiring adapts to the modules.
No code edits of my own were needed — the inherited wiring was complete.

## 2. Environment enablement (no repo bytes)

- `mix deps.get` — exit 0.
- `cd native/hddl_cli && cargo build --release --locked` — exit 0 (B4's real solver; B4 honestly returns `{:blocked, …}` without it).
- `cd native/graphlaw_host && cargo build --release --locked` — exit 0, 1m44s. Optional: only widens B7 from its base pair to the full two-pair matrix (module's own availability gate).
- `mix compile` — clean, exit 0.

## 3. The gate: all 10 RFC-SA2A-002 categories in ONE invocation

`mix ash_a2a.chicago.bench --out /tmp/bench-final` — **exit 0**, run_id
`bench-f4c02071f426`, environment identity
`bf35e58106952698ef87a0a27a3f45643023cbe4880f00b7f00c32c4ce4e6e70`,
subject identity `7d03fabb5634c8edf3c865a4c76b96e824d5b707418b26c99c3e532bb22181fc`.
10/10 MEASURED, 0 invariant failures anywhere, 0 BLOCKED. Summary:
`/tmp/bench-final/summary.json`.

| category | module | iterations | key metric | status |
|---|---|---|---|---|
| B1 admission | B1Admission | 10 | total_admission p50 159.8 ms; 0.94 adm/s; 4.68 refusals/s | MEASURED, 0 inv.fail |
| B2 logic closure | B2LogicClosure | 10 | closure p50 1.103 s (real wasmtime via wasmex) | MEASURED, 0 |
| B3 hook reflex | B3HookReflex | 10 | cascade total p50 2.97 ms; hook eval p50 1.07 ms; idempotency seen p50 11 us | MEASURED, 0 |
| B4 HDDL/FOND planning | B4Planning | 10 | freedom_gym solve p50 4.50 ms; dogfood p50 16.1 ms; 39.1 solves/s, 78.1 refusals/s (real hddl_cli subprocess) | MEASURED, 0 |
| B5 authority/BRCE | B5Authority | 10 | authority decision p50 13 us; e2e authorized p50 2.02 ms | MEASURED, 0 |
| B6 reactive cascade | B6ReactiveCascade | 10 | all 6 depth/fan-out cases within bounds (e.g. cycle_d4: depth 4, 4 routes, p50 15.5 ms) | MEASURED, 0 |
| B7 cross-runtime | B7CrossRuntime | 1 | judged_pair_count=2 (WasmexSession×RuntimeB, RuntimeB×WasmtimeRuntime); p50 wall 2.18 s (base pair), 38.4 s (native pair) | MEASURED, 0 |
| B8 offline replay | B8Replay | 1 | fresh_verify p50 716 ms; max receipt chain 98 | MEASURED, 0 |
| B9 OCEL overhead | B9OcelOverhead | 10 | per-event overhead p50 231 us; 132 events, 92,719 bytes | MEASURED, 0 |
| B10 crash/recovery | B10Recovery | 1 | recovery p50 82.5 ms over all 4 crash points | MEASURED, 0 |

Content-addressed integrity spot-check (`--verify`, sha256 re-derivation):
`VERIFIED SA2A-B4`, `VERIFIED SA2A-B7` (and earlier `VERIFIED` on run-1's
B10/B7). Exit 0.

Earlier runs this session (also 10/10 MEASURED, exit 0): `/tmp/bench-full-run`
(B7 with 1 pair — graphlaw_host not yet built) and `/tmp/bench-full-run-2`
(B7 with both pairs). Note: run 1's mid-run GenServer "killed" log lines are
B10's own deliberate crash-point teardown (the EKV chaos environment is
killed on purpose — that is the benchmark subject), not failures.

## 4. Architecture verifier + full suite

- `mix ash_a2a.verify_architecture` — **17/17 architecture checks passed**
  (incl. Chicago courts SA2A-AUTH 21/21, CHI-RECEIPT 30/30, CHI-REPLAY 9/9,
  SA2A-HOOK 12/12, SA2A-OCEL 21/21 falsifiers real-corroborated-passed).
- `mix test --max-cases 6` — first run: 5 failures / 14 invalid — but that
  run was CONTAMINATED BY ME: I ran bench invocations and native builds
  concurrently with the suite. Re-run clean and serial (nothing else
  executing):
  **2089 tests, 3 failures, 0 invalid, 1 skipped (17 excluded)**, ~11.5 min.
  - All 3 failures = `AshA2A.GraphLawVendorToolVersionCwdTest` — the exact
    pre-existing flake named in the dispatch (`/private/var` vs `/var`:
    macOS `/tmp` symlink prefix; `Path.expand` does not resolve symlinks).
    Deterministic on this host, pre-existing on main, unrelated to bench
    wiring; not fixed here (out of scope-item-3 scope; flagged for the
    defect/triage owner).
  - `SemanticRefusalTest` `:hddl_solve_error` — did NOT hit.
  - `:eaddrinuse` — did NOT hit.
  - With graphlaw_host built, `AshA2A.GraphLaw.WasmtimeRuntimeTest` compiles
    in its REAL wasm-execution branch (test count 2066 → 2089) and passes.
  - First-run-only artifacts (ArchitectureVerifierTest 60 s timeout; 3
    setup_all DBConnection pool drops; the compiled-not-built/runtime-built
    skew in WasmtimeRuntimeTest) all cleared on the clean serial run —
    contention-induced, not code.

## 5. Attribution (inherited vs new) + 比

- Inherited from predecessor (uncommitted at handoff), judged correct and
  committed as-found: 4 files, +43/−20 lines — `bench.ex` (wiring),
  `b6_reactive_cascade.ex` (docs), `environment.ex` (docs string),
  mix task (docs).
- Written by A4r this session: **0 bytes of lib/test code**. New file:
  this WAVE-RECEIPT.md only (workflow receipt, not 産面 product code).
- 比 on this change's delivered lines: manufactured-by-pack/generator = 0;
  hand-authored = 4 wiring/doc files (100% inherited). Honest statement:
  scope item 3 was a hand-authored wiring change by design (no pack owns
  ash_a2a's bench dispatch); A4r's contribution is falsification,
  environment enablement, execution and this receipt — the operator and
  this agent each wrote zero new product bytes beyond the inherited edit.

## 6. Falsifiers attempted

1. "Do the 7 modules match the dispatch contract?" — checked `id/0` + `run/1`
   + return shapes on all 7 vs B1/B5/B9: match. Survives.
2. "Did the predecessor edit module logic to force-fit?" — full `git diff`
   read line by line: docs/string-only outside `bench.ex`. Survives.
3. "Does one invocation really run all 10 with real numbers?" — observed
   3× this session (10/10 MEASURED, 0 invariant failures, exit 0). Survives.
4. "Are the numbers real, not mocks?" — B4 drives the real hddl_cli
   subprocess (sha256 of binary recorded in the raw result); B2/B3/B6 drive
   real wasmtime/wasmex; B7 ran TWO real host pairs; raw records are
   content-addressed and `--verify` re-derivation passes. Survives.
5. "Is the suite green independent of my concurrent load?" — contaminated
   run discarded; clean serial re-run isolates the one known pre-existing
   flake. Survives.
6. "Does the wiring break the harness tests?" — `bench_harness_test.exs`
   pins `--only B5,B9` and single-module behavior only; passed in both suite
   runs. Survives.

## 7. Remaining (honest)

- `GraphLawVendorToolVersionCwdTest` /private/var — pre-existing, hit,
  triaged not fixed (owner: defect/triage scope, not bench wiring).
- `Courts.Benchmarks` (SA2A-BENCH qualification court) still runs its own
  hardcoded B1/B5/B9 falsifier set (SA2A-BENCH-001..003). Scope item 3 names
  `@benchmarks` + the mix task only; extending the court means AUTHORING 7
  new falsifier definitions (invariants/predicates), which is new court
  authorship, not wiring — left for its own ticketed scope.
- Ticket scope items 1, 2, 4 (two defects + push main) — other worktrees/
  coordinators.
