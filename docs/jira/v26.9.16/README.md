# ash_a2a v26.9.16 — DME closure ticket set

This directory turns the 2026-09-16 cross-repository implementation audit into executable work.

The audit found the architecture is primarily a **closure problem, not an invention problem**: semantic law, deterministic planning, Knowledge Hooks, authority separation, BRCE, receipts, AtomVM and manufacturing primitives already exist. These tickets cover the nine surfaces that were not yet `ALIVE` as one composed system.

## Standing vocabulary

- `ALIVE` — real implementation path with repository evidence for the claimed boundary.
- `PARTIAL_ALIVE` — substantial machinery exists, but the claimed composition is not closed.
- `NOT_FOUND` — the named component was not evidenced; predecessor primitives may still be `ALIVE`.
- None of these tickets may infer merge, publication, hosted CI, deployment or production standing from source presence or local tests.

## Tickets

| ID | Surface | Current standing | Primary owner | Closure |
|---|---|---|---|---|
| [A2A-2604](A2A-2604-wire-semantic-admission-to-live-do-path.md) | semantic admission → authority → DO | `PARTIAL_ALIVE` | `ash_a2a` | make admission mandatory on live consequence path |
| [A2A-2605](A2A-2605-cmca-resource-allocation-control-plane.md) | CMCA | `PARTIAL_ALIVE` | `ggen` / `bcinr` | one bounded selector across deterministic/local/estate/frontier routes |
| [A2A-2606](A2A-2606-mfw-recursive-dme-closure.md) | MFW recursive DME loop | `PARTIAL_ALIVE` | `ggen` / `bcinr` | close receipt → residual → bounded successor epoch |
| [A2A-2607](A2A-2607-blue-river-dam-cross-repo-closure.md) | Blue River Dam | `PARTIAL_ALIVE` | cross-repo | make the Dam the typed upstream control plane |
| [A2A-2608](A2A-2608-projected-ephemeral-code-invariant.md) | projected ephemeral software | `PARTIAL_ALIVE` | `ggen` / `ash_r2rml` | prohibit generated output from becoming semantic source |
| [A2A-2609](A2A-2609-portable-graphlaw-wasm.md) | portable GraphLaw law binary | `PARTIAL_ALIVE` | `ggen` / `praxis` | content-addressed `graphlaw.wasm` with host parity |
| [A2A-2610](A2A-2610-atomvm-enterprise-idle-estate.md) | enterprise idle compute estate | `NOT_FOUND` controller / AtomVM `ALIVE` | `unrdf` | admitted host leases, bounds, drain, receipts |
| [A2A-2611](A2A-2611-shllm-bounded-local-unknown-tier.md) | SHLLM | `PARTIAL_ALIVE` | `ash_a2a` | canonical bounded local UNKNOWN inference tier |
| [A2A-2612](A2A-2612-machine-experience-compile-back.md) | Machine Experience | `PARTIAL_ALIVE` | cross-repo | compile successful UNKNOWN work into future zero-LLM KNOWN routes |

## Dependency order

The narrowest closure order is:

```text
A2A-2604  semantic fence on live DO path
    |
    +--> A2A-2611  bounded SHLLM
    |
    +--> A2A-2609  portable GraphLaw

A2A-2605  CMCA selector
    +--> A2A-2610  idle AtomVM estate
    +--> A2A-2611  SHLLM

A2A-2606  recursive MFW closure
    +--> A2A-2612  Machine Experience compile-back

A2A-2608  projected-ephemeral invariant
    +--> A2A-2612

A2A-2604 + 2605 + 2606 + 2608 + 2609 + 2610 + 2611 + 2612
    -> A2A-2607 Blue River Dam cross-repo closure
```

## Target closed loop

```text
O
 -> O* / admission
 -> classify
 -> CMCA
 -> {KNOWN deterministic | SHLLM | idle estate | frontier}
 -> candidate result
 -> admission
 -> SELECT
 -> CONSTRUCT
 -> authority
 -> BRCE / DO
 -> receipt
 -> standing
 -> Machine Experience compiler
 -> newly manufactured KNOWN route
```

The key derivative is operational, not rhetorical:

`repeated admitted experience => less required inference on the next matching episode`.

A task is not considered learned because an LLM solved it once. It is learned when the result has standing, can be manufactured/replayed, and a subsequent matching task can execute through the deterministic path without repurchasing the same intelligence.

## Non-goals for this ticket set

These tickets do **not** claim to solve Sybil-resistant identity issuance, universal program verification, arbitrary external-system transactional atomicity, or unbounded distributed planning. Those remain separate problems with separate evidence boundaries.

`PRFAQ.md` remains the earlier v26.9.16 working-backwards charter. This README is the later implementation-audit backlog and therefore may describe gaps that became visible only after the router/broker work advanced.
