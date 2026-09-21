# ARD v26.9.18 — GALL-029: Process Finding Admission

**Status:** DRAFT ARCHITECTURE SPEC  
**Release:** v26.9.18  
**Repository:** `seanchatmangpt/ash_a2a`  
**Owner:** ash_a2a  
**Dependencies:** GALL-026..028 findings, GALL-012 predictions optionally  
**Authority ceiling:** ADMIT candidate only; no consequence yet

## Architecture objective
ash_a2a consumes typed external findings, verifies provenance/subject/evidence ceiling, and emits an admitted intervention candidate or typed refusal without granting authority or executing anything.

## Components
- public finding envelope/schema
- producer/evidence verifier
- semantic finding mapper
- evidence-class preservation model
- candidate admission receipt
- security/redaction gate

## Data/control flow
`Process/GNN/prediction finding -> provenance/schema/evidence validation -> semantic mapping -> admitted intervention CANDIDATE or REFUSED`

## Invariants
1. Define a public finding envelope carrying producer SHA, evidence digest, semantic/process subject, finding type, horizon and requested candidate class.
2. Verify producer/receipt identity against admitted allowlist/schema/public ontology.
3. Preserve evidence class: prediction, conformance, attribution and postcondition remain distinct.
4. Map admitted finding to candidate capability/objective only through explicit semantic rules.
5. Admission cannot grant authority, choose final action or perform DO.
6. Reject stale, mismatched, secret-bearing, private-ontology or insufficient-evidence findings.
7. Emit admission receipt linking source finding to candidate identity.

## Failure/refusal boundaries
- Stale/mismatched subject => REFUSED
- Unknown/private vocabulary => UNSUPPORTED/REFUSED
- Authority secret detected => hard refusal
- Finding insufficient for requested candidate class => PARTIAL/REFUSED

## Qualification court
- finding-envelope schema tests
- evidence-class preservation tests
- stale-subject falsifier
- secret-leakage falsifier
- zero-DO admission witness

## Boundary law
[
Finding \neq Admission \neq Authority,\quad Prediction \neq Fact,\quad SELECT \neq DO
]

Only GALL-030 may cross the process-intervention consequence boundary, and it must reuse the existing GALL-003 authority/receipt machinery.
