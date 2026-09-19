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

## 2026-09-18 semantic telemetry propagation

GALL-003 is the producer-side source of exact correlation identity for the downstream independent telemetry court.

A consequence-bearing command MUST make the following opaque identities observable where the runtime transport supports them:

- exact semantic subject;
- objective/task/action identity where present;
- exact capability ID;
- prepared and durable receipt correlation identity;
- actor / role identity;
- opaque authority-grant ID or digest;
- exact runtime/source subject identity required for downstream reconciliation.

Forbidden:

- bearer tokens, credentials, or authority secrets in telemetry;
- display-name fallback replacing exact capability identity;
- loss of correlation identity across process/task boundaries;
- using an OpenTelemetry / Weaver validation result as permission to DO.

Downstream evidence chain:

`GALL-003 consequence -> observed OTLP/events -> Weaver semantic validation -> OCEL -> beam4pm GALL-004 independent postcondition court`.

Weaver validates observation semantics only. BRCE / CommandBus remains the consequence boundary. Independent postcondition standing remains owned by beam4pm GALL-004 and its stacked Weaver contract in `seanchatmangpt/beam4pm#76`.

## Implementation specifics — refined 2026-09-18

Current docs-only PR head at this refinement: `8feb63eee7dc66747b04721534efd4f6b44ba602`.

### Verified existing surfaces

The checkpoint MUST compose, not replace, these already-established surfaces:

- `lib/ash_a2a/command_bus.ex`
  - canonical consequence-bearing boundary;
  - target inspection, authority handling, prepared receipt/outbox interaction, dispatch, finalization.
- `lib/ash_a2a/dispatcher.ex`
  - real Ash action dispatch;
  - current exact-skill redispatch support added by commit `538b0de47554520250f40aaca58a480cfc1f8c24`.
- `lib/ash_a2a/info.ex`
  - exact capability lookup / ambiguous-selector refusal.
- `lib/ash_a2a/brce_anchor.ex`
  - prepared receipt / consequence admission fence.
- `lib/ash_a2a/receipt.ex`
  - consequence receipt representation.
- `lib/ash_a2a/receipt_outbox.ex`
  - durable pending/final receipt state used by the crash-window path.
- `lib/ash_a2a/telemetry/ocel_forwarder.ex`
  - bounded process-evidence forwarding.
- `test/ash_a2a_command_bus_outbox_chicago_test.exs`
  - pre-DO durable anchor / fail-closed / replay witnesses.
- `test/ash_a2a_command_bus_crash_window_chicago_test.exs`
  - real external acknowledgement + BEAM death + reconciliation witness.
- `test/support/receipt_crash_window_fixture.ex`
  - real collaborator for the crash-window court.
- existing duplicate-action-name regression introduced with `538b0de...`
  - exact capability-id dispatch succeeds;
  - ambiguous bare selector refuses typed.

### Smallest coherent production diff

The preferred GALL-003 implementation is **primarily a composition court**, not another CommandBus.

Production changes are allowed only if the composed court finds a missing identity or refusal edge.

Required consolidation:

1. Define one canonical GALL subject struct/map at the court boundary containing:
   - GALL-002 manufacturer subject digest;
   - semantic subject;
   - exact capability ID;
   - selector presented by caller;
   - authority grant ID/digest;
   - command ID/fingerprint;
   - idempotency key;
   - consequence class.

2. Ensure `CommandBus` receipt metadata carries the upstream manufacturer/semantic subject digest needed by beam4pm.
   - If that field already exists, reuse it.
   - If it does not, add only the minimal receipt metadata field; do not duplicate the whole GALL-002 receipt.

3. Ensure the exact resolved skill object continues from `CommandBus.inspect_target/2` into `Dispatcher.dispatch/6` via `resolved_skill:`.
   - No second display-name resolution is allowed after authority/preparation.

4. Keep `ReceiptOutbox` as the crash-window durability mechanism.
   - GALL-003 does not introduce a second journal.

5. Keep `OcelForwarder` bounded.
   - Process evidence failure/saturation must not create an unbounded task surface or silently change consequence authority.

### New crown court

Add one top-level composition test:

`test/gall_checkpoint_003_command_authority_chicago_test.exs`

It MUST orchestrate the existing lower courts and add the cross-invariant bindings they do not individually prove.

Required witnesses:

1. **duplicate capability display names**
   - two real Ash resources;
   - both expose `create`;
   - dispatch exact B capability ID;
   - prove B receives the consequence;
   - receipt capability ID == exact B ID.

2. **ambiguous selector**
   - dispatch bare `create`;
   - result == typed `:ambiguous_skill` / refused capability;
   - external consequence count == 0.

3. **prepared receipt ordering**
   - observe prepared/outbox anchor before actuator invocation.

4. **real consequence**
   - use the existing real external-DO fixture, not a mock return value.

5. **crash window**
   - external acknowledgement;
   - kill BEAM before final receipt commit;
   - restart/reconcile;
   - replay;
   - external operation count remains exactly 1.

6. **subject mismatch**
   - change GALL-002/semantic subject identity with otherwise identical command;
   - stale command/receipt identity must not retain standing.

7. **architecture mutation**
   - the existing architecture verifier must fail if a consequence-bearing path calls the actuator outside CommandBus or bypasses BRCE preparation.

### Exact acceptance commands

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test test/ash_a2a_command_bus_outbox_chicago_test.exs
mix test test/ash_a2a_command_bus_crash_window_chicago_test.exs
mix test test/gall_checkpoint_003_command_authority_chicago_test.exs
```

Then execute the repository's existing architecture-verifier command and the affected/full suite required by repository doctrine.

Do not relabel the historical full-suite VendorCwd/macOS path trio as a GALL-003 failure if reproduced unchanged on the exact base; record them as inherited evidence separately.

### Handoff artifact to GALL-004 / GALL-005

The receipt emitted by the successful court MUST expose enough information for an observer that does not trust the actuator:

```text
ash_a2a_repo_sha
gall_002_manufacturer_subject_digest
semantic_subject_digest
capability_id
selector
authority_grant_digest
command_id
command_fingerprint
idempotency_key
prepared_receipt_id
final_or_pending_receipt_id
consequence_class
consequence_identity
external_operation_count_witness
runtime/source identity
```

Do not include bearer credentials or authority secrets. Only opaque authority identity/digest crosses into observation.

### Stop conditions

Stop and preserve typed uncertainty when:

- the external side effect occurred but finalization cannot be proven;
- independent downstream observation is missing;
- subject identity cannot be correlated across the consequence;
- only a display name is available for a multi-match capability;
- replay safety depends on an external system with no idempotency/reconciliation contract.

GALL-003 may still be `ALIVE` for its bounded local consequence subject while GALL-004 remains open; it MUST NOT self-issue the independent-observer claim.

## 2026-09-18 exact-head code review

Reviewed source subject: `501e7bab0aecaca1b815679f5e33a2998f85178b`.

### Observed implementation

GALL-003 is much closer to an execution seal than the original contract wording implies.

`AshA2A.CommandBus` already has an explicit consequence state machine:

`ADMITTED -> CLAIMED -> RECEIPT_ANCHORED -> EXECUTING -> CONSEQUENCE_OBSERVED -> RECEIPT_DURABLE | RECEIPT_OUTBOXED`.

For `:change` and `:external_do`, a pending receipt anchor is mandatory before dispatch; anchor persistence failure refuses before DO. The finalized receipt preserves the anchor receipt identity.

`AshA2A.Receipt` already carries S31-style fields including actuation/idempotency identity, actor, bounded authority-grant descriptor, semantic subject, intended effect, input/plan/projection digests, logical clock, evidence class, reconciliation state, and terminal status. Raw authority evidence is represented by a digest rather than copied into the durable receipt.

The source tree also contains:

- an exact-capability duplicate-action-name regression court;
- a separate-OS-BEAM crash-window Chicago test that performs a real HTTP consequence, kills the producer after acknowledgement, reconciles the pending anchor, and asserts replay does not DO twice;
- filesystem outbox reconciliation;
- boundary telemetry around target/admission/claim/prepare/actuate/postcondition/commit.

Presence of these tests is source evidence only in this review; they were not re-executed here.

### Remaining semantic-observation gap

The current `AshA2A.SemanticProjection.ocel_event/1` does **not** project several identities already present on the receipt and required by the downstream Weaver/GALL-004 court. Its emitted attributes currently include command/execution/task/agent/principal/capability/fingerprint/consequence/status/standing/replayed, but not the receipt's:

- semantic subject / projection digest;
- actuation id;
- idempotency key;
- bounded authority-grant identity/digest;
- evidence class.

GALL-003 should close that projection gap rather than inventing parallel telemetry identity.

### Effect-dedup fail-open falsifier

When effect-level actuation dedup enforcement is active, `claim_actuation/6` currently rescues/ catches receipt-store failures and degrades to `:proceed`; `commit_actuation/6` similarly degrades to `:ok`. The prepared receipt anchor still exists, but a fresh command id with the same declared effect can no longer rely on the effect-index court if that store is unavailable.

The exact GALL-003 court MUST decide this boundary explicitly. For `:declared`/`:strict` idempotency, the required falsifier is: **actuation-claim store unavailable must not silently widen authority to repeat a declared-idempotent consequence**. If fail-open is intentionally retained, the ticket cannot claim an effect-level replay seal under that failure mode.

### Revised next action

The smallest implementation delta is:

1. project the already-canonical receipt semantic/actuation/authority-digest identities into observational telemetry;
2. add a no-secret-leak falsifier;
3. add the effect-claim-store-unavailable falsifier for enforced idempotency;
4. execute the existing exact capability + prepared-anchor + crash-window courts at the final exact head and emit one checkpoint receipt.

### Review standing

- core CommandBus prepared-receipt path: `PARTIAL_ALIVE` by source inspection;
- exact-head GALL-003 crown: `UNKNOWN` until executed;
- downstream semantic telemetry identity completeness: `PARTIAL_ALIVE`.
