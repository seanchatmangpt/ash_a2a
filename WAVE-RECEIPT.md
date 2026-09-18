# WAVE-RECEIPT — A3, ticket b4p-f5-01 scope item 2 (ObanAuthority.verify_live!/3 in the command worker)

- **standing: ALIVE** (gate closed by observed execution in this session)
- **base:** `chore/f5-01-defect2-verify` @ `fa51fc8dace7964b824b1238939335422797e503` (ash_a2a main tip at worktree creation; `1f06cab` is an ancestor — `git merge-base --is-ancestor` confirmed)
- **agent:** A3 of 10-agent DfCM wave, 2026-09-18

## Environment build

| command | exit |
|---|---|
| `mix deps.get` | 0 |
| `cd native/hddl_cli && cargo build --release --locked` | 0 (31.5s, hddl_cli 0.1.0 + ferroplan dep compiled) |
| `mix compile --warnings-as-errors` | 0 (309 files) |
| Postgres for `AshA2A.Test.Repo` | Homebrew PostgreSQL 14.19 on localhost:5432 (`ash_a2a_test` DB created there), served to the suite at the config-exact coordinates `localhost:55432` via a local TCP forwarder (colima/docker was unavailable-slow; no committed config file was modified; worktree tree stayed byte-identical to base for every product/test run) |

## Gate verdict: CLOSED — the revocation-mid-flight test exists, is adequate, and was proven to fail on the old code

**Test:** "the shipped AshA2A.Test.Support.CommandWorker now re-verifies live broker standing, so a revoked-but-unexpired grant is refused (closed gap, regression guard)"
**File:** `test/ash_a2a/chicago/hardening/adapter_crash_safety_test.exs` (test at line 464)
**Shape (matches the ticket's demanded scenario exactly):** real `Grant.grant/2` into the real default (config-driven, production-identical) broker → real DB-persisted `Oban.Job` via `AshA2A.Delivery.Oban.enqueue(CommandWorker, ...)` → `Grant.revoke/2` **while the job sits in the queue** (revocation mid-flight, before fresh dispatch) → real dequeue-claim (attempt/attempted_at bumped via real Ecto update) → `Oban.Testing.perform_job/2` (Oban's own executor, real `AshA2A.Test.Support.CommandWorker.perform/1` — the shipped worker, not a stub). Asserts typed refusal `{:error, %{reason: :authority_stale}}`, no durable receipt (`:error` from the receipt store), and zero actuation (no `Item` rows).

**Falsifier attempted and survived (test fails on old code — empirically, not by reading):**
- `git show 1f06cab^:test/support/command_worker.ex` (0 `verify_live` refs vs 2 in fixed) placed at `test/support/command_worker.ex`
- `mix test test/ash_a2a/chicago/hardening/adapter_crash_safety_test.exs:464` → **1 test, 1 failure** — `left: {:error, %{reason: :authority_stale}}` / `right: :ok` — i.e. on the pre-fix worker the REVOKED-but-unexpired authority really actuated. This is the ticket's "fails on the old code" property, witnessed.
- Fixed worker restored (`git status` clean); rerun → **1 test, 0 failures, exit 0**.

**Not vacuously green — control cases witnessed (standing grant actuates through the same shipped worker):**
- `test/ash_a2a/oban_delivery_qualification_test.exs:121` — real `CommandWorker.perform/1` via `perform_job/2` performs a real `Ash.create` and commits a real Receipt (`assert [%Item{label: ^label}] = created`); redelivery replays, never double-executes.
- same crash-safety file, tests 3 and 5 — still-standing grant actuates through the hardened reference worker; revocation-after-durable-receipt still replays (receipt-peek purpose case).

## Ordering evidence (ticket DO #4)

`git show 1f06cab -- test/support/command_worker.ex`: the receipt-peek ordering claim is real. In `perform/1`: `store = CommandBus.default_store()` → `store.fetch(reconstructed.command_id, [])` → `{:ok, _}` branch returns the reconstructed authority (legitimate redelivery of an already-actuated command, live re-verification skipped **on purpose** — revoking authority must not invalidate evidence of a consequence that already happened; same semantics as the file's own CrashSafeCommandWorker reference body) → `:error` branch (no receipt = genuinely fresh/in-flight attempt) calls `ObanAuthority.verify_live!(reconstructed.authority, args["capability_id"])` **before** `CommandBus.run/4` — the only side-effecting call — is ever reached. No side effect precedes the live-verification gate on a fresh dispatch. Moduledoc documents the contract.

## Commands + exits (verification runs, all in this session)

| command | result | exit |
|---|---|---|
| `mix test test/ash_a2a/chicago/hardening/adapter_crash_safety_test.exs --trace` | **6 tests, 0 failures** | 0 |
| same file `:464` with OLD worker (falsifier) | 1 test, 1 failure (revoked authority actuated: `:ok`) | nonzero |
| same file `:464` with fixed worker restored | 1 test, 0 failures | 0 |
| `mix test test/ash_a2a/oban_authority_staleness_test.exs test/ash_a2a/oban_delivery_qualification_test.exs test/ash_a2a/oban_delivery_test.exs` | **12 tests, 0 failures** | 0 |
| `mix test --max-cases 6` (full suite) | 58 doctests, 29 properties, **2066 tests, 4 failures**, 1 skipped (17 excluded) | 2 |

### Full-suite 4 failures — triaged, all pre-existing/environmental, none in scope

1. 3x `AshA2A.GraphLawVendorToolVersionCwdTest` (`test/ash_a2a/graphlaw_vendor_tool_version_cwd_test.exs`): macOS `/var` → `/private/var` symlink — `System.tmp_dir()` returns `/var/folders/...`, the probe subprocess records the resolved `/private/var/...`; `Path.expand` resolves no symlinks so the string-compare fails. Reproduces deterministically in isolation (8 tests, 3 failures). Environment-specific (macOS), zero relation to Oban/authority.
2. `AshA2A.Chicago.GraphlawEngineTest` "reproducers under priv/graphlaw/defects": failed only under full-suite load (on_exit `GenServer.stop` race on the wasm host; log also shows a `graphlaw_import_surface_mismatch` from the vendored praxis wasm artifact's import surface). **Passes in isolation: 9 tests, 0 failures, exit 0.** Flaky teardown, environmental.
- The two ticket-named known flakes (`SemanticRefusalTest` `:hddl_solve_error` mapping, `:eaddrinuse` port race) did **not** fire in this run.
- Worktree tree was byte-identical to base `fa51fc8` during every run above (the only file ever swapped was restored before rerun), so all 4 failures are pre-existing relative to this branch by construction. Per ticket triage law they are here explicitly triaged with the isolation re-run receipts above, not silently ignored.

## Files changed

- `WAVE-RECEIPT.md` (this file) — only change. **No product, test, or config code changed**: the fix under verification was already on main (`1f06cab`, verified present at `test/support/command_worker.ex:74-91` with `verify_live!/3` at line 80).

## 比 (ratio)

- 産面 lines delivered this session by A3: 1 hand-written ledger file (the receipt itself; ledger-writing is the operator-mandated exception, not product code). Product/test lines hand-written by A3: **0** — none were needed; the gate closed on existing, verified code.
- The fix itself was authored in `1f06cab` (prior session, receipts in its own commit message: real Postgres+Oban sweep 18/18, full suite 2087 tests / 0 failures). This session added the missing adversarial leg: empirical proof the shipped regression test fails on the pre-fix worker.

## Falsifiers attempted

1. **Old-code falsifier (the ticket's core demand)** — ran the revocation-mid-flight test against the literal `1f06cab^` worker: FAILS with the revoked authority actuating (`:ok`). Survives only on fixed code. This proves the test exercises the real shipped worker path and is not vacuously green.
2. **Ancestry falsifier** — `git merge-base --is-ancestor 1f06cab HEAD`: confirmed the fix under verification is in this branch's history (guarding against verifying a fix absent from the base).
3. **Vacuity falsifier** — searched for, and ran, the standing-grant control cases through the same shipped worker (`oban_delivery_qualification_test.exs`); without these the refusal test alone could pass on a worker that refuses everything.
4. **Isolation falsifier on the 4 full-suite failures** — reran both offending files solo to separate environment/flake from product regression (cwd test: deterministic macOS symlink issue; engine test: passes solo → load-related teardown flake).

## Remaining (not A3's scope)

- Scope item 1 (parse-stage witness), item 3 (7 benchmark modules wiring), item 4 (push main) — other agents/ticket legs.
- Non-blocking upstream nits observed while here: `graphlaw_vendor_tool_version_cwd_test.exs` should compare symlink-resolved paths (`File.realpath/1`) to be macOS-clean; the vendored praxis-graphlaw wasm import surface drift (`graphlaw_import_surface_mismatch`) will need reconciliation when graphlaw live-engine tests are next exercised.
- Environment note for reproducers: colima was started for docker but was not needed; the dedicated Postgres ran as Homebrew PG 14.19 (`ash_a2a_test` DB) fronted at `localhost:55432`.
