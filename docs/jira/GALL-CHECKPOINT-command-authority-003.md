# GALL Checkpoint 003 — Command / Authority / Receipt Seal

Status: DRAFT IMPLEMENTATION CONTRACT
Repository: `seanchatmangpt/ash_a2a`
Exact admitted base: `baa135d5c6129aea1d4b38d48a12ad87e132b638`
Branch: `gall/checkpoint-003-command-authority`
Owner surface: admitted capability -> authority -> prepared receipt -> CommandBus -> consequence receipt

## Why this checkpoint is anchored in a real defect

The current head contains the repair for the duplicate-action-name defect discovered by the beam4pm capability sweep: consequence-bearing redispatch once carried only a display name, allowing an index-first namesake to be selected. The system failed safe with `:capability_mismatch`, but the defect made almost every same-named resource skill inoperable.

That defect becomes a permanent GALL falsifier. The court must prove exact resolved capability identity survives the full CommandBus redispatch path; deleting the repair must make the checkpoint fail.

## Required transition

`semantic subject -> candidate capability -> admission -> exact resolved capability -> authority -> pending receipt anchor -> CommandBus -> real consequence -> finalized/pending durable receipt -> replay/reconciliation`

Hard law:

- `Received != Admitted`
- `Capability != Authority`
- `SELECT != CONSTRUCT != DO`
- CommandBus is the sole consequence-bearing path
- zero unreceipted actuation

## Required implementation / consolidation

1. Create one focused checkpoint court that composes the already-proven capability-identity, authority, outbox, crash-window, replay, and bounded-fanout invariants.
2. Carry exact resolved capability identity through redispatch; bare ambiguous display names must be typed refusals.
3. Bind command fingerprint to semantic subject + exact capability + authority/grant + consequence identity.
4. Require the prepared receipt anchor before every `:change` / `:external_do` consequence.
5. Preserve pending uncertainty when finalization cannot be proven; never invent an outcome.
6. Prove replay/reconciliation cannot perform a second consequence.
7. Emit the exact receipt/identity surface required by the independent observer checkpoint.

## Positive witness

Use at least two resources exposing the same display action name. Address the intended non-first resource by its exact capability identity, pass admission/authority, execute one real test consequence through CommandBus, and prove the resulting receipt names the exact resolved capability.

## Negative witnesses / falsifiers

- restore display-name-only redispatch and observe checkpoint failure;
- dispatch a bare ambiguous selector and require typed `:ambiguous_skill` refusal;
- swap semantic subject identity without changing command fingerprint;
- remove/disable prepared-receipt anchoring and require the mutation court to fail;
- force primary receipt commit failure after real consequence and prove pending/final outbox evidence blocks second DO;
- kill the consequence-running BEAM after external acknowledgement and before finalization, then reconcile/replay and prove external operation count remains one;
- exceed OCEL forwarding concurrency and prove bounded shedding rather than unbounded task creation;
- attempt a consequence outside CommandBus and require architecture verification failure.

## GALL receipt fields

- repository + exact head SHA;
- semantic subject identity;
- exact resolved capability ID + display selector;
- command fingerprint + idempotency key;
- authority/grant identity;
- prepared receipt identity and durability witness;
- consequence identity;
- finalized or pending receipt state;
- reconciliation/replay identity;
- external operation count witness;
- OCEL dispatch/shed evidence as applicable;
- commands/exits/toolchain identity;
- standing.

## Verification ladder

1. `mix format --check-formatted`
2. `mix compile --warnings-as-errors`
3. focused duplicate-skill/capability-identity tests
4. focused CommandBus/outbox/crash-window Chicago tests
5. architecture verifier
6. relevant full suite, with any inherited unrelated environmental failures recorded separately rather than hidden
7. hosted exact-head CI where available

## Dependencies

Consumes GALL-002 semantic/manufacturer identity when the capability is manufactured from that path.

Produces the command/receipt subject consumed by:

- GALL-004 independent observer;
- GALL-005 composition/MachineExperience crown.

## Exclusions

- independent postcondition standing belongs to GALL-004;
- no claim that host-local journal semantics equal arbitrary distributed transaction atomicity;
- no production deployment;
- no merge/publication claim;
- no cross-repo `ALIVE` crown.

## Definition of done

At one exact PR head, an exact manufactured capability survives admission and authority, traverses the sole CommandBus DO path with a prepared receipt, performs exactly one real consequence, remains replay-safe across the crash window, and is independently identifiable by downstream observers. The historical display-name regression is a permanent mutation falsifier.

Standing on completion: `ALIVE` for the exact repository-local command/authority/receipt subject only.