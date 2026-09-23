# PRD v26.9.18 — GALL-003: Command / Authority / Receipt Seal

**Status:** DRAFT IMPLEMENTATION SPEC  
**Release:** v26.9.18  
**Repository:** `seanchatmangpt/ash_a2a`  
**Owner:** ash_a2a  
**Dependencies:** GALL-002 semantic/manufacturer identity  
**Authority ceiling:** sole consequence-bearing CommandBus path

## Product thesis

One exact admitted capability crosses explicit authority and a prepared receipt boundary, produces one real consequence, survives crash-window reconciliation and remains replay-safe.

## Problem

Capability selection, authority and consequence execution must remain distinct. The historical duplicate action-name defect proved that a display-name redispatch can destroy or misresolve the intended capability surface even when the system fails safe.

## User / consumer

The primary consumer is another machine boundary in the GALL chain. Human maintainers need the same artifact to be inspectable, falsifiable and executable through repository-native courts. No downstream consumer is allowed to infer stronger standing than this checkpoint emits.

## Required product behavior

1. Carry exact resolved capability identity through CommandBus into Dispatcher; no second ambiguous display-name lookup.
2. Bind command fingerprint to semantic/manufacturer subject, capability, authority grant, idempotency identity and consequence class.
3. Require durable prepared receipt anchor before every change/external_do.
4. Preserve pending uncertainty when finalization cannot be proved.
5. Use the existing ReceiptOutbox/crash-window mechanism; no competing journal.
6. Prove replay/reconciliation cannot perform a second external operation.
7. Expose correlation identities required by the independent observer without leaking credentials or authority secrets.

## Acceptance criteria

1. Two real resources share `create`; exact non-first capability ID actuates the addressed resource.
2. Bare ambiguous selector receives typed `ambiguous_skill` refusal and performs zero consequence.
3. Prepared receipt ordering is observed before actuator invocation.
4. Real consequence occurs exactly once across ack/crash/restart/reconcile/replay.
5. Changing semantic/manufacturer subject invalidates stale command/receipt identity.
6. Architecture verifier fails a consequence path that bypasses CommandBus/BRCE preparation.

## Product outputs

The implementation MUST emit a machine-readable, content-addressed checkpoint artifact/receipt that binds the exact subject, evidence ceiling, falsifiers attempted, commands/courts executed and resulting standing. Prose documentation is explanatory only and cannot confer standing.

## Success metrics

- 0 unreceipted consequence attempts admitted
- External operation count = 1 across crash/replay witness
- 100% exact capability ID preservation on consequential redispatch

## Non-goals

- Independent postcondition proof
- Production deployment claim
- Distributed global transaction atomicity
- Cross-repo crown

## Release semantics

- A configured workflow is not execution evidence.
- Source presence is not runtime standing.
- Local PASS, hosted PASS, runtime standing, merge and publication remain separate evidence classes.
- Any changed base/head SHA is a changed subject unless explicitly re-admitted.
- UNKNOWN/PARTIAL/REFUSED/BLOCKED states are preserved rather than collapsed into generic failure.

## Definition of done

One exact admitted capability crosses explicit authority and a prepared receipt boundary, produces one real consequence, survives crash-window reconciliation and remains replay-safe.

The exact v26.9.18 subject earns only the bounded standing proven by its repository-native court. No cross-repository promotion is implied.
