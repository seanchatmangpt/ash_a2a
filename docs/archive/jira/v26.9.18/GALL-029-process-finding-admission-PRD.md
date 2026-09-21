# PRD v26.9.18 — GALL-029: Process Finding Admission

**Status:** DRAFT IMPLEMENTATION SPEC  
**Release:** v26.9.18  
**Repository:** `seanchatmangpt/ash_a2a`  
**Owner:** ash_a2a  
**Dependencies:** GALL-026..028 findings, GALL-012 predictions optionally  
**Authority ceiling:** ADMIT candidate only; no consequence yet

## Product outcome
ash_a2a consumes typed external findings, verifies provenance/subject/evidence ceiling, and emits an admitted intervention candidate or typed refusal without granting authority or executing anything.

## Problem
Conformance deltas, predictors and process findings are observations/analyses, not permission to act. A separate admission boundary is required before any process finding can become an actionable semantic candidate.

## Functional requirements
1. Define a public finding envelope carrying producer SHA, evidence digest, semantic/process subject, finding type, horizon and requested candidate class.
2. Verify producer/receipt identity against admitted allowlist/schema/public ontology.
3. Preserve evidence class: prediction, conformance, attribution and postcondition remain distinct.
4. Map admitted finding to candidate capability/objective only through explicit semantic rules.
5. Admission cannot grant authority, choose final action or perform DO.
6. Reject stale, mismatched, secret-bearing, private-ontology or insufficient-evidence findings.
7. Emit admission receipt linking source finding to candidate identity.

## Acceptance criteria
1. Valid GALL-026 finding becomes candidate intervention with exact provenance.
2. Prediction-only finding remains prediction-class candidate and cannot self-promote.
3. Stale producer/semantic subject refuses.
4. Bearer credential/authority secret in finding fails security court.
5. Unknown private vocabulary refuses or remains unsupported.
6. No CommandBus consequence occurs during admission.

## Evidence product
Emit a content-addressed receipt binding exact finding/process/runtime/authority subjects, attempted falsifiers, outputs and evidence ceiling. Analysis and admission remain weaker than authority until the explicit GALL-030 boundary.

## Definition of done
ash_a2a consumes typed external findings, verifies provenance/subject/evidence ceiling, and emits an admitted intervention candidate or typed refusal without granting authority or executing anything.
