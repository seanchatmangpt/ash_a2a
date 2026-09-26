# RFC v26.9.26 — SA2A architecture capability interchange seed

## Ownership
ash_a2a transports and coordinates admitted architecture capability semantics. SA2A is not enterprise architecture and is not authority.

## Definition of done
1. Add typed payloads/references for ABB, ArchitectureContract, CandidateSBB, Qualification and exact subject identity.
2. Permit participants to OBSERVE/PROPOSE/SELECT candidates without self-declaring qualification or authority.
3. Conserve candidate digest, exact subject and architecture contract through Command/WorkOrder exchange.
4. Add HILT actor/context/accountability bindings to architecture decisions.
5. Refuse stale/mismatched contract, forged qualification and authority laundering.
6. Emit durable replay/OCEL evidence for architecture selection exchanges.
7. Demonstrate provider substitution without changing semantic SBB identity.
8. Keep SELECT != CONSTRUCT != DO.

SA2A must make architecture candidates portable, not make them true.
