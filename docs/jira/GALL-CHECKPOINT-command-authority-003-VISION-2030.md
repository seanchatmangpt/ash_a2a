# Vision 2030 — ash_a2a as the Semantic Consequence Plane

> **Design horizon, not prediction.**
>
> Assume models become much more capable. Capability does not create authority. ash_a2a exists so increasingly capable machines still cross the world-changing boundary through explicit semantic identity, bounded authority, durable receipts, and replay-safe execution.

## 1. Thesis

By 2030, `ash_a2a` is the **semantic consequence plane** for machine-to-machine systems.

The foundational separation is permanent:

[
Agent 
eq Authority
]

[
Message 
eq Fact
]

[
Capability 
eq Authority
]

[
Plan 
eq Authority
]

[
SELECT 
eq CONSTRUCT 
eq DO
]

The more capable agents become, the more valuable these separations become.

## 2. Beyond “agent communication”

A2A systems are often described as agents sending messages to agents.

Semantic A2A changes the unit of interoperation.

The 2030 unit is:

[
AdmittedSemanticSubject
+
ExactCapability
+
AuthorityGrant
+
ConsequenceContract
+
Receipt
]

Messages are transport.

Semantics, authority, and receipts determine standing.

## 3. Non-LLM actuation by default

By 2030, most consequential enterprise work should not require an LLM at the actuation boundary.

A model may help discover a candidate route.

Once a route is known:

[
SemanticEvent
ightarrow
DeterministicCapabilityResolution
ightarrow
Authority
ightarrow
CommandBus
ightarrow
DO
]

This enables:

- BEAM processes;
- WASM components;
- AtomVM/edge devices;
- traditional services;
- databases;
- schedulers;
- workflow engines;
- hardware controllers;
- CLI tools;
- serverless functions;

to participate as first-class semantic actors without pretending to be conversational agents.

## 4. Exact capability identity

By 2030, display names are user-interface conveniences, never consequence identity.

Every capability has a canonical machine identity bound to:

- semantic subject;
- provider;
- version;
- input/output contract;
- authority requirements;
- consequence class;
- replay behavior.

Ambiguity is a refusal condition.

The duplicate-action-name defect captured in GALL-003 becomes a foundational law:

[
AmbiguousSelector Rightarrow REFUSED
]

not “pick the first thing that looks right.”

## 5. Authority algebra

Authority becomes explicit data.

A consequence executes only when:

[
A_{effective}
=
A_{request}
cap
A_{capability}
cap
A_{principal}
cap
A_{environment}
cap
A_{policy}
]

If the intersection is empty, the system refuses.

No model output, plan, tool description, semantic proof, or prior success can expand authority.

## 6. The consequence envelope

Every DO occurs inside an admitted envelope:

[
E =
{
subject,
capability,
principal,
authority,
budget,
preconditions,
idempotency,
receiptAnchor,
consequenceClass
}
]

The envelope bounds:

- what may happen;
- where;
- how many times;
- at what cost;
- under whose authority;
- with which durable evidence.

## 7. Zero unreceipted actuation

The 2030 invariant remains:

[
DO Rightarrow PreparedReceipt
]

This is stronger than logging after the fact.

The system durably establishes the consequence identity before crossing the consequence boundary.

If finalization becomes uncertain:

[
Uncertain 
eq Success
]

The system preserves uncertainty and reconciles.

## 8. Crash-window semantics

Distributed machine systems fail between steps.

The architecture therefore treats:

[
ExternalAck ightarrow Crash ightarrow Recovery
]

as a normal state transition, not an exceptional corner case.

The required property:

[
Replay(CommandIdentity)
Rightarrow
ExternalOperationCount le 1
]

where the claimed capability supports exactly-once semantic consequence through its bounded idempotency model.

## 9. Semantic protocol federation

By 2030, ash_a2a can bridge public transports without collapsing their semantics:

- A2A;
- MCP;
- HTTP;
- event buses;
- BEAM messaging;
- WASM host calls;
- workflow systems;
- edge runtimes.

Transport adapters translate envelopes.

They do not invent authority.

## 10. Machine economies

Once semantic capability and authority are explicit, machines can coordinate work without conversational overhead.

The system can ask:

- Which provider can perform this admitted capability?
- Under which authority?
- With what cost/latency/reliability?
- Which consequence receipt will result?
- Which provider has the strongest qualified evidence?

This creates a machine-native service economy whose contracts are executable rather than prose-only.

## 11. Intelligence becomes optional infrastructure

By 2030:

[
LLM in CandidateGeneration
]

is common.

But:

[
LLM 
otin RequiredDOPath
]

for known deterministic capabilities.

This is the economic phase change.

Semantic A2A makes intelligence a replaceable upstream producer of candidates, not the permanent runtime tax on every consequence.

## 12. 2030 crown capabilities

1. Semantic Agent/Capability Cards
2. Exact capability IDs
3. Public ontology interoperability
4. Authority algebra
5. Prepared-receipt-before-DO
6. Single consequence boundary
7. Crash-window reconciliation
8. Replay-safe idempotency
9. Bounded fan-out
10. Protocol federation
11. Non-LLM actor participation
12. Edge/BEAM/WASM actors
13. Receipt algebra
14. MachineExperience feedback
15. Typed refusal as protocol behavior

## 13. What disappears

By 2030, governed machine interaction should no longer depend on:

- natural-language tool selection for known capabilities;
- ambient credentials;
- untyped “agent permissions”;
- display-name actuation;
- invisible retries;
- actuation before durable identity;
- success claims without receipts;
- LLM presence merely because the original workflow used an LLM.

## 14. GALL trajectory

GALL-003 proves the first hard consequence seal.

The 2030 trajectory expands:

[
OneExactCapability
ightarrow
ManyCapabilities
ightarrow
ManyRuntimes
ightarrow
ManyOrganizations
]

while retaining the same law:

[

eg Standing(x) Rightarrow 
eg Consequence(x)
]

## 15. 2030 falsifiers

The vision fails if:

- agents carry ambient authority;
- messages are treated as facts;
- display names can select consequential skills ambiguously;
- retries can silently duplicate DO;
- an LLM is required for known deterministic actuation;
- authority cannot be independently reconstructed;
- receipts are post-hoc logs rather than part of the actuation law.

## 16. Final compression

By 2030:

[
oxed{
ash_a2a =
	ext{semantic capability plane}
+
	ext{authority boundary}
+
	ext{receipted consequence runtime}
}
]

The most important feature is not that more agents can talk.

It is that **anything can participate without being trusted merely because it is intelligent**.
