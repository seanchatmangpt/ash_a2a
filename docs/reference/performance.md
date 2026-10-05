# Performance

Baseline wire-path numbers for v1.0, captured 2026-10-04 on the canonical
checkout of `ash_a2a` at v26.10.3 (branch `main`, uncommitted working tree at
capture time).

> **Not a benchmark claim.** Every number below is a MEASURED-once
> observation from a single run on one machine. For comparative numbers
> (regression detection, before/after claims), re-run
> `mix ash_a2a.chicago.bench` and compare against a content-addressed raw
> result via `--verify` and
> `AshA2A.Chicago.Bench.Regression` — never against this page.

## Environment

| Field | Value |
|---|---|
| Machine | Apple M3 Max, 16 logical cores (12P+4E), 48 GB RAM |
| OS | macOS 26.2 (Darwin 25.2.0), arm64 |
| Elixir / OTP | 1.19.5 / OTP 28 (erts 16.2, JIT, `build_type: opt`) |
| ash_a2a / ash | 26.10.3 / 3.34.0 |
| Build root | `_build-laneZ14` (isolated lane build; MIX_ENV=dev for the |
| | bench, MIX_ENV=test for the smokes) |
| Topology | Single BEAM node, in-process SUT boundaries; no network hop in |
| | any bench path (loopback HTTP only in the smokes) |
| Environment identity | `4b3e851be4fd3d55390a477560219d1a9c7894cbabfb1e929c52831984b4305d` |

The environment identity is the §102 receipt stamped into every raw bench
result in the same run, so the numbers below are replayable against that
exact environment receipt.

## Chicago bench (SA2A-B5, SA2A-B9)

Run of `mix ash_a2a.chicago.bench --only B5,B9 --iterations 10 --warmup 2`,
output archived at `/tmp/laneZ14/bench-B5-B9-output.txt`, raw content-
addressed results in `/tmp/laneZ14/bench/`:

    SA2A-B5  MEASURED  iterations=10  p50=2508us  p90=34655us  p99=76169us
             max=76169us  invariant_failures=0
    SA2A-B9  MEASURED  iterations=10  p50=29417us  p90=38702us  p99=39408us
             max=39408us  invariant_failures=0

Selected categories: `SA2A-B5` (authority + BRCE dispatch: the dispatch-path
authority decision plus the sole DO boundary, `AshA2A.CommandBus.run/4`,
over a real broker, receipt store and ETS resource) and `SA2A-B9` (OCEL
evidence overhead on that same dispatch path). These are the two B1-B10
categories that measure the dispatch path a wire request traverses. The
suite has **no HTTP / SSE / streaming bench category** (B1-B10 measure
admission, logic closure, hooks, planning, authority, cascade, cross-
runtime, replay, OCEL, recovery); the wire-only path is covered by the
micro-smokes below instead.

Per-case latency for SA2A-B5 (microseconds, n=10 per case):

| Case | min | p50 | mean | max | Invariants |
|---|---|---|---|---|
| authorized | 16,884 | 26,902 | 39,770 | 76,169 | 0 |
| broker_unavailable | 954 | 1,344 | 5,023 | 34,655 | 0 |
| expired | 1,017 | 2,033 | 4,289 | 20,654 | 0 |
| refused | 1,058 | 2,416 | 4,430 | 11,835 | 0 |
| revoked | 1,168 | 2,672 | 3,294 | 11,072 | 0 |

Reading: the full authorized dispatch (authority decision + prepared
receipt + actuation + final receipt + independent post-state read) is
roughly an order of magnitude above a refusal path (p50 ~27 ms vs ~1-3 ms),
with a heavy tail (max 76 ms within only 10 iterations) — treat these as
shape-of-cost observations, not stable percentiles.

SA2A-B9 highlights: p50 OCEL overhead 13.1 us per event over 132 OCEL
events / 93,297 bytes serialized in the run; serialization 17.6 ms and
query-load 11.0 ms per iteration.

## Wire micro-smokes (MEASURED-once)

Two ad hoc smokes, run once, over the real wire: a real Bandit listener
serving the real `AshA2A.A2ATransport.Plug` fronting a real
`AshA2A.Protocol.Agent` GenServer, driven by `Req` over loopback HTTP.
Script: `/tmp/laneZ14/smoke.exs` (not committed); raw output
`/tmp/laneZ14/smoke-run-output.txt`; machine-readable results
`/tmp/laneZ14/smoke-results.json`.

### message/send round-trip

200 sequential real HTTP POSTs (after 20 warmup calls), per-call latency:

| n | min | p50 | p95 | p99 | max | mean |
|---|---|---|---|---|---|---|
| 200 | 211 us | 415 us | 1,670 us | 6,747 us | 18,051 us | 762.6 us |

### message/stream SSE drain

30 sequential real SSE streams (after 5 warmups), full-drain wall time per
stream; each stream is one `message/stream` request whose agent streams 3
text parts (6 SSE frames on the wire, ~1,018-1,028 bytes):

| n | min | p50 | p95 | p99 | max | mean |
|---|---|---|---|---|---|---|
| 30 | 361 us | 445 us | 862 us | 4,402 us | 4,402 us | 616.3 us |

## Findings

- **Wire-path bench category: `SA2A-B11` now exists (placeholder).** The
  findings above predate it; B11 (`AshA2A.Chicago.Bench.B11Wire`) is the
  HTTP/SSE category B1-B10 lack: a real Bandit loopback listener serving the
  real `AshA2A.A2ATransport.Plug` behind real `AshA2A.Protocol.Plug.Auth`
  bearer auth, fronting a real `AshA2A.Agent` GenServer over a real ETS
  resource. Two scenarios per iteration -- an auth'd JSON-RPC `message/send`
  round trip through the full authority + CommandBus dispatch path (same path
  B5 times, entered via the wire) and a full drain of a 3-frame `message/stream`
  SSE body -- with §84 invariant checks per sample, so the bench doubles as a
  wire smoke court. Bandit is a `only: :test` dependency, so run:

      MIX_ENV=test MIX_BUILD_ROOT=_build-laneZ26 mix ash_a2a.chicago.bench \
        --only B11 --iterations 5 --warmup 1

  MEASURED numbers land here after the first full run; the micro-smokes below
  remain the MEASURED-once baseline until then.
- **No wire bench category existed at capture time.** B1-B10 contain no
  HTTP/SSE/streaming category; the only dispatch-path categories are B5
  (authority+BRCE) and B9 (OCEL overhead). At capture time the micro-smokes
  above were the only wire-path measurements, and they were MEASURED-once
  only.
- **No bench category errored.** Both selected categories ran MEASURED with
  0 invariant failures on the post-v1.0-refactor tree (finding template
  otherwise unused).

## Reproduce

From the repo root (`/Users/sac/ash_a2a`):

```console
# Chicago bench (dispatch-path categories; --out archives raw results)
MIX_BUILD_ROOT=_build-laneZ14 mix ash_a2a.chicago.bench \
  --only B5,B9 --iterations 10 --warmup 2 --out /tmp/laneZ14/bench

# Wire-path category (real Bandit + real agent over loopback HTTP)
MIX_ENV=test MIX_BUILD_ROOT=_build-laneZ26 mix ash_a2a.chicago.bench \
  --only B11 --iterations 5 --warmup 1

# Wire micro-smokes (real Bandit + real agent over loopback HTTP;
# script lives in /tmp, not committed)
MIX_ENV=test MIX_BUILD_ROOT=_build-laneZ14 mix run /tmp/laneZ14/smoke.exs
```

For comparative runs, re-execute with the same `--iterations`/`--warmup`
and compare raw results via `mix ash_a2a.chicago.bench --verify <raw.json>`
plus `AshA2A.Chicago.Bench.Regression`.
