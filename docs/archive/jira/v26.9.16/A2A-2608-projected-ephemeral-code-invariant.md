# A2A-2608: enforce projected-ephemeral software as an invariant

- **Status**: OPEN
- **Severity**: High
- **Standing**: `PARTIAL_ALIVE`
- **Owning repos**: `seanchatmangpt/ggen`, `seanchatmangpt/ash_r2rml`; consumers ecosystem-wide

## Problem

The ecosystem already has deterministic RDF-driven generation, graph hashing, deltas, transition receipts, semantic parity witnesses, and generated artifacts. The missing closure is a hard rule that generated code is only a disposable projection of admitted semantic state and may not become an independent semantic source.

Without that invariant, hand patches can reintroduce semantic drift and force later agents to interpret arbitrary code.

## Required change

Define and enforce:

`C_t = projection(O*, generator, toolchain, environment)`

where `C_t` has no independent semantic authority.

Repair targets are limited to:

- admitted semantic source `O*`;
- generator/manufacturer;
- verifier;
- declared environment/toolchain.

Generated output must be regenerated, not semantically patched in place.

## Laws

1. Source-of-truth identity is the admitted graph/spec identity, not the generated file tree.
2. Generated files carry provenance back to graph, query/template/generator and toolchain identities.
3. A direct mutation to generated output fails qualification unless reproduced by the manufacturer from admitted source.
4. Regeneration from identical admitted inputs is deterministic within the declared environment.
5. Semantic parity gates fail closed on projection drift.
6. Generated code never grants authority by existing.

## Chicago falsifiers

1. Tampering with one generated line without changing `O*` causes qualification failure.
2. Regenerating restores the canonical projection byte-for-byte where determinism is promised.
3. A change to `O*` produces a new projection identity and receipt.
4. A generated artifact with missing provenance cannot be promoted.
5. A consumer cannot treat a generated artifact as a new ontology/source without explicit re-admission.

## Definition of done

- generation manifests bind graph/query/template/generator/toolchain identities;
- repository-native qualification detects hand drift;
- repair workflow points upstream to `O*`/manufacturer rather than patching output;
- one end-to-end fixture proves tamper -> refusal -> upstream repair -> regeneration -> admission.
