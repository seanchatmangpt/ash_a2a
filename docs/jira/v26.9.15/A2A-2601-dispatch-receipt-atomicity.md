# A2A-2601: Consequence can occur before receipt commit — dispatch↔receipt transaction is not closed

- **Status**: Closed — implemented + Chicago-validated (2026-09-15)
- **Severity**: High
- **Standing**: ALIVE for this fix (full suite: 382 tests, 0 failures, `fix/v26.9.15-commandbus-outbox` @ 1f60491/1e35c30, worktree `wt-v26915/ash_a2a`)
- **Closure evidence**: new `AshA2A.ReceiptOutbox` (durable append-only journal: tmp+rename writes, version-tagged term format, fetch/re-claim/commit reconcile); `CommandBus.run/4` now implements the documented ADMITTED -> INTENT_DURABLE -> EXECUTING -> CONSEQUENCE_OBSERVED -> RECEIPT_DURABLE / RECEIPT_OUTBOXED state machine with bounded commit retries (`:receipt_commit_retry_delays_ms`, default `[50, 150]`), a typed `:receipt_commit_pending` error carrying the receipt, `reconcile_outboxed_receipts/2`, and an opportunistic pre-claim drain. Chicago suite `test/ash_a2a_command_bus_outbox_chicago_test.exs` proves the exact review falsifier with a real mutating `:next_phase` command, a real flaky-commit store, a real killed-Memory re-claim recovery, and replay-after-reconcile performing no second consequence.
- **Found by**: 14-hour cross-repo code review, window 2026-09-14 9:40 PM → 2026-09-15 11:40 AM PDT (inspection, not execution)

## Evidence

The current `CommandBus` sequence (`lib/ash_a2a/command_bus.ex`) is effectively:

**claim → dispatch consequence → construct receipt → commit receipt**

This window's change correctly catches dispatcher crashes and receipt-store crashes instead of allowing the agent GenServer to die. But if the real `:change`/`:external_do` dispatch **succeeds** and `store.commit/2` subsequently fails, the consequence has already happened. `commit_receipt/3` then returns `receipt_store_unavailable` (`lib/ash_a2a/command_bus.ex:74-89`) and there is no durable outcome receipt for that consequence.

The gap existed structurally before the window — the pre-window version also dispatched before `store.commit` — but this window explicitly modified that exact failure boundary without closing the transaction.

## Impact

This is the highest architectural priority of the review window (closure order #1) because it contradicts **zero unreceipted actuation**, not merely availability: an actual consequence can exist in the world with no committed outcome receipt.

## Fix

Close the transaction with something equivalent to a durable execution/outbox state machine:

`ADMITTED → INTENT_DURABLE → EXECUTING → CONSEQUENCE_OBSERVED → RECEIPT_DURABLE`

with crash recovery/reconciliation between the latter states, so a failure at any boundary leaves a recoverable, reconcilable state rather than an unreceipted consequence.

## Falsifier (acceptance)

Make `claim/2` succeed, execute a real idempotently-observable mutation, then make `commit/2` fail. After `run/4`, ask the durable store for the command.

- Current expected result: consequence exists, committed receipt does not.
- Required result after fix: no unreceipted consequence is observable — the state machine either reconciles the receipt durably or rolls the intent into a typed recovery/refusal path.
