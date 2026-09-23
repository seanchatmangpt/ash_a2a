# A2A-2605: compose CMCA as the bounded resource-allocation control plane

- **Status**: OPEN
- **Severity**: High
- **Standing**: `PARTIAL_ALIVE`
- **Owning repos**: `seanchatmangpt/ggen`, `seanchatmangpt/bcinr`, integration surface in `seanchatmangpt/ash_a2a`
- **Reuse**: Q-lens, frontier measures, cost vectors, fair-rail scheduling, MFW portfolio/search machinery

## Problem

The ecosystem already has most of the optimization primitives needed for Combinatorial Maximalism Compute Allocation (CMCA), but there is no single admitted selector that chooses among deterministic execution, local inference, idle-estate compute, and frontier inference under one bounded objective.

The missing object is not another agent. It is a lawful selector over already-described execution classes.

## Required change

Introduce a canonical CMCA decision object with inputs sufficient to choose the least-cost lawful route while preserving authority separation.

Minimum route classes:

- `KNOWN_DETERMINISTIC`
- `UNKNOWN_LOCAL`
- `UNKNOWN_IDLE_ESTATE`
- `UNKNOWN_FRONTIER`
- `REFUSED`

Decision inputs must include at least semantic standing, capability fit, consequence class, authority requirement, resource envelope, expected cost, deadline/latency class, and evidence obligations.

CMCA may SELECT a route. It must not grant authority, execute DO, or mutate ontology.

## Laws

1. If deterministic machinery satisfies the admitted goal, no LLM route may be selected.
2. Local/idle/frontier routes are considered only for unresolved UNKNOWN residue.
3. Resource budgets are finite and explicit; no implicit infinite retry or fan-out.
4. Route selection is deterministic for identical admitted inputs and policy profile.
5. Every decision is receipted/content-addressed.
6. A higher-capability route is refused when a lower-cost lawful route satisfies the same admitted contract.

## Chicago falsifiers

1. A KNOWN task with a frontier model available still selects deterministic execution.
2. Exhausted local budget cannot silently spill into frontier inference without an admitted policy permitting it.
3. Two identical admitted requests produce byte-identical route decisions.
4. Unknown consequence class is refused rather than optimized.
5. CMCA output cannot itself satisfy `Authority.admits?/2`.

## Definition of done

- one canonical CMCA IR exists;
- current bcinr/ggen optimization primitives are reused rather than duplicated;
- ash_a2a can consume the decision without interpreting free-form prose;
- route decision receipt records why a more expensive route was or was not selected;
- exact-head repository-native tests cover all five falsifiers.
