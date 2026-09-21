# ARD v26.9.18 — GALL-003: Command / Authority / Receipt Seal

**Status:** DRAFT ARCHITECTURE SPEC  
**Release:** v26.9.18  
**Repository:** `seanchatmangpt/ash_a2a`  
**Owner:** ash_a2a  
**Dependencies:** GALL-002 semantic/manufacturer identity  
**Authority ceiling:** sole consequence-bearing CommandBus path

## Architectural objective

One exact admitted capability crosses explicit authority and a prepared receipt boundary, produces one real consequence, survives crash-window reconciliation and remains replay-safe.

The architecture follows the Chatman separation laws:

[
Received \neq Admitted,\quad Candidate \neq Authority,\quad SELECT \neq CONSTRUCT \neq DO
]

and every consequence/evidence claim is bounded by exact subject identity and replayable receipts.

## Load-bearing components

- `AshA2A.CommandBus` — consequence boundary
- `AshA2A.Dispatcher` — real Ash action dispatch
- `AshA2A.BrceAnchor` — prepared receipt fence
- `AshA2A.ReceiptOutbox` — pending/final durability
- `AshA2A.Telemetry.OcelForwarder` — bounded evidence forwarding
- `test/gall_checkpoint_003_command_authority_chicago_test.exs` — composition court

## Data / control flow

`Manufactured semantic subject -> exact capability -> authority -> prepared receipt -> CommandBus -> Dispatcher -> real consequence -> durable final/pending receipt -> replay/reconciliation`

## Interfaces

- Input: GALL-002 subject + capability request + explicit grant
- Output: GALL-003 command/consequence receipt
- Downstream: GALL-004 observer and GALL-005 composition

## Required invariants

1. Carry exact resolved capability identity through CommandBus into Dispatcher; no second ambiguous display-name lookup.
2. Bind command fingerprint to semantic/manufacturer subject, capability, authority grant, idempotency identity and consequence class.
3. Require durable prepared receipt anchor before every change/external_do.
4. Preserve pending uncertainty when finalization cannot be proved.
5. Use the existing ReceiptOutbox/crash-window mechanism; no competing journal.
6. Prove replay/reconciliation cannot perform a second external operation.
7. Expose correlation identities required by the independent observer without leaking credentials or authority secrets.

## Failure and refusal boundaries

- Ambiguous capability => REFUSED
- No authority/prepared receipt => REFUSED before DO
- Ack without provable finalization => PENDING/UNCERTAIN
- No idempotency/reconciliation contract => bounded replay claim cannot be made

A refusal is a valid architectural result. The implementation MUST NOT add model inference, private state, ambient dependencies, alternate authority paths or hand-written generated projections merely to make a court green.

## Repository-native qualification court

- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix test test/ash_a2a_command_bus_outbox_chicago_test.exs`
- `mix test test/ash_a2a_command_bus_crash_window_chicago_test.exs`
- `mix test test/gall_checkpoint_003_command_authority_chicago_test.exs`
- repository architecture verifier + affected/full suite

Each command is recorded with exact head SHA, relevant lock/toolchain identities, exit status and artifact digests. A later run against a different subject does not inherit this standing.

## Evidence contract

The checkpoint receipt MUST contain enough identity to let the next boundary validate:

- producer repository and exact SHA;
- semantic/manufacturer/runtime subject as applicable;
- predecessor receipt digests;
- court/falsifier identities;
- exact output artifact digests;
- standing and evidence ceiling.

## Security / authority

Authority is never inferred from capability, model output, successful parsing, observation, conformance, generated source or prior execution. Secrets and bearer credentials are never embedded into cross-repository evidence receipts; only opaque grant/principal identities needed for correlation are allowed.

## Definition of architectural closure

The architecture is closed only when the positive witness executes and every required negative witness is actually attempted against the exact subject. Configuration, source inspection or absence of a violation without an attempted falsifier is insufficient.
