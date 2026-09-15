# v26.9.15 — ash_a2a: receipt boundary + OCEL fan-out bounds

- **Date**: 2026-09-15
- **Source**: 14-hour cross-repo review, Sep 14 9:40 PM PDT → Sep 15 11:40 AM PDT.
- **Current standing**: `BUILD_UNVERIFIED` until the current PR head passes repository-native exact-head CI. No merge, publication, production, runtime-standing, or `ALIVE` claim is implied by this document.

## A2A-2601 — receipt closure

The original `claim → dispatch → receipt commit` order admitted a real gap: the consequence could exist before any durable outcome evidence survived.

The repaired consequence-bearing route now requires a pre-dispatch pending receipt anchor:

`ADMITTED → CLAIMED → RECEIPT_ANCHORED → EXECUTING → CONSEQUENCE_OBSERVED → RECEIPT_DURABLE | RECEIPT_OUTBOXED`

The same receipt identity is finalized after dispatch. If the primary receipt commit and final outbox replacement both fail, the pending anchor remains and replay is blocked from performing a second DO. A missing anchor refuses before DO.

The boundary is intentionally narrow: host-local filesystem evidence is not equivalent to atomicity with an arbitrary external system, replicated durability, or power-loss durability.

## A2A-2602 — bounded OCEL forwarding

OCEL egress uses a `Task.Supervisor` with `max_children` from `:ocel_max_in_flight`. Events that cannot enter that bounded supervisor are explicitly shed and counted; task-supervisor exits/errors are normalized into the same accounted shed path rather than propagating synchronously into the dispatch caller.

## Verification contract

The predecessor head `429246c` was admitted by hosted CI at the exact SHA, but CI failed at `mix format --check-formatted`; warnings-as-errors compile and `mix test` were skipped. The reported 382-test local run therefore remains predecessor/local evidence only.

The current head is admissible for merge only after the repository-native CI proves, at that exact SHA:

1. checkout identity assertion,
2. pinned Rust/HDDL CLI build and Cargo lock check,
3. `mix format --check-formatted`,
4. `mix compile --warnings-as-errors`,
5. full `mix test`, including the new pre-DO anchor, double-persistence-failure, retry-count, replay, reconcile, bounded-concurrency, and non-capacity shed falsifiers.

## Tickets

- [A2A-2601](./A2A-2601-dispatch-receipt-atomicity.md) — consequence/receipt closure.
- [A2A-2602](./A2A-2602-ocel-forwarder-bounded-fanout.md) — bounded OCEL forwarding.
