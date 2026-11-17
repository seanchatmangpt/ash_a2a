# Test suite timing

Where `mix test.all` spends its time, what was measured, and what each owner can
change. The full suite grew from about 11 to 17 minutes in one session; the sync
portion (the `async: false` files) went from about 560 s to 930 s
(`full4.log`: `Finished in 1052.0 seconds (119.9s async, 932.1s sync)`).

## How this was measured, and its limit

Command (partition 2, heavy-suspect set only):

```
MIX_TEST_PARTITION=2 nice -n 10 mix test --slowest 60 --include serial \
  test/ash_a2a/sim test/ash_a2a/c2_compromise test/ash_a2a/c2 test/fuzz_*.exs \
  test/ash_a2a/event_journal_*.exs test/grpc_*.exs test/conference_sim test/ash_a2a/chicago
```

Result: 806 tests, `Finished in 1761.5 seconds (316.4s async, 1445.0s sync)`, 5
failures (not timing related, owned by other lanes), `real 29m47s`, `user 4m51s`.

The wall time is not a trustworthy baseline. 19 other lanes shared the 4-core
machine, load average was 27 to 65 for the whole run, and every number below is
inflated by contention. CPU time (`user`) is the figure that survives contention.
Two single-file reruns show how large the distortion is:

| File | Wall | User CPU |
|---|---|---|
| `chicago/closure/closure_test.exs` | 437 s | 115 s |
| `chicago/offline_replay_test.exs` | 198 s | 17 s |

So `closure_test` is genuinely CPU bound, while `offline_replay_test` is mostly
waiting on fresh OS-process boots and timers, which load stretches.

## Top 20 slowest tests, before (loaded machine, wall)

| # | ms | Test | Owner of the file |
|---|---|---|---|
| 1 | 571 277 | `Chicago.MutationHarnessTest` SA2A-MUTATION court end to end | mutation lane (L12) |
| 2 | 263 681 | `Chicago.OfflineReplayTest` CHI-REPLAY court end to end | chicago |
| 3 | 158 602 | `Chicago.ClosureTest` real tree report / enforce | chicago |
| 4 | 40 582 | `Chicago.CrossRuntimePortabilityTest` SA2A-XRUNTIME end to end | chicago |
| 5 | 29 482 | `Sim.McpTest` parity through `sim_parity` | sim lanes (L13/14) |
| 6 | 23 252 | `Chicago.FreshConsumerTest` CHI-FRESH end to end | chicago |
| 7 | 22 555 | `Chicago.CrownTest` Strict crown claim | chicago |
| 8 | 18 881 | `Sim.McpTest` every surface item through `tools/call` | sim lanes |
| 9 | 18 300 | `Chicago.CrashReconciliationTest` SA2A-CHAOS | chicago |
| 10 | 14 791 | `Chicago.IdentityGate1Test` CHI-ID | chicago |
| 11 | 14 387 | `ConferenceSim.RedTeamCourt` 200 concurrent resubscribes | conference sim |
| 12 | 13 833 | `Chicago.OfflineReplayTest` `verify_fresh/2` fresh OS process | chicago |
| 13 | 9 698 | `Chicago.MutationHarnessTest` proof CHI-SELFTEST-REPLAY-001 | L12 |
| 14 | 9 541 | `Chicago.CrossRuntimePortabilityTest` unavailable host | chicago |
| 15 | 8 809 | `Chicago.RealCollaboratorsTest` CHI-REAL | chicago |
| 16 | 6 854 | `Chicago.ObserverQualificationTest` | chicago |
| 17 | 6 511 | `FuzzJSONDecodersTest` decode/2 total | fuzz lane (L15) |
| 18 | 6 222 | `Chicago.AuthorityCourtsTest` | chicago |
| 19 | 6 064 | `Chicago.Stress.MultinodeConcurrencyTest` 6 real peers | chicago |
| 20 | 5 506 | `Chicago.RootManifestMetaAdmissionTest` | chicago |

The top 60 tests sum to 1 371 s of the 1 761 s run. The top 3 alone are 993 s
(56 percent). Nothing else in the set is above 41 s.

## What the data rules out

- `test/ash_a2a/c2` and `test/ash_a2a/c2_compromise`: no test is above 5 s
  (`L07TlsFramedTest` 3 to 5 s each). The one real elapsed-time wait in
  `test/support/c2_harness/catalog.ex` (4.5 s, a certificate that must really
  lapse, marked `SLEEP-CLASS: REAL-ELAPSED-TIME`) is not reducible without
  weakening the check.
- Fuzz: `FuzzGen.iterations/1` already scales counts with `FUZZ_ITERATIONS`
  (percent, default 100). The slowest fuzz test is 6.5 s. Not a source of the growth.
- gRPC, event journal and conference sim: every test is below 15 s; the only
  multi-second ones start real peer nodes or 200 sockets on purpose.
- Repeated `Application.ensure_all_started` and sleeps in `test/support`: all
  calls are inside `:peer` node bootstraps (idempotent, milliseconds). No support
  fixture sleeps above 2 s except the one above.
- `config/test.exs` and the 60 s / 300 s timers: the 300 000 ms values found are
  court and replay timeouts in `lib/ash_a2a/chicago/*` and
  `lib/ash_a2a/receipt/offline_replay.ex`. They are ceilings, not waits, and are
  not touched in a normal run.

## What changed in this lane

No file in the lane's scope (`test/support`, `config/test.exs`, `mix.exs`
aliases, CI shard config) held a safe, measurable win, so no behaviour was
changed there and the before and after numbers are the same. The time is in test
files and `lib/ash_a2a/chicago`, which are outside this lane's scope. The
recommendations below are what to apply there. No change was made to the tier
tags, so `scripts/check_optional_deps.sh` and `test/optional_deps_matrix_test.exs`
are unaffected.

## Recommendations (ordered by saving)

1. `mutation_harness_test.exs` (L12), SA2A-MUTATION test: it runs every resolved
   killer court once as a baseline and once per mutant (`@tag timeout: 1_800_000`),
   so cost is courts times mutants. Keep the full matrix in a nightly job
   (`mix test --only mutation_full`) and in the default tier assert only the
   resolution table plus one mutant per killer court. Largest single saving,
   several minutes of the shard that holds it.
2. `closure/closure_test.exs`: two full-tree abstract-code walks (`setup_all`
   report and the enforce test), 115 s CPU. Derive the enforce verdict from the
   report already computed (`report.verdict == "violations"` is the refusal), or
   cache the walk per VM in a `test/support` helper keyed on the module list. The
   planted-bypass tests already prove enforce refuses. Saves about half of 115 s CPU.
3. `offline_replay_test.exs`: 17 s CPU but 198 s wall; the wait is fresh
   `elixir` OS-process boots (`Chicago.FreshConsumer`, `OfflineReplay.verify_fresh`).
   Run the independent fresh-process verifications of one run concurrently
   (`Task.async_stream`) instead of one after another.
4. `sim_mcp_test.exs` (L13/14): the two `Sim.McpTest` stdio tests that run the
   parity and every-surface-item drivers take about 48 s; start the stdio server
   once in `setup_all` and share it between those tests.
5. Shard balance: `mix test --partitions 3` assigns files by index in the sorted
   list of all test files (`rem(index, 3)`), not by cost, so adding or removing any
   test file moves every later file between shards. Today `mutation_harness_test`
   lands on shard 2, `offline_replay_test` and `fresh_consumer_test` on shard 3,
   `cross_runtime_portability_test` and `sim_mcp_test` on shard 1. CI's measured
   split (shard-2 4.3 min, shard-3 4.4 min) was balanced at `4a647a9`; re-measure
   after recommendations 1 to 3 land and change the lane comment in
   `.github/workflows/ci.yml` if it drifts.

## Projected full-suite time

Measured here: the suite cannot be re-timed reliably on a shared, loaded host, so
the table above is evidence of where time goes, not of the total. Estimate if
recommendations 1 to 3 are applied (these are estimates, not measurements): the
three files account for about 56 percent of the heavy-suspect set's wall time and
most of its CPU; with a reduced default mutation matrix the sync portion should
return towards the earlier 560 s, giving a full `mix test.all` of roughly 11 to 12
minutes on an idle machine. With no change, the projection stays at the measured
17 minutes.
