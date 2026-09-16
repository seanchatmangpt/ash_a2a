# A2A-2611: define SHLLM as the bounded local UNKNOWN tier

- **Status**: OPEN
- **Severity**: High
- **Standing**: `PARTIAL_ALIVE`
- **Owning repos**: `seanchatmangpt/ash_a2a`, local-provider adapters such as `seanchatmangpt/ollama-ai-provider-v2`
- **Reuse**: `AshA2A.LLMProfiles`, local/custom Ollama provider support, CMCA route contract

## Problem

Local inference plumbing exists and `ash_a2a` already separates capability identity from provider/model identity. What is missing is a canonical SHLLM role with a bounded contract: local inference handles admitted UNKNOWN residue only, returns candidate semantic artifacts, and has no direct authority or DO path.

## Required change

Add an abstract SHLLM capability/profile whose input is an admitted UNKNOWN task package and whose output is one of:

- `CANDIDATE_SEMANTIC_ARTIFACT`
- `NO_CANDIDATE`
- `RESOURCE_EXHAUSTED`
- `UNSUPPORTED`
- `REFUSED`

Provider/model selection remains configuration. The profile must define finite token/time/concurrency/resource budgets and must never silently fall back to a frontier provider.

## Laws

1. SHLLM is reached only for UNKNOWN work selected by CMCA.
2. SHLLM output has `authority: :none` and candidate standing.
3. Provider/model identity is not part of capability identity.
4. Exhausted local budget yields an explicit result for CMCA; no implicit escalation.
5. Local tool access is capability-scoped and cannot bypass CommandBus.
6. A successful candidate must pass the same semantic admission as any frontier-model candidate.

## Chicago falsifiers

1. A KNOWN deterministic request cannot invoke SHLLM.
2. Switching local model provider leaves capability identity and authority unchanged.
3. Budget exhaustion produces `RESOURCE_EXHAUSTED`, not a remote model call.
4. A local model tool call cannot execute a consequence outside CommandBus.
5. Malformed/ungrounded output is refused by admission even when generated locally.

## Definition of done

- canonical SHLLM role/profile exists;
- one local provider implementation exercises it end to end;
- deterministic tests prove no frontier fallback and no authority acquisition;
- CMCA can consume explicit SHLLM outcomes;
- telemetry distinguishes local UNKNOWN inference from deterministic and frontier routes.
