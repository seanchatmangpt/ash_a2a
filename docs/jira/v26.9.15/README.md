# v26.9.15 — ash_a2a: dispatch↔receipt transaction closure + OCEL fan-out bounds

- **Date**: 2026-09-15
- **Source**: 14-hour cross-repo code review, window Sep 14 9:40 PM PDT → Sep 15 11:40 AM PDT.
- **Method**: inspection of commits, PR heads, and exact source files. No code executed, nothing changed by the reviewer.

## Result

**Closure (2026-09-15)**: both tickets implemented and Chicago-validated on `fix/v26.9.15-commandbus-outbox` (worktree `wt-v26915/ash_a2a`); full suite 382 tests, 0 failures. See the ticket files for evidence.

The window's work correctly catches dispatcher crashes and receipt-store crashes instead of letting the agent GenServer die, and correctly moves OCEL egress out of the single agent mailbox. Direction is right; transaction closure is not finished.

Two open defects, ranked #1 and #5 in the cross-repo closure order:

1. A real consequence can occur before its receipt commits. If a `:change`/`:external_do` dispatch succeeds and `store.commit/2` then fails, the consequence has happened and `commit_receipt/3` returns `receipt_store_unavailable` with no durable outcome receipt. This contradicts **zero unreceipted actuation**, not merely availability. Standing: **BLOCKED for the zero-unreceipted-DO claim**.
2. The new OCEL forwarder's `Task.Supervisor` has no `max_children`, queue, shedding policy, or bounded buffer — every event starts another process and the HTTP timeout merely bounds its lifetime.

## Tickets

| ID                                                                  | Title                                                                                          | Severity | Closure order |
| ------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- | -------- | ------------- |
| [A2A-2601](./A2A-2601-dispatch-receipt-atomicity.md)                | Consequence can occur before receipt commit — dispatch↔receipt transaction is not closed       | High     | #1            |
| [A2A-2602](./A2A-2602-ocel-forwarder-bounded-fanout.md)             | OCEL async forwarding is unbounded supervised-task fan-out                                     | Medium   | #5            |
