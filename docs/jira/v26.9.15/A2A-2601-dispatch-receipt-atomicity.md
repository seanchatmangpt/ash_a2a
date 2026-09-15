# A2A-2601: consequence/receipt closure across CommandBus DO

- **Status**: Implemented; exact-head verification required before merge.
- **Severity**: High.
- **Standing**: `BUILD_UNVERIFIED` for the current PR head. No publication, production, runtime-standing, or `ALIVE` claim.
- **Found by**: 14-hour cross-repo review, 2026-09-14 9:40 PM → 2026-09-15 11:40 AM PDT.

## Boundary

A post-consequence outbox alone is insufficient for zero-untracked actuation: the primary receipt store and the fallback outbox can both fail after the consequence already exists.

The repaired sequence is therefore:

`ADMITTED → CLAIMED → RECEIPT_ANCHORED(:pending) → EXECUTING → CONSEQUENCE_OBSERVED → RECEIPT_DURABLE | RECEIPT_OUTBOXED`

For `:change` and `:external_do`, dispatch is refused unless a pending receipt with the exact command id, execution id, fingerprint, capability, and receipt identity has already been persisted by `AshA2A.ReceiptOutbox`. The finalized receipt preserves that same receipt id.

If primary commit fails and final outbox replacement also fails, the pending receipt remains. Reconciliation may commit that pending receipt to the primary store; replay then returns pending evidence instead of executing a second consequence. The system does **not** infer whether the interrupted consequence succeeded or failed.

This is host-local filesystem evidence. It is not a claim of transactional atomicity with an arbitrary external system, replicated storage, or power-loss durability.

## Retry semantics

`:receipt_commit_retry_delays_ms` is interpreted as true retries: one immediate commit attempt, followed by one additional attempt after each configured delay. Default `[50, 150]` therefore means at most three primary commit attempts.

## Chicago falsifiers

`test/ash_a2a_command_bus_outbox_chicago_test.exs` now defines these acceptance falsifiers:

1. A real `:next_phase` mutation plus primary-store failure must leave one finalized outboxed receipt and later reconcile without a second DO.
2. An unavailable receipt anchor must refuse before the real mutation occurs.
3. If primary commit and finalized outbox replacement fail after the real mutation, the pre-dispatch receipt must remain `:pending`; reconcile + replay must not execute a second mutation.
4. A killed in-memory primary store must recover through the re-claim reconcile path.
5. Default-shaped `[5, 5]` test delays must produce exactly three commit attempts: initial + two retries.

## Evidence boundary

The predecessor head `429246c` had local evidence reported as 382 tests / 0 failures, but hosted CI stopped at `mix format --check-formatted`; compile and tests did not run there. That evidence does not qualify the current head.

Current-head admission requires repository-native exact-head CI to pass checkout identity, formatter, warnings-as-errors compile, and the full test suite including the falsifiers above.
