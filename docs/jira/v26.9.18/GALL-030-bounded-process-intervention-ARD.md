# ARD v26.9.18 — GALL-030: Bounded Process Intervention

**Status:** DRAFT ARCHITECTURE SPEC  
**Release:** v26.9.18  
**Repository:** `seanchatmangpt/ash_a2a`  
**Owner:** ash_a2a  
**Dependencies:** GALL-029 admitted finding, GALL-003 authority/receipt seal, GALL-004 independent observer  
**Authority ceiling:** bounded authorized DO through CommandBus

## Architecture objective
One admitted process finding can trigger exactly one bounded, preflighted, authorized intervention whose consequence and independent postcondition are fully receipted.

## Components
- intervention envelope builder
- preflight constraint checker
- existing authority broker
- existing GALL-003 CommandBus/ReceiptOutbox
- independent observer correlation adapter
- rollback/escalation result model

## Data/control flow
`GALL-029 candidate -> intervention envelope/preflight -> explicit authority -> prepared receipt -> CommandBus DO -> GALL-004 verify -> completed/refused/rollback candidate`

## Invariants
1. Require GALL-029 candidate admission receipt before intervention construction.
2. Construct consequence envelope with exact capability, target/process subject, authority requirement, scope/budget, idempotency and expected postcondition.
3. Preflight refusal conditions before authority request/DO.
4. Acquire explicit grant through existing authority broker; finding itself is never authority.
5. Use existing GALL-003 prepared-receipt CommandBus path exclusively.
6. Require GALL-004 independent verification for intervention success standing.
7. Support rollback/escalation candidate when postcondition fails; no hidden retry storm.

## Failure/refusal boundaries
- No admission => REFUSED
- No authority => REFUSED before DO
- Scope/budget violation => REFUSED
- Postcondition failed => FAILED/rollback candidate
- Uncertain external outcome => PENDING/reconcile

## Qualification court
- admission-required test
- authority refusal test
- scope/budget falsifier
- real single-DO fixture
- independent postcondition integration
- replay/idempotency court

## Boundary law
[
Finding \neq Admission \neq Authority,\quad Prediction \neq Fact,\quad SELECT \neq DO
]

Only GALL-030 may cross the process-intervention consequence boundary, and it must reuse the existing GALL-003 authority/receipt machinery.
