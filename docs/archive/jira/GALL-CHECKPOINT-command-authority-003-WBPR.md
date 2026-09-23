# WBPR — GALL-003 Command / Authority / Receipt Seal

**Working-backwards target. This document states the release claim that must be earned.**

## Headline

**ash_a2a makes exact semantic capability identity survive all the way to one receipted consequence.**

## Subheadline

GALL-003 closes the consequence-bearing Semantic A2A path from admitted capability through explicit authority, prepared receipt, CommandBus, one real DO, durable consequence evidence, reconciliation, and replay protection.

## Announcement

At completion, `ash_a2a` can make a narrow consequence-bearing claim:

`semantic subject -> exact capability -> admission -> authority -> prepared receipt -> CommandBus -> one consequence -> receipt -> replay-safe standing`

The system no longer relies on a skill display name, planner choice, model output, or transport message as authority.

## Customer problem

Agent systems often collapse several distinct questions:

- Which capability did the caller mean?
- Was that capability admitted?
- Who is authorized to invoke it?
- Was durable evidence prepared before consequence?
- Did the consequence occur once or more than once?
- Can the same command be replayed without repeating DO?

The recent duplicate-action-name defect made this concrete: redispatch by display name could resolve a different resource's namesake. Failing safe prevented the wrong actuation, but destroyed most of the intended capability surface.

GALL-003 turns that real failure into permanent machine knowledge.

## Product

The CommandBus checkpoint binds:

- semantic subject;
- exact resolved capability identity;
- selector/display name;
- authority/grant;
- command fingerprint;
- idempotency identity;
- prepared receipt;
- actual consequence;
- final/pending durable state;
- reconciliation/replay identity.

Ambiguous selectors are refused. Exact capability identity survives redispatch.

## Customer experience

An upstream planner may SELECT.

A manufacturer may CONSTRUCT.

Neither can DO.

Only an admitted command carrying explicit authority and a prepared durable receipt can reach the consequence boundary.

If finalization becomes uncertain after a consequence, the system preserves uncertainty and reconciles; it does not invent success and it does not repeat the consequence.

## Core invariants

`Received != Admitted`

`Capability != Authority`

`SELECT != CONSTRUCT != DO`

`DO => Authority && PreparedReceipt && CommandBus`

`Replay(CommandIdentity) => ExternalOperationCount <= 1`

## Release proof

One exact head must demonstrate:

1. two resources may expose the same action display name;
2. an exact non-first capability ID reaches the correct resource;
3. ambiguous bare selectors are typed refusals;
4. prepared receipt exists before consequence;
5. exactly one real test consequence occurs;
6. crash/finalization uncertainty is durable and reconcilable;
7. replay/reconciliation does not perform a second DO;
8. restoring display-name-only redispatch makes the mutation court fail;
9. direct consequence paths outside CommandBus fail architecture verification.

## Chicago relation

GALL-003 carries the central evidence for:

- planning remains candidate-only;
- sole DO boundary;
- zero unreceipted actuation;
- receipt identity;
- replay protection.

Independent postcondition observation remains GALL-004's job.

## Non-claims

This release does not claim:

- actuator self-report is independent verification;
- host-local durability equals arbitrary distributed transaction atomicity;
- the planner or agent has authority;
- production deployment;
- final cross-repo Chicago standing.

## Working-backwards definition of done

A caller can hand ash_a2a an exact admitted capability request, then later prove which capability was authorized, which consequence happened, why it was lawful, why it happened only once, and which durable receipt binds the result.

The historical duplicate-name defect becomes impossible to reintroduce without breaking the checkpoint.
