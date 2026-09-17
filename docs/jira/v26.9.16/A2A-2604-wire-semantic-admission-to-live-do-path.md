# A2A-2604: wire semantic admission into the live consequence path

- **Status**: OPEN
- **Severity**: Critical
- **Standing**: `PARTIAL_ALIVE`
- **Owning repo**: `seanchatmangpt/ash_a2a`
- **Depends on**: existing `Semantic.Admission`, `Planning.candidate_fence/1`, `Authority.Grant`, `CommandBus`

## Problem

The repo already has deterministic semantic admission and candidate-only authority ceilings, and the real dispatch path already reaches `Authority.Broker` before consequence-bearing `CommandBus` execution. The remaining gap is compositional: the semantic/planning candidate fences are not the mandatory predecessor of the live authority/DO path.

The target law is:

`candidate semantic state -> ADMIT -> SELECT -> CONSTRUCT -> authority grant -> CommandBus/DO`

Never:

`candidate -> authority -> DO`

## Required change

Make an admitted semantic/planning package the only semantic input shape that may reach consequence-bearing command construction. Preserve existing observe-only paths where appropriate. Do not make admission itself an authority grant.

Required invariants:

1. `standing != :admitted` implies no `:change` / `:external_do` dispatch.
2. semantic admission always leaves `authority: :none`.
3. authority is acquired only after successful admission.
4. a broker grant cannot repair or bypass failed semantic admission.
5. deterministic KNOWN routing retains the same fence.
6. LLM output remains candidate-only until admission succeeds.

## Chicago falsifiers

1. Grounded admitted package + standing broker grant reaches one real DO and one receipt.
2. Ungrounded semantic candidate with a valid broker grant is refused before DO.
3. Admitted package with no authority is refused before DO.
4. Expired/revoked authority cannot turn an admitted package into DO.
5. Replaying an admitted package does not create a second consequence.
6. An LLM candidate cannot call `CommandBus` directly.

## Definition of done

- live `AshA2A.Agent` semantic dispatch traverses admission before consequence-bearing command construction;
- architecture verifier asserts the edge ordering;
- full tests pass with warnings-as-errors;
- exact-head test proves the negative paths above;
- no merge, publication, hosted-CI, runtime `ALIVE`, or production-standing claim is inferred from local verification alone.
