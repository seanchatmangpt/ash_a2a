# ash_a2a v26.9.16 — RFC Closure Contract

Status: DRAFT IMPLEMENTATION PR. No merge, publication, runtime ALIVE, or production-standing claim until the acceptance courts below pass at exact head.

## Canonical Jira tickets

- A2A-2604 — wire semantic admission into the live authority/DO path
- A2A-2605 — CMCA bounded resource-allocation control plane
- A2A-2611 — SHLLM bounded local UNKNOWN tier
- A2A-2612 — machine-experience compile-back

Canonical ticket text lives on `main` under `docs/jira/v26.9.16/`.

## RFC ownership

This repo owns the live protocol/control-plane closure for:

1. `Received != Admitted` on the actual dispatch path.
2. `SELECT != CONSTRUCT != DO` across semantic planning, authority, and CommandBus.
3. `LLMOutput => Candidate`, never canonical state or authority.
4. KNOWN work must take the deterministic route when an admitted capability exists.
5. UNKNOWN work must be classified and routed through an explicit bounded allocation decision.
6. No resource consumer may self-increase its inference/execution budget.
7. Frontier inference is an explicit overflow allocation, never an implicit default.
8. Successful UNKNOWN resolution must return typed evidence suitable for compile-back into future KNOWN machinery.
9. CommandBus remains the sole consequence-bearing path and preserves the existing receipt/outbox invariants.

## Existing machinery to reuse

- `AshA2A.Planning.RequestRouter`
- `AshA2A.Planning.HddlDeterministicSynthesis`
- `AshA2A.Semantic.Admission`
- `AshA2A.Semantic.Compiler`
- `AshA2A.Semantic.Feedback`
- `AshA2A.Authority.Broker`
- `AshA2A.CommandBus`
- `AshA2A.ReceiptOutbox`
- `AshA2A.LLMProfiles`

Do not manufacture parallel subsystems when these seams already exist.

## Required closure

`Message -> Semantic Admission -> Work Classification -> CMCA -> {KNOWN deterministic | UNKNOWN local | UNKNOWN deferred | UNKNOWN frontier} -> Candidate -> Admission -> Command construction -> Authority -> CommandBus -> Receipt -> Semantic Feedback -> Machine Experience`

The deterministic KNOWN route must be observationally provable to avoid the LLM seam.

## Chicago falsifiers

The exact-head suite must fail if any of the following becomes possible:

- semantic/planning candidate reaches Authority.Broker without passing the required admission fence;
- a model response grants authority or writes canonical state;
- a KNOWN request calls an LLM when a deterministic admitted capability is available;
- an UNKNOWN request silently falls through to a provider without a bounded allocation receipt;
- a model/provider can enlarge its own token, time, concurrency, or retry budget;
- local-model failure silently escalates to frontier inference without an explicit allocation decision;
- receipt feedback can directly actuate or grant authority;
- compile-back registers a KNOWN route without admission/qualification evidence;
- any consequence path bypasses CommandBus or the pre-DO receipt anchor.

## Definition of done

- all four Jira tickets are implemented, not merely documented;
- full suite + repository architecture verifier pass at literal PR head;
- paired positive/negative courts prove deterministic KNOWN bypass and bounded UNKNOWN escalation;
- exact-head CI records checkout identity before verification;
- PR body records the exact evidence boundary and cross-repo subjects consumed;
- no claim of system-wide RFC closure until the dependent v26.9.16 PRs in ggen, bcinr, unrdf, ash_r2rml, ggen_igniter, wasm4pm, affidavit, autofde-lab, and the local-model provider are qualified.
