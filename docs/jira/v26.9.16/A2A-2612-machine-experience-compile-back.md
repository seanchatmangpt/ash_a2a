# A2A-2612: compile successful UNKNOWN work back into future KNOWN routes

- **Status**: OPEN
- **Severity**: Critical
- **Standing**: `PARTIAL_ALIVE`
- **Owning repos**: `seanchatmangpt/ash_a2a`, `seanchatmangpt/ggen`, `seanchatmangpt/bcinr`, `seanchatmangpt/affidavit`
- **Reuse**: semantic receipt feedback, admitted-world manufacture, deterministic route registry, ggen manufacture, standing/verification receipts

## Problem

The ecosystem already has both halves of Machine Experience:

- runtime receipts can be projected back into typed semantic feedback with no authority;
- candidate domains/problems can be admitted and manufactured into formal, receipted worlds.

The missing closure is automatic compile-back: a successful UNKNOWN resolution must become reusable admitted machinery so that the same problem class is routed as KNOWN next time rather than repurchased as intelligence.

## Required change

Implement an Experience Compiler with the following state machine:

`UNKNOWN -> candidate -> admitted -> executed -> receipt evidence -> generalized candidate pattern -> admission -> manufactured deterministic capability -> registered KNOWN route`

Registration is a semantic change and therefore must itself be admitted, receipted, versioned and reversible. A successful one-off answer is insufficient.

## Laws

1. No experience is promoted from model text alone; promotion requires execution evidence/receipt.
2. Receipt feedback carries no authority.
3. Generalization produces a candidate pattern, never an immediately trusted rule.
4. Promotion must bind source evidence, ontology identity, capability identity, generator/manufacturer identity and verification result.
5. A promoted route must be at least as fenced as the UNKNOWN path it replaces.
6. On the next matching task, the deterministic KNOWN route is preferred over SHLLM/frontier inference.
7. Failed or contradictory evidence cannot silently mutate the canonical graph.

## Chicago falsifiers

1. One successful UNKNOWN episode without a promotion admission does not change routing.
2. An admitted promotion creates a new deterministic route and the next matching episode makes zero LLM calls.
3. Tampered receipt evidence cannot be promoted.
4. A promoted capability cannot widen authority relative to its admitted contract.
5. Contradictory new evidence produces a new candidate/requalification event, not silent overwrite.
6. Removing the promoted capability returns the task to UNKNOWN without corrupting prior receipts.

## Definition of done

- Experience Compiler has a typed input/output contract;
- one real UNKNOWN fixture is solved, receipted, promoted, manufactured and then rerun through a zero-LLM KNOWN path;
- promotion provenance is content-addressed and queryable;
- exact-head tests prove all six falsifiers;
- telemetry can measure the derivative target: repeated-task LLM usage decreases after admitted experience.
