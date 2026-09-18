# Chicago Benchmark Report (RFC-SA2A-002)

This is a real, measured run of `mix ash_a2a.chicago.bench` against this
exact checkout -- not a description of the harness. `chicago-conformance-court.md`
covers what the Chicago court and its benchmark courts are; this document
reports one concrete run's numbers and the environment they were measured
in.

## Exact subject

- Repo: `ash_a2a`, branch `main`
- Commit measured against: `9ef801e` (docs: record the completed
  RFC-SA2A-002 Chicago court in CHANGELOG + explanation)
- `subject_identity`: `ad0f57192fed79c50cce4128ab6d1221770a8c6ecb6955ca3024e3beb282684b`
- `environment_identity`: `395a22286f23be0e770d75b5eb679298dbf4aeb8ab8cb465f2ae0cc958adb150`
- `run_id`: `bench-2369d7f7170e`
- Command: `mix ash_a2a.chicago.bench --iterations 10 --out <dir>`
  (default `--warmup 2`; `--iterations 10` is a small run for a real,
  reproducible measurement -- not a statistically rigorous sample; see
  Caveats below)
- Each raw result is content-addressed (`SA2A-<id>.<sha256>.json`) and
  re-verifiable with `mix ash_a2a.chicago.bench --verify <path>`, which
  re-derives the digest from disk and exits non-zero on mismatch (RFC
  S135). All three digests below were produced by this run, not hand-typed.

## Environment receipt (RFC S102)

| Field | Value |
|---|---|
| CPU | Apple M3 Max, 16 logical / 16 physical (12 performance + 4 efficiency cores) |
| BEAM schedulers online | 16 (16 dirty-CPU schedulers online) |
| OS | macOS 26.2, Darwin kernel 25.2.0, arm64 |
| Elixir | 1.19.5 |
| OTP release | 28 (ERTS 16.2), JIT emulator, opt build |
| Ash | 3.33.1 |
| ash_a2a | 26.9.14 |
| wasmex | 0.15.1 |
| wasmtime CLI | wasmtime 48.0.1 (7bac2c277 2026-08-24) |
| GraphLaw WASM host runtime | node v26.8.1 |
| GraphLaw WASM sha256 | `187688d9e7e33a575713d6911d75687adb38713ed37412e211af263dfcbe0c28` |
| Total host memory | 51,539,607,552 bytes (~48 GiB) |
| Free memory at capture | 3,912,761,344 bytes (~3.6 GiB) |
| Filesystem | APFS, internal Apple Fabric SSD |
| Network topology | single BEAM node; GraphLaw via local subprocess; no network hop |
| Container | none detected (darwin host, no Linux cgroup limits) |

Captured at `2026-09-17T06:38:51Z`. Full receipt (including BEAM limits,
per-process reduction counts) is embedded verbatim in each raw result
under `raw_result.environment`.

## B1 -- admission latency and throughput

Status: **MEASURED**, 10 iterations, 2 warmup, 0 invariant failures.

- `total_admission` latency (us), n=60 (6 admission cases x 10 iterations):
  p50=110015, p90=175381, p95=196087, p99=215246, max=215246, mean=120798.6,
  stddev=33902.3
- Throughput: 1.38 admissions/s, 6.9 refusals/s, 8.28 candidates/s overall
  (10 admitted, 50 refused across the case matrix; wall=7,248,995us)
- Per-phase breakdown (one representative case,
  `invalid-falsifier-forbidden`, us): parse p50=101662 (dominant cost),
  rule_closure p50=4082, shex p50=8378, shacl p50=4187, identity p50=168,
  sparql_falsifiers p50=10, finalize p50=1
- Memory: total heap delta -13,824 bytes across the run (GC-dominated,
  not a leak signal at this iteration count)
- Raw result: `SA2A-B1.b0782c135a9e857849b7e18e3796e833c14c12c3b77673fbe5e81a43e621791f.json`
  (31,986 bytes)

Parse dominates B1's wall time by roughly an order of magnitude over every
other phase; the Turtle/RDF parse step, not SHACL/ShEx/rule-closure
admission logic, is the actual latency floor at this corpus size.

## B5 -- authority decision / BRCE end-to-end

Status: **MEASURED**, 10 iterations, 2 warmup, 0 invariant failures.

- End-to-end authorized-path latency (us), n=50: p50=329, p90=2483,
  p95=2732, p99=4957, max=4957, mean=794.8, stddev=1023.3
- Highlights: `authority_decision_p50_us`=15,
  `authorized_end_to_end_p50_us`=2483, `authorized_end_to_end_p99_us`=4957,
  `prepared_receipt_durability_p50_us`=1321
- Baseline-arm phase breakdown (us, p50): authority_decision=16,
  bus_admission=161, actuator=230, independent_postcondition=259,
  final_receipt=378, prepared_receipt_durability=1008,
  end_to_end=2044
- Throughput: 1210.8 samples/s (wall=41,295us for the full arm matrix)
- Memory: total heap delta +411,880 bytes across the run
- Raw result: `SA2A-B5.e9ee6ab968d282974cbbf85a3e09a4ab842f01922cb725186abd6d25b31ef03b.json`
  (23,402 bytes)

The authority decision itself (15-16us p50) is negligible against the
end-to-end path; `prepared_receipt_durability` (disk fsync of the prepared
receipt before actuation) is the largest single phase, consistent with
BRCE's durability-before-actuation ordering being disk-bound rather than
compute-bound.

## B9 -- OCEL overhead

Status: **MEASURED**, 10 iterations, 2 warmup, 0 invariant failures.

- Baseline (no OCEL observer attached) end-to-end latency (us), n=10:
  p50=2044, p90=2783, p95=4970, p99=4970, max=4970, mean=2415.3
- With-OCEL arm latency (us), n=10: p50=1804, p90=2119, p95=2312,
  p99=2312, max=2312, mean=1838.8
- OCEL overhead delta (with-OCEL minus baseline, us): p50=-240, p90=-664,
  p95=-2658, mean=-576.5 -- **negative** at this iteration count (see
  Caveats)
- OCEL artifact: 132 events, 64 objects, 702 bytes/event, 92,659 bytes
  serialized (`serialization_us`=13235), validated
  (`AshA2A.Chicago.Ocel.Validator`, status=valid, 19,582us)
- Query-load predicates, all `holds: true`: `prepared_before_actuation`
  (12 `brce.actuate.start`, 0 missing an earlier `brce.prepare` sharing
  the command; 67us), `commit_after_actuation` (12 `brce.commit`, 0
  missing an earlier `brce.actuate.stop`; 57us), `no_failed_commit`
  (0 failed commits observed; 6210us)
- `vm_reductions_delta`=140305, `vm_runtime_ms_delta`=0
- Throughput: 532.08 samples/s (wall=18,794us)
- Raw result: `SA2A-B9.676a2b5025569b60f148e981a325e10fe5a6261401ba3b43ca27ff67f797449c.json`
  (19,635 bytes)

## B2 -- logic closure (RDF rule-closure fuel/wall/memory)

Status: **MEASURED** (v26.9.17 harden/benchmark pass,
`feat/bench-b2-logic-closure`, commit `ff3d2eb`). 10 iterations, 2
warmup, real in-BEAM Wasmtime engine (`AshA2A.GraphLaw.WasmexSession`)
-- a different transport from B1's subprocess-based
`AshA2A.GraphLaw.Wasm`.

- `shallow` (200 facts, non-recursive): derived_count=200,
  fuel_consumed p50=88,015,677, engine_wall p50=10,956us,
  peak_memory p50=2,424,832 bytes
- `recursive` (40-node transitive chain): derived_count=741,
  fuel_consumed p50=123,865,831, engine_wall p50=17,830us,
  peak_memory p50=2,752,512 bytes
- `near_bound` (90-node transitive chain): derived_count=3916,
  fuel_consumed p50=1,142,195,342 (57.1% of fuel budget), engine_wall
  p50=95,150us, peak_memory p50=17,563,648 bytes
- Cross-case: total_closure p50=1,522,565us, p99=2,169,496us, 0.63
  closures/s. `fuel_deterministic`=true and `closure_digest_stable`=true
  on every case; derived counts verified arithmetically against
  `LogicSparql.chain_derived/1`; 0 invariant failures across two
  independent runs.
- **Not yet wired into `Bench.@benchmarks`** (shared-file scope
  boundary) -- run directly via
  `AshA2A.Chicago.Bench.B2LogicClosure.run/1`, not yet through
  `mix ash_a2a.chicago.bench`.

## B3 -- Knowledge Hook reflex latency

Status: **MEASURED** (`feat/bench-b3-hook-reflex`, commit `b2451b0`).
20 iterations, 3 warmup, 4 cases, 0 invariant failures across all 80
samples.

- `hook_evaluation` p50=5,738us; `intent_construction` p50=20us;
  `idempotency_check` (new delta) p50=11us vs (seen/replay) p50=21us;
  `cascade_total` p50=12,069us (pooled)
- `no_match_control`: 1 hook evaluated, 0 fired, cascade_total
  p50=2,957us. `single_match`: 1/1 fired, 1 Signal row, cascade_total
  p50=10,174us. `multi_match_within_bound`: 2/2 fired within the
  fan-out ceiling, 2 Signal rows, cascade_total p50=22,577us.
  `replay_same_delta`: idempotency outcome `:new` then `:seen`, same
  intent_id both deliveries, exactly 1 Signal row after 2 deliveries
  (no duplicated consequence).
- **Not yet wired into `Bench.@benchmarks`** (same shared-file
  boundary as B2).

## B4 -- HDDL/FOND planning invocation

Status: **MEASURED** (`feat/bench-b4-planning`, commit `9d5549b`).
10 iterations, 2 warmup, real `hddl_cli` subprocess boundary, 0
invariant failures across 30 samples.

- `freedom_gym_meeting` (solved, real 6-step FOND policy):
  planner_invocation p50=4,686us, p99=5,632us
- `unsolvable_qualification` (refused, `:hddl_solve_error`, real
  NoPlan): p50=4,145us, p99=5,703us
- `sa2a_v26_9_17_dogfood` (refused, real NoPlan, ~60x larger domain/
  problem than the small fixtures): p50=16,737us, p99=19,291us
- Overall: 112.69 samples/s, 37.56 solves/s, 75.13 refusals/s.
  Plan-admission latency (an RFC S88-named measure) is honestly
  reported as **not measured** -- no admission pipeline exists
  downstream of the planner boundary in this repo today.
- **Not yet wired into `Bench.@benchmarks`** (same shared-file
  boundary as B2/B3).

## B6 -- reactive cascade

Status: **MEASURED** (`feat/bench-b6-reactive-cascade`, commit
`486336c`). 10 iterations, 2 warmup, real GraphLaw wasm engine, real
`CommandBus`/`Authority.Broker.InMemory`/`ReceiptStore.Memory`/ETS
`Signal` resource, 0 invariant failures across 18 samples/case.

- `cycle_d1_f1_p1` p50=6,510us; `cycle_d2_f1_p1` p50=10,307us;
  `cycle_d4_f1_p1` p50=20,292us; `tree_d2_f2_p1` p50=73,147us;
  `tree_d2_f2_p2` p50=71,170us; `wide_d1_f4_p4` p50=42,677us
- Every case: ETS `Signal` row-count delta exactly equals
  `HookReactor.Result`'s reported committed-route count; the
  `generations == depth_reached + 1` invariant held on all 6 cases,
  including bound-exhausted ones.
- **Not yet wired into `Bench.@benchmarks`** (same shared-file
  boundary as B2/B3/B4).

## B7 -- cross-runtime portability

Status: **MEASURED, partial coverage** (`feat/bench-b7-b8-b10-extraction`,
commit `e650e14`). `native_runtime_available=false` in this
environment, so only the base pair (`WasmexSession` judged against
itself) ran rather than the full cross-runtime matrix -- 1 judged
pair, not a full runtime comparison.

- wall p50=p99=5,195,869us (~5.2s); fixture_count=10,
  admission_equivalence_count=10, post_state_equivalence_count=10,
  disagreements=[] (none observed on the pair that did run)
- **Not yet wired into `Bench.@benchmarks`**.

## B8 -- offline replay

Status: **MEASURED** (same commit `e650e14` as B7/B10). Receipt-chain
sizes [2, 8, 32], 0 external ledger writes on any replay
(`zero_external_consequence=true` for all 3 sizes).

- n=2 (chain_length=8): fresh_verify p50=136,249us,
  in_vm_verify p50=6,639us, fresh_startup p50=549,931us
- n=8 (chain_length=26): fresh_verify p50=171,387us,
  in_vm_verify p50=9,834us, startup p50=846,616us
- n=32 (chain_length=98): fresh_verify p50=154,324us,
  in_vm_verify p50=32,859us, startup p50=984,570us
- **Not yet wired into `Bench.@benchmarks`**.

## B10 -- crash/recovery (RFC S70 crash points)

Status: **MEASURED** (same commit `e650e14` as B7/B8). All 5 real RFC
S70 crash points reached, 0 repeated external effects on any of them.

- `before_receipt_preparation`: not_attempted (recovery 278.5ms --
  expected, crash before any anchor)
- `after_preparation_before_external_call`: reconciled (273.9ms)
- `during_external_call`: reconciled (64.7ms)
- `after_external_response_before_finalization`: reconciled (563.9ms)
- `after_finalization_before_acknowledgement`: executed (1,061.8ms)
- **Not yet wired into `Bench.@benchmarks`**.

RFC-SA2A-002 names 10 benchmark categories; before this pass only 3
(B1/B5/B9) had a real standalone bench module. All 10 now have a real
module producing real numbers (B2/B3/B4/B6/B7/B8/B10 above); the 7 new
ones are not yet wired into `Bench.@benchmarks`/the mix task -- a
real, disclosed integration gap left to a follow-up merge, not
overclaimed as done.

## Caveats

- **Iteration count**: `--iterations 10` (RFC default is higher) is
  deliberately small, per the request driving this report -- this is a
  real measured run of the actual harness against this actual checkout,
  not a statistically rigorous benchmark. p99/max at n=10-60 are single
  outlier samples, not stable tail estimates; don't treat any p99 above
  as a SLA figure.
- **B9's negative overhead**: attaching the OCEL observer measured
  *faster* than the no-observer baseline arm (p50 -240us). At n=10 this
  is scheduler/JIT/GC jitter between two small, separately-run arms, not
  evidence that OCEL instrumentation has negative cost. A larger
  `--iterations` run is needed before this delta means anything either
  way; it is reported as measured, not smoothed or discarded.
- **B1 case mix**: the 60-sample B1 distribution mixes six admission
  cases (mostly refusal paths -- `invalid-*`) whose costs differ by an
  order of magnitude (e.g. `invalid-falsifier-forbidden` at ~121ms p50
  vs `invalid-parse-not-turtle` at ~95ms p50); the pooled p50/p90/p99
  above are across all cases, not any single case's own distribution.
- Each of B1/B5/B9 individually reports `invariant_failure_count: 0` --
  no BRCE/authority/OCEL invariant was violated during this run.

## Reproducing this run

```
mix ash_a2a.chicago.bench --iterations 10 --out <output-dir>
mix ash_a2a.chicago.bench --verify <output-dir>/SA2A-B1.<sha256>.json
mix ash_a2a.chicago.bench --verify <output-dir>/SA2A-B5.<sha256>.json
mix ash_a2a.chicago.bench --verify <output-dir>/SA2A-B9.<sha256>.json
```

## Hardening findings (v26.9.17 harden/benchmark/stress pass)

Six adversarial hardening tasks ran against already-shipped v26.9.17
code. Four returned a clean bill of health (no real defect found);
two found a real production defect, both correctly left unfixed in
this pass because the fix lives in a file shared with other parallel
worktrees (flagged for the serial MergeVerify/integration phase
rather than risked as an uncoordinated edit).

- **Concurrency races** (`feat/harden-concurrency-races`, commit
  `3d624ef`): "No real race found. ... In every case exactly one real
  winner ..., every loser a clean typed refusal (`:in_flight`,
  `:command_conflict`, `:actuation_in_flight`, or `:token_id_taken`),
  and no poller ever observed a resurrection (true after false) once
  a revoke landed." Clean bill of health across `CommandBus.run/4`
  command-id races, the S55 actuation-claim index, and
  `Authority.Broker.InMemory` grant/revoke races.
- **Crash boundaries** (`feat/harden-crash-boundaries`, commit
  `ec5b102`): "No production module needed a fix" -- the one apparent
  gap (an immediate resubmission after a claim-only crash not being
  instantly reclaimable) turned out to be the documented, deliberate
  300s `ClaimLease` liveness/safety tradeoff, not a defect; the
  test's own first-draft assumption was wrong, not the production
  code.
- **Mock/Dialyzer audit** (`feat/harden-mock-dialyzer-audit`, commit
  `17e1900`): 0 mock violations found; architecture verifier 15/15
  twice; Dialyzer shows 0 new warning classes introduced by this
  session's new code (7/123 warnings on 2 new files, both instances
  of pre-existing warning classes that already occur identically on
  old sibling files).
- **Bounds exhaustion** (`feat/harden-bounds-exhaustion`, commit
  `796b859`): "No genuine bypassable defect exists in
  `AshA2A.Semantic.Bounds` or `AshA2A.Semantic.Allocator` today"
  across 15 tests + 10 property-based tests attempting self-grant/
  widening, fan-out/depth/parallelism overshoot, and delegated-
  capability escalation (confused-deputy and structural-injection
  variants) -- every attempt failed closed with a typed refusal on
  the first real run.
- **Adversarial input** (`feat/harden-adversarial-input`, commit
  `dfc1dcc`) -- **real defect, unfixed, flagged for MergeVerify**:
  over a real HTTP JSON-RPC round trip, `AshA2A.Semantic.Peer.
  admit_candidate/2` has no parse-stage triple-existence witness
  equivalent to `AdmissionPipeline`'s -- syntactically-garbage,
  non-Turtle content parses to zero triples and is **silently
  ADMITTED** (SHACL passes vacuously against a receiving peer's own
  shape). All 12 other adversarial classes tested (missing fields,
  wrong types, forged standing history, digest mismatch, oversized/
  malformed payloads, invalid UTF-8) produced correct typed refusals.
  Recommended fix: port the same parse-witness pattern
  `AdmissionPipeline` already uses into `Peer.admit_candidate/2`
  (`lib/ash_a2a/semantic/peer.ex`, a shared file outside this pass's
  per-agent scope).
- **Adapters** (`feat/harden-adapters`, commit `8f7a0bc`) -- **real
  defect, unfixed, flagged for MergeVerify**: the shipped
  `test/support/command_worker.ex` (`AshA2A.Test.Support.
  CommandWorker`) calls `ObanAuthority.reconstruct/2` but never
  `verify_live!/3` before dispatching -- it fails closed on an
  expired authority but **does not fail closed on a
  revoked-but-unexpired authority**, proven via a real `Ash.create`
  actuating through the shipped worker against a real revoked grant.
  A second, in-scope defect was found and fixed within this same
  task: a naive unconditional `verify_live!/3` gate (this agent's own
  first draft) broke legitimate Oban at-least-once redelivery of an
  already-durably-receipted command; fixed by peeking the receipt
  store before gating on live authority (skip re-verification only
  when a receipt for the command already exists). Recommended fix for
  the shared file: apply the same receipt-peek-before-verify_live!
  ordering to `test/support/command_worker.ex`.

## Stress test results (v26.9.17 harden/benchmark/stress pass)

- **Sustained throughput** (`feat/stress-sustained-throughput`,
  commit `15908d2`, merged): real, measured
  tail-latency-climbs-under-sustained-load pattern in
  `CommandBus.run/4` -- three real 12s runs, 16 concurrent workers,
  34,881 total real dispatches (14,104 / 3,276 / 17,501), **0 errors
  and 0 process-count leak** across all of them. Late-half p50 was
  1.26x-1.44x early-half p50 and late-half p99 was 1.70x-181.3x
  early-half p99 in every run; one run's late half collapsed to an
  8.5-second p50 on 17 samples. Full detail (including the disclosed
  shared-host-contention confound: `uptime` load average 12-18 on a
  16-scheduler host) in `v26.9.17-stress-report.md`.
- **Multinode concurrency** (`feat/stress-multinode-concurrency`,
  commit `9bf9836`, merged): 6 real `:peer`-started BEAM nodes,
  genuinely concurrent dispatch (`Task.async`/`await_many`, not
  sequential `:erpc.call`); per-node counts and the merged aggregate
  exactly matched every real input across 5 repeated `--seed` runs,
  67.7-101.5 dispatches/s aggregate, 0 failures, 0 flakiness.
  Surfaced **two real defects in code outside this task's scope**,
  both documented in the test's own moduledoc for MergeVerify rather
  than fixed here: (1) `HddlSolver.run/4`'s temp-file naming
  (`System.unique_integer/1`-only) collides across independent
  host-local `:peer` VMs sharing one filesystem -- reproduced a real
  crash before an in-scope mitigation (pre-advancing each peer's
  counter into a disjoint band) was added; (2)
  `AshA2A.Telemetry.RouterCounters` is not caller-isolated when two
  instances are attached concurrently on the same node --
  `:telemetry.execute/3` broadcasts to every attached handler, so
  concurrent `drive_and_report/3` calls cross-contaminate counts
  (reproduced with an exact count mismatch), contradicting that
  module's own moduledoc claim of independence.
- **Resource ceiling** (`feat/stress-resource-ceiling`, commit
  `46cf2d1`, merged): 130 real `Episode.delegate/2` delegations
  against a root envelope with a real executions ceiling of 100 --
  terminated lawfully (`:bounds_delegation_not_narrowing`) at exactly
  the 101st attempt, `committed == 100` matched by an independently-
  read real ETS row count of 100 (no leak past the ceiling).
  `Episode.max_ceiling/0` boundary (`9_223_372_036_854_775_807`)
  admitted exactly at the edge, refused one past it. A real defect
  was root-caused **in this task's own first test draft** (a missing
  `:control` key masked the intended ceiling-exhaustion path behind
  an unrelated `:unbounded_production_operation` refusal) and fixed
  within scope before the numbers above were captured.

Merge of all six harden branches, five bench branches, and three
stress branches completed clean, `--no-ff`, no conflicts; final head
`fea05cd`. Post-merge full suite: 58 doctests, 29 properties, 2086
tests total; 1-2 failures observed across repeated runs, in different
tests each time (`AshA2A.SemanticRefusalTest`'s `:hddl_solve_error`-
mapping check, and an `:eaddrinuse` port-bind race under
`--max-cases 6`) -- confirmed pre-existing on `main` before this
merge (the merge's own diff touched no `lib/` files, so it cannot
have introduced either), not a regression from this harden/benchmark/
stress pass.

## See Also

- `chicago-conformance-court.md` -- what the Chicago court is and why it
  exists as a falsification court rather than a test suite
- `lib/mix/tasks/ash_a2a.chicago.bench.ex` -- the mix task run for this
  report
- `docs/rfc/RFC-SA2A-002-v26.9.16.md` -- S102 (environment receipt), S135
  (raw-result digest verification)
- `v26.9.17-stress-report.md` -- full sustained-throughput/multinode/
  resource-ceiling stress detail behind the "Stress test results"
  summary above
- `v26.9.17-hardening-audit.md` -- the mock/Dialyzer audit behind the
  "Hardening findings" section's mock/Dialyzer entry
- `CHANGELOG.md` -- `[Unreleased]` entry for this pass
