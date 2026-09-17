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

## See Also

- `chicago-conformance-court.md` -- what the Chicago court is and why it
  exists as a falsification court rather than a test suite
- `lib/mix/tasks/ash_a2a.chicago.bench.ex` -- the mix task run for this
  report
- `docs/rfc/RFC-SA2A-002-v26.9.16.md` -- S102 (environment receipt), S135
  (raw-result digest verification)
