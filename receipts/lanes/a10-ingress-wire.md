# Lane A10 — Ingress Wire (Channel) Receipt

Standing: PASS

## Lane / files

- Lane: A10 — CONSTRUCT (integration wire), repo `/Users/sac/ash_a2a`
- Owned files:
  - `lib/ash_a2a/ingress/channel.ex` (new namespace `AshA2A.Ingress`)
  - `test/ingress/channel_test.exs` (new)

## Surface

`AshA2A.Ingress.Channel` — pure, caller-threaded state (no GenServer):
`empty_state/0`, `ingest/3`, `stats/1`. `ingest(state, event, key:, now:, max_staleness_sec:)` verifies the `AshA2A.Attestation.Key`-signed device token (`Gate.verify_enclave/2`), freshness vs the event timestamp, sensor-metadata plausibility, and consecutive-event GPS teleport (per-coordinator last-known ring threaded through state). Typed refusals are exactly the closed vocabulary `:bad_signature`, `:stale`, `:spoofed_payload`, `:emulator_detected`, `:gps_impossible_jump`; gate outcomes `:nonce_mismatch`/`:malformed_token` fold into `:spoofed_payload`. Failure statistics: per-reason refusal counters as a plain map in `state.refusals` (no persistence).

## Refusal matrix (exercised by court, `test/ingress/channel_test.exs`)

| attack class | refusal | witness test |
|---|---|---|
| token signed by foreign key | `:bad_signature` | "refuses a token signed by a foreign key" |
| `is_virtual` device | `:emulator_detected` | "refuses an emulator-declaring device" |
| issued_at 3600s in past | `:stale` | "refuses an attestation signed in the past" |
| empty camera_make / 500km GPS accuracy | `:spoofed_payload` | two tests |
| nonce mismatch / garbage token | `:spoofed_payload` (folded) | two tests |
| Tokyo→Lisbon in 45s across two ingests | `:gps_impossible_jump` | teleport test |
| valid fresh on-site check-in | `{:ok, normalized_event}` | admit test + Yokohama hop admitted, last-known updated |

## SLA minimal-unblock disclosure (cross-lane)

Early in the lane, `lib/ash_a2a/strain/bridge.ex` (another lane's in-flight file, not mine) failed shared compile: `fatigued?/1` called `error_drift_rising?(state)` arity-1 which did not exist. I applied the minimal unblock (private arity-1 helper). The owning lane subsequently landed its own fix (`drift_rising_on_window?/1`) superseding mine; I deleted my helper (net zero diff of mine in bridge.ex) — owning lane supersedes, coordinator reconciles.

## Commands / exits

- `cd /Users/sac/ash_a2a && MIX_BUILD_ROOT=_build-laneA10 mix compile` — compiles clean (earlier failure was bridge.ex, disclosed above)
- `cd /Users/sac/ash_a2a && MIX_BUILD_ROOT=_build-laneA10 mix test test/ingress/` — **11 tests, 0 failures** (exit 0)

## Fixes during court (session-introduced, resolved)

1. `now:` was not forwarded to `Gate.verify_sensor_metadata` → real wall clock made fixed-timestamp events `:stale`.
2. nil `max_staleness_sec` keyword defeated freshness via term ordering (`3600 <= nil` is true) — nil keys now dropped before forwarding.
3. Teleport test used a 90s gap (above the gate's 60s jump window — jump was lawful); tightened to 45s.
4. Test helper ignored `camera_make` override; now reads opts.

## Standing

PASS — court runs on real `Key.sign/verify` (no doubles), 11/0, lane build root `_build-laneA10` left for coordinator cleanup.
