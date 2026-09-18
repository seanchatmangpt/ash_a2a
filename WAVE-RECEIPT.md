# WAVE-RECEIPT — agent A6, ticket b4p-f5-02 (ash_a2a), scope items 2 + 3

Date: 2026-09-18 · Session: A6 of the 10-agent DfCM wave · Worktree:
`/Users/sac/ash_a2a-wt/f5-02-tail-counters` (isolated; no writes to
`/Users/sac/beam4pm`)

## Standing

**ALIVE** for both scoped items — every claim below is an observed
execution in this session, against the exact subjects, with fail-before
and pass-after evidence. Ticket-level standing stays with the coordinator
(item 1 = HddlSolver belongs to a sibling agent; the beam4pm consumption
gate runs after the branches merge upstream).

## Base + branches + SHAs

| branch | base | HEAD | scope |
|---|---|---|---|
| `fix/commandbus-tail-latency` | ash_a2a main `fa51fc8` | `f68bde4` | item 2 (tail latency) |
| `fix/router-counters-isolation` | `f68bde4` (branched off item 2 per ticket) | `255d3dc` (9f47af4 + docs 255d3dc) | item 3 (RouterCounters) |

Commits: `f68bde4` test(commandbus): standing tail-latency SLO tripwire ·
`9f47af4` fix(telemetry): RouterCounters per-emitter isolation via
`attach!/3 :owner` · `255d3dc` docs: CHANGELOG + stress-report
reconciliation.

## Commands + exits (all run in this session, this worktree)

| command | exit | result |
|---|---|---|
| `mix deps.get` | 0 | deps resolved |
| `cargo build --release --locked` (native/hddl_cli) | 0 | binaries built |
| `mix compile --warnings-as-errors` | 0 | clean |
| `mix test test/ash_a2a/telemetry/router_counters_isolation_test.exs` (BEFORE fix) | nonzero | **3 tests, 2 failures — real contamination numbers** |
| same (AFTER fix) | 0 | 3 tests, 0 failures |
| `mix test test/ash_a2a/planning/request_router_telemetry_test.exs test/ash_a2a/telemetry/allocation_counters_test.exs` | 0 | 14 tests, 0 failures (backward compat incl. the pre-existing two-instance replica-semantics test) |
| `mix test test/ash_a2a/multinode_router_counters_test.exs` | 0 | 1 test, 0 failures (2 real peers, owner-scoped helper, exact counts unchanged) |
| `ASH_A2A_STRESS_DURATION_MS=6000 ASH_A2A_TAIL_TRIPWIRE_FORCE_X=10 mix test .../commandbus_tail_latency_tripwire_test.exs --include benchmark` | nonzero | **TRIPPED: ratio 12.158x > 3.0 (fail-before)** |
| unforced tripwire, 3 runs | 0 (x3) | ratios 0.497 / 0.831 / 0.468 — PASS, PASS, PASS |
| `mix test test/ash_a2a/chicago/stress/tail_latency_diagnostic_test.exs --include benchmark` | 0 | 12 s, 16 workers, 3,719 dispatches, 0 errors + sampler evidence (below) |
| `mix format --check-formatted` (all touched files) + `mix compile --warnings-as-errors` | 0 | clean |
| `mix test --max-cases 6` (full suite, twice) | 2 (failures only the pre-existing GraphLawVendorToolVersionCwdTest host issue — reproduced on base `fa51fc8`) | counts below |

## Item 2 — CommandBus.run/4 tail latency: BOUNDED (SLO + standing tripwire)

### SLO (documented in `AshA2A.CommandBus`'s moduledoc and the tripwire's)

Under sustained concurrent load: `degradation_ratio_p99 = late_half_p99 /
early_half_p99 <= 3.0`, zero dispatch errors. Bound rationale: 2x headroom
over the worst non-pathological Memory-store measurement (1.274x / 1.515x /
1.391x in `docs/explanation/v26.9.17-commandbus-scale.md`), vs the
pathological 181x observed under external host contention (load 12-18 on
16 schedulers, `docs/explanation/v26.9.17-stress-report.md`).

Standing tripwire:
`test/ash_a2a/chicago/stress/commandbus_tail_latency_tripwire_test.exs`
(`:benchmark` tag, same convention as its sibling stress files), which also
reports max store-mailbox length and outbox depth with every run.

### Fail-before / pass-after

- Fail-before (forced 10x-worse synthetic, `ASH_A2A_TAIL_TRIPWIRE_FORCE_X=10`,
  6 s window, load ~91): `degradation_ratio_p99 = 12.158` →
  `TAIL-LATENCY SLO TRIPPED ... > 3.0` — the tripwire demonstrably fails on
  the pattern it guards.
- Pass-after (unforced): ratio 0.497 (12 s, load ~40-66), 0.831 (12 s,
  8,601 dispatches, 0 errors, load ~43), 0.468 (12 s, 14,841 dispatches,
  0 errors, load ~43) — all PASS with 4x+ margin.

### Mechanism diagnosis (evidence, not guess)

Diagnostic harness (temporary, not landed) = the stress wave's sustained
harness + a 200 ms sampler (store mailbox length, `ReceiptOutbox.count()`,
BEAM run queues) + per-quarter latency:

- Store mailbox length: ~0 at every sample across 12 s (single transient
  16); **no queue accumulation** — the "single-GenServer mailbox queue
  grows through the run" candidate is falsified at these loads.
- Outbox: 0 before → 0 after, peaks <= 15 (in-flight-bounded);
  **no debris/reconcile-cost growth** — that candidate is falsified too.
- The climb is real but BROAD (mean 39.7 -> 78.3 ms, per-quarter throughput
  1,225 -> 623 dispatches, p50 18.1 -> 72.6 ms) under host load ~84 — it
  tracks external host contention, amplified tail-specifically when the
  shared store GenServer is descheduled and all 16 workers queue behind it
  at once (the Ekv-vs-Memory differential in the scale doc isolates exactly
  this amplification: per-key CAS store, no shared mailbox, ratios
  0.812x-1.072x vs Memory's consistent 1.27x-1.52x).

Conclusion: **no unbounded in-SUT state growth exists to fix** on this
evidence; the 181x observation was host contention, and the residual
Memory amplification is a documented architectural trade with an existing
config-level remedy (`:receipt_store, AshA2A.ReceiptStore.Ekv`). Bounding
— not a rewrite of a battle-tested store — is the tractable, honest path,
and the ticket explicitly allows it.

## Item 3 — RouterCounters contamination: FIXED

### Mechanism

`:telemetry.execute/3` broadcasts `[:ash_a2a, :router, :tier_selected]` to
EVERY attached handler on the node; `RouterCounters` scoped storage per
instance but not event SOURCE, so overlapping instances each counted the
other's dispatches (the stress wave hit this for real and had to prune
`@dispatches_per_node` to 1). Fix = `attach!/3` with `owner:` (`:any`
default = unchanged historical semantics; a pid counts only its own
process's events) — the exact design `AshA2A.Telemetry.AllocationCounters`
already shipped for the identical broadcast problem. A per-instance
metadata token through `RequestRouter`'s opts was considered and rejected
(wider public-API change, no in-repo precedent) — recorded in the
moduledoc per the failed-edge rule.

### Fail-before (unfixed code, real contamination — not an API crash)

Two concurrent `Task.async` drivers, each 2 facts + 1 phrase dispatch:

```
1) test ...disjoint telemetry...
   code: assert counts_a == %{deterministic: 2, llm: 0, phrase: 1}
   left: %{deterministic: 4, phrase: 2, llm: 0}   <-- both drivers' events in each ref
2) test ...a pid-scoped instance never observes another process's dispatches
   left: %{deterministic: 1, phrase: 0, llm: 0}   <-- other process's event counted
   right: %{deterministic: 0, phrase: 0, llm: 0}
3 tests, 2 failures
```

(The test deliberately falls back to unscoped `attach!/1` when `attach!/3`
is absent so the fail-before shows the DEFECT, not an UndefinedFunctionError.)

### Pass-after (fixed code)

Same test file: `3 tests, 0 failures` — each driver's ref reads exactly
`%{deterministic: 2, llm: 0, phrase: 1}` (disjoint), the scoped probe stays
at zero while another process routes, and the default `:any` scope keeps
counting every emitter (production/replica semantics preserved).
Backward compat: 14 tests across `request_router_telemetry_test.exs` +
`allocation_counters_test.exs` green, incl. the pre-existing
"two independently-attached instances" test; the 2-real-peer
`multinode_router_counters_test.exs` exact counts unchanged with the
owner-scoped `drive_and_report/3`.

## Files changed

Item 2 (`f68bde4`):
- `test/ash_a2a/chicago/stress/commandbus_tail_latency_tripwire_test.exs` (new, 370 lines)
- `lib/ash_a2a/command_bus.ex` (+24: SLO moduledoc section)

Item 3 (`9f47af4`):
- `lib/ash_a2a/telemetry/router_counters.ex` (attach!/3 `:owner`, handler config, moduledoc truthing)
- `test/ash_a2a/telemetry/router_counters_isolation_test.exs` (new, 173 lines)
- `test/support/multinode_router_counters.ex` (+7/-1: `owner: self()`)
- `test/ash_a2a/chicago/stress/multinode_concurrency_test.exs` (defect section marked RESOLVED)

Docs (`255d3dc`, both items):
- `CHANGELOG.md` ([Unreleased]: Fixed + Added entries)
- `docs/explanation/v26.9.17-stress-report.md` (status banner: bounded / fixed)

## Full suite (`mix test --max-cases 6`, branch tip `255d3dc`)

Two full runs, both in this session:

- Run 1 (host load 40-90): **58 doctests, 29 properties, 2069 tests,
  3 failures, 14 invalid, 1 skipped (19 excluded)** in 597.1 s. (Log kept
  only the tail; failure identities not captured for this run. The 14
  invalid did not recur in run 2 — consistent with load-race setup
  failures, not deterministic breakage.)
- Run 2 (complete log): **58 doctests, 29 properties, 2069 tests,
  3 failures, 1 skipped (19 excluded)**, exit 2. All 3 failures are the
  SAME file: `AshA2A.GraphLawVendorToolVersionCwdTest` (3 of its 8 tests)
  — a macOS tmpdir symlink mismatch (`/private/var/folders/...` vs
  `/var/folders/...` after `Path.expand/1`) in vendor-tool cwd provenance
  assertions, a surface none of this session's files touch.

Pre-existing proof: on base `fa51fc8` (my changes checked out), the same
file alone reproduces **8 tests, 3 failures** — the failures exist without
this session's diff. The two ticket-named known flakes
(`SemanticRefusalTest` `:hddl_solve_error`; `:eaddrinuse` port-bind race)
were NOT hit in either run. Net: no regression attributable to items 2+3.

## 比 (ratio, reported truthfully)

Generator-manufactured lines on this surface: **0**. No admitted pack or
generator in the marketplace expresses ash_a2a benchmark/telemetry/library
code; this is upstream OSS library work authored directly, so
`ratio = 0% manufactured / 100% hand-written` for the 715 inserted lines.
No UNSUPPORTED ledger exists in this repo for this surface (the 帳 applies
to consumer repos' projections, not to upstream library authorship);
recorded here rather than papered over. What the operator did NOT write:
everything in this receipt — both fixes, both fail-before demonstrations,
all evidence runs, and this receipt itself.

## Falsifiers attempted

1. "Store mailbox queue grows through the run" → **falsified** (sampler ~0
   throughout, one transient 16).
2. "Outbox debris makes per-dispatch reconcile cost grow" → **falsified**
   (0 → 0, peaks <= 15).
3. "Existing 'two instances never interfere' test already proves
   isolation" → **falsified** (it encodes replica semantics: both refs
   counting one shared event; overlap contaminates — demonstrated live).
4. "The tripwire might be unfalsifiable" → **falsified** (forced-10x run
   trips it: 12.158x; three unforced runs pass: 0.497 / 0.831 / 0.468).
5. "Isolation requires touching RequestRouter's public API" → **falsified**
   (`:owner` closes the observed defect with no API break; arity-2
   `attach!/2` unchanged).

## Remaining

- Item 1 (HddlSolver cross-VM tempdir) — sibling agent's scope, untouched.
- beam4pm consumption gate (re-run `beam4pm_ferroplan` suites + concurrent
  OCEL dispatch smoke against the updated dep) — requires the branches
  merged into ash_a2a main first; out of this agent's worktree scope (no
  writes to `/Users/sac/beam4pm`).
- Neither branch is pushed (per wave discipline: no push).
- Tripwire runs are host-load-sensitive by design: it passed at load ~40-50
  and its moduledoc states the honest reading for contended hosts.
- Temporary diagnostic harness (`tail_latency_diagnostic_test.exs`) was
  run for evidence and deleted, not landed (its evidence lives here; the
  landed tripwire carries the standing mailbox/outbox sampler).
