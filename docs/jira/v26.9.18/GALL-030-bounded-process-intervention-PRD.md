# PRD v26.9.18 — GALL-030: Bounded Process Intervention

**Status:** DRAFT IMPLEMENTATION SPEC  
**Release:** v26.9.18  
**Repository:** `seanchatmangpt/ash_a2a`  
**Owner:** ash_a2a  
**Dependencies:** GALL-029 admitted finding, GALL-003 authority/receipt seal, GALL-004 independent observer  
**Authority ceiling:** bounded authorized DO through CommandBus

## Product outcome
One admitted process finding can trigger exactly one bounded, preflighted, authorized intervention whose consequence and independent postcondition are fully receipted.

## Problem
An admitted process finding is still not a lawful consequence. Intervention must bind one candidate to explicit authority, scope, budget, idempotency and postcondition, then cross the same receipted CommandBus boundary as every other consequence.

## Functional requirements
1. Require GALL-029 candidate admission receipt before intervention construction.
2. Construct consequence envelope with exact capability, target/process subject, authority requirement, scope/budget, idempotency and expected postcondition.
3. Preflight refusal conditions before authority request/DO.
4. Acquire explicit grant through existing authority broker; finding itself is never authority.
5. Use existing GALL-003 prepared-receipt CommandBus path exclusively.
6. Require GALL-004 independent verification for intervention success standing.
7. Support rollback/escalation candidate when postcondition fails; no hidden retry storm.

## Acceptance criteria
1. Finding without admission receipt cannot reach CommandBus.
2. Admitted finding without authority refuses before DO.
3. Authorized intervention performs exactly one scoped consequence.
4. Budget/scope mutation outside envelope is refused.
5. Independent observer confirms expected postcondition.
6. Failed postcondition does not report success and produces bounded rollback/escalation evidence.
7. Replay/idempotency keeps external operation count <=1 for exact command subject.

## Evidence product
Emit a content-addressed receipt binding exact finding/process/runtime/authority subjects, attempted falsifiers, outputs and evidence ceiling. Analysis and admission remain weaker than authority until the explicit GALL-030 boundary.

## Definition of done
One admitted process finding can trigger exactly one bounded, preflighted, authorized intervention whose consequence and independent postcondition are fully receipted.
