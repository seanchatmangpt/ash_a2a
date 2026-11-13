# Receipt: ash_a2a 26.11.13 at A2A v1.1.0

Standing: PARTIAL

Subject: `seanchatmangpt/ash_a2a` main, commit `d8f593dc2ea422605731450fa0cef28f551d2c4b`
(pushed; verified with `git ls-remote origin | grep <HEAD>`). Date 2026-11-13.

## Diff

475 files changed, 40388 insertions, 3108 deletions (explicit-path staging; `research/erc/*`
generated JSON left untracked on purpose).

## Commands and exits (coordinator-run, build root `_build-coord`, `MIX_ENV=test`)

| Step | Command | Result |
| --- | --- | --- |
| compile | `mix compile --force` | rc=0, zero warnings in `lib/` |
| default tier | `mix test` (runs 14, 15, consecutive, no edits between) | 125 doctests, 51 properties, 4705 tests, 0 failures, rc=0 |
| serial tier | `mix test --only serial --max-cases 1` | 0 failures, 34 invalid (env-blocked, below) |
| TCK | `run_tck.py` @ a2a-tck `263b9cfa`, SUT `tck_sut.exs`, jsonrpc+http_json+grpc | 238 passed, 27 skipped, 0 failed |
| TCK assert | `scripts/tck_assert.py reports/compatibility.json` | pass=98 fail=0 must_fail=0 |

Logs: `/tmp/coord-full-14.log`, `/tmp/coord-full-15.log`, `/tmp/coord-serial-4.log`,
`/tmp/tck-run-2.log` (working-tree results, bound to the commit above).

## Verification ladder

compile (ALIVE) -> codec/corpus (ALIVE) -> default suite x2 (ALIVE) -> serial tier (PARTIAL,
env-blocked modules) -> TCK v1.0.1 pin (ALIVE). The TCK does not cover v1.1; v1.1 evidence is
local courts only (`docs/reference/a2a-v1-1-conformance.md`).

## Standing per area

| Area | Standing |
| --- | --- |
| v1.1 codec, generation, timeline, live sessions, ifGenerationMatch, long-poll | ALIVE (local courts) |
| v1.0 pre-1.1 client compatibility (downgrade) | ALIVE (TCK 0 failed) |
| Email gateway (Inbound/Brief/ReplyIntent/Plug/KernelEntry) | ALIVE (unit + plug + kernel entry courts); no live SMTP/DKIM provider exercised |
| JSON-RPC `message/live` method | PARTIAL (REST and gRPC live covered) |
| TCK at v1.1 | UNSUPPORTED (no v1.1 TCK exists) |

## BLOCKED / env-only (named, not counted as regressions)

- 34 invalid serial tests: `C2.FramedInteropTest`, `C2Compromise.CourtTest` (child projects'
  Hex deps absent), `Chicago.FiboFinanceTest` (`GRAPHLAW_ABI_WASM` unset).
- XRUNTIME-002 needs the `graphlaw_host` binary (not built).
- Postgres tests ran against a throwaway local instance on :55432 (`/tmp/pg-ash-a2a`).

## Decisions worth knowing

- The pinned TCK (`263b9cfa`) is the external authority for error mappings: cancel of a terminal
  task is HTTP 409; gRPC UNIMPLEMENTED for unsupported operation / version / push-not-supported.
- v1.1-only fields are emitted only when the client negotiates >= 1.1 or sends no version header.
- `Version.default/0` remains "1.0"; emitted `protocolVersion` is "1.1".

## Open items

- JSON-RPC `message/live` court; DKIM/S-MIME live-provider verification for the email gateway.
- Several lane-written tests re-pinned stale expectations to current behavior; flagged in lane
  receipts (S2 re-pinned two string-keyed `a2a.auth` courts: the `Protocol.Plug` metadata merge
  was not independently re-checked).
- Flaky-by-pattern `if Process.alive?(pid), do: GenServer.stop(pid)` teardowns remain in many
  tests (two hardened).

## Falsifiers

A default or serial run with a new failure after this commit; a TCK MUST failure at the pinned
SHA; any v1.1 key on the wire to an explicit `A2A-Version: 1.0` client.
