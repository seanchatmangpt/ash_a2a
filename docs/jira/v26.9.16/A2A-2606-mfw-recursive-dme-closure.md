# A2A-2606: close MFW as the recursive DME manufacture loop

- **Status**: OPEN
- **Severity**: High
- **Standing**: `PARTIAL_ALIVE`
- **Owning repos**: `seanchatmangpt/ggen`, `seanchatmangpt/bcinr`; integration in `seanchatmangpt/ash_a2a`
- **Reuse**: `bcinr-mfw-ir`, `bcinr-pddl`, POWL projection, consequence horizons, receipts

## Problem

MFW already has bounded IR, content-addressed identities, epoch bounds, causal/concurrency witnesses, formal-standing contracts, and search portfolios. What is not yet closed is the recursive DME loop in which unresolved obligations become newly bounded planning epochs and successful resolutions feed back as reusable machinery.

The missing work is composition, not a new planner.

## Required change

Define one repository-native recursive contract:

`admitted world -> bounded epoch -> SELECT -> projection -> execution package -> receipt -> residual obligations -> next epoch | closure`

Every recursive edge must carry a descent/bound witness. Failure to demonstrate descent must refuse rather than recurse.

## Laws

1. Every child epoch references one parent epoch and one residual obligation set.
2. Recursion requires an explicit descent measure.
3. A closed consequence horizon emits no successor epoch.
4. Planner output remains candidate-only until the downstream admission boundary accepts it.
5. Receipt feedback cannot grant authority.
6. Identical admitted epoch + profile produces identical semantic identity and projection witness.

## Chicago falsifiers

1. A closed plan terminates without manufacturing a successor epoch.
2. A non-descending residual loop is refused before recursive execution.
3. A child epoch cannot change the parent's admitted ontology identity silently.
4. Receipt feedback can alter observations/residuals but cannot mint authority.
5. Replay of a prior epoch does not create a second DO.

## Definition of done

- one executable orchestration path composes the existing MFW IR, planner, projection and receipt machinery;
- recursive termination/bounds are machine-checkable;
- residual UNKNOWN is explicit rather than hidden behind another LLM call;
- exact-head tests exercise closure, recursion, refusal, and replay.
