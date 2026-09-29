# RFC-SA2A-006-v26.9.28

Adversarial Control-Plane and Cryptographically Bounded Actuation

**Status:** PROPOSED NORMATIVE (candidate text; not yet reconciled with implementation)
**Relationship:** security profile successor to RFC-SA2A-004; sibling of RFC-SA2A-005
(the CWE/court security profile). Numbered 006 because 005 is taken.
**Provenance:** operator-supplied text, saved verbatim in substance. The editorial note
below is part of that text. The companion file
`RFC-SA2A-006-existing-substrate-map-v26.9.28.md` maps each requirement to existing
technology found under `~` before any new mechanism is proposed (section 5).

> Editorial note: this document is written in the style of a hypothetical joint
> NIST/MITRE/Erlang-OTP architectural review. It is not an official publication or
> endorsement by those organizations.

## Table of contents

1. Security objective; 2. Threat model; 3. Control is not authority; 4. Assume failure;
5. Mature-substrate conservation; 6. Canonical system model; 7. Trust domains;
8. CMCA resource conservation; 9. Effect identity; 10. Canonical encoding;
11. PreparedEffect; 12. Durable preparation; 13. External cryptographic authority;
14. Post-quantum signature profile; 15. Multiple independent authorities;
16. Final actuation fence; 17. No ambient credentials; 18. Complete mediation;
19. Confused-deputy resistance; 20. Replay; 21. Unknown outcome;
22. Dangerous primitive elimination; 23. BEAM/OTP kernel constraints; 24. Standing;
25. Receipts; 26-29. Courts; 30. CWE claims; 31. Profiles; 32. Required changes;
33. Theorem; 34-39. Consequences and targets.

## 1. Security objective

A conforming SA2A system SHALL NOT rely on the correctness, honesty, alignment or
uncompromised state of probabilistic intelligence to prevent unauthorized actuation.

```text
ArbitraryIntelligence -> Candidate          (never -> Authority, never -> DO)
Compromise(ControlPlane) does NOT imply UnauthorizedActuation
```

The control plane includes language models, prompts, memories, retrieval, planners,
semantic reasoners, agent processes, orchestration, protocol peers, MCP/A2A endpoints,
application state and the primary AshA2A runtime. The system MUST remain able to refuse
unauthorized actuation when the attacker controls the AshA2A application host, provided
the independently protected authority and actuation domains remain uncompromised.

Protected actuation requires an independently verifiable chain:

```text
ExactIdentity -> Admission -> BoundedAllocation -> Construction -> EffectClaim
  -> DurablePrepare -> ExternalAuthority -> ActuationCertificate -> DO
  -> Observation -> Verification -> Receipt
```

Four independent containments: (1) BEAM/OTP fault containment (substrate properties, not
reimplemented agent-runtime features); (2) CMCA resource containment (intelligence cannot
manufacture budget); (3) SA2A semantic and authority containment (candidates cannot
manufacture authority); (4) cryptographic actuation containment (possession of the
control plane does not confer the authority protected actuators accept).

## 2. Threat model

The adversary MAY control any combination of: LLM output, system prompts, retrieved
context, agent memory, planners, semantic reasoning, generated code, model/provider
responses, A2A peers, MCP servers, agent processes, application databases, caches, message
queues, orchestration, candidate-generation services, scheduling requests, control-plane
telemetry, the AshA2A process and (strongest profile) administrative/root access to the
control-plane host. The adversary MAY manufacture arbitrary candidates, commands, plans,
internal records, proposed capabilities, alleged observations, unsigned receipts, fake
internal standing, fake allocations and requests for authority. None SHALL suffice for
protected DO. The adversary is outside the protection boundary only when sufficient
independently protected authority components, or the actuator itself, are compromised.

## 3. Control is not authority

`Control(System) != Authority(System)`; `Control(AshA2A) != Authority(Actuator)`.
Protected actuator credentials MUST NOT be available to an LLM process, agent process,
planner, CMCA, semantic engine, A2A/MCP transport, generic CommandBus caller, the ordinary
application environment, or (compromise-tolerant profile) the control-plane host.
Authority MUST reside in a distinct authority domain.

## 4. Assume failure

Component failure is an expected operating condition. AshA2A MUST use BEAM/OTP lifecycle
semantics directly wherever they satisfy the requirement, and MUST NOT create parallel
agent-specific abstractions for supervision, restart orchestration, child lifecycle,
health monitoring, actor emulation, mailbox replacement or secondary fault propagation
without a documented falsifier proving the mature substrate cannot satisfy the admitted
requirement.

## 5. Mature-substrate conservation

For requirement R, search downward: `BEAM -> OTP -> Ash -> EstablishedPriorArt ->
SA2AExtension`. A higher layer MUST NOT reimplement a property already satisfied at a
lower mature layer unless an executable falsifier demonstrates inadequacy. A replacement
MUST preserve the constraints of what it replaces: FeatureEquivalence does not imply
ConstraintEquivalence; APIEquivalence does not imply SystemEquivalence. Mature absences
carry provisional standing as possible historically derived constraints until falsified
(negative Chesterton's Fence). Operator addendum: "prior art" includes technology already
present under `~` (see the substrate map) before anything external.

## 6. Canonical system model

```text
O -> O* -> DfCM -> PlannerSet -> CMCA -> SELECT -> CONSTRUCT -> PreparedEffect
  -> Authority -> ActuationCertificate -> DO -> Observe -> Verify -> Receipt -> Standing
```

Absolute distinctions: UNKNOWN != ADMITTED; CANDIDATE != ADMITTED; ADMITTED != SELECTED;
SELECTED != CONSTRUCTED; CONSTRUCTED != AUTHORIZED; AUTHORIZED != EXECUTED;
EXECUTED != VERIFIED; VERIFIED != ATTESTED. CMCA allocates but does not actuate; planning
proposes but does not actuate; construction manufactures but does not actuate; proof and
agent output are not execution authority.

## 7. Trust domains

- **7.1 Candidate domain** (hostile): LLMs, prompts, planners, RAG, agent logic, memories,
  external peers, generated code, semantic engines. May create candidates; MUST NOT hold
  protected actuator credentials.
- **7.2 Allocation domain** (CMCA): may assign bounded resource mass to admitted
  candidates; MUST NOT issue actuation authority or create resource mass.
- **7.3 Semantic consequence domain** (AshA2A): exact identity binding, admission, effect
  identity derivation, effect-instance binding, durable preparation, policy closure,
  consequence classification. Constructs a powerless `PreparedEffect`.
- **7.4 Authority domain**: operationally independent of the control plane. Receives a
  canonical PreparedEffect identity, decides authority, issues an `ActuationCertificate`,
  MUST NOT execute the effect.
- **7.5 Actuator domain**: deliberately unintelligent; no LLM, autonomous planner,
  arbitrary code evaluation, generic agent logic, general policy reasoning or unrestricted
  credential delegation. Verification plus narrowly bounded execution only.

## 8. CMCA resource conservation

Intelligence MUST NOT manufacture resources by decomposition, delegation, recursion or
process creation. For every parent allocation `B_p`: `sum(B_children) <= B_p`; for every
consequential operation `Cost(effect) <= B_admitted`. Recursion does not increase total
admitted allocation; extra workers divide or consume admitted capacity. A request to
spawn, schedule, delegate, raise model tier, raise concurrency or raise verification depth
remains a request until allocation is admitted. CMCA decisions MUST be replayable from
admitted inputs and configuration identity. CMCA MUST NOT communicate with protected
actuators.

## 9. Effect identity

Separate identities for request, semantic subject, task, capability, effect class, effect
instance, execution attempt, authority decision and receipt. Request identity is not
effect identity. A legitimate repeated effect MUST obtain a new explicit
`effect_instance_id`. The same `effect_instance_id` means the same intended real-world
consequence regardless of transport retry, agent, provider, process, node, request id or
attempt: `SameEffectInstance => AtMostOneAdmittedDO`.

## 10. Canonical encoding

Security-critical identities MUST use one protocol-defined canonical encoding; language
native serialization MUST NOT define protocol identity. The baseline profile SHOULD use a
standards-defined deterministic encoding and a FIPS-approved digest. Erlang term
serialization MUST NOT be the portable identity for authority, effect identity,
PreparedEffect, ActuationCertificate or cross-domain receipts. Canonicalization occurs
before authorization; map key representation, atoms, object identity, PIDs and provider
values MUST NOT change semantic identity.

## 11. PreparedEffect

Contains at least: protocol version, principal identity, exact semantic subject, task,
capability, consequence class, canonical input digest, effect-instance identity, request
identity, admitted resource envelope, policy identity, capability-release identity,
construction identity, preparation epoch, expiry, predecessor/replay identity, and the
canonical PreparedEffect digest. A caller MUST NOT construct authoritative instances; the
consequence subsystem creates and persists them.

## 12. Durable preparation

No `change` or `external_do` occurs without a durable PreparedEffect, persisted before DO,
whose identity the final actuator validates. Security MUST NOT depend on a process
dictionary entry, a caller-provided receipt object, a transient process token, an
invocation option or an in-memory assertion. Durable preparation prevents unsafe retry
after control-plane process death.

## 13. External cryptographic authority

The strongest profile requires authority outside the control-plane compromise domain,
bound to the exact PreparedEffect digest, never to vague ambient authority ("principal P
may operate service S"). `E = H(version, principal, subject, capability, effectInstance,
inputDigest, resourceBounds, policyEpoch, expiry)`; `Certificate = Sign_Authority(E)`.
Changing any security-relevant field invalidates the certificate.

## 14. Post-quantum signature profile

The baseline suite MAY use NIST-standardized ML-DSA (FIPS 204) or SLH-DSA (FIPS 205). The
protocol remains algorithm-agile; algorithm identity is bound into the signed object. A
conforming implementation SHALL NOT invent a proprietary post-quantum signature scheme.

## 15. Multiple independent authorities

For high-consequence effects one compromised authority SHOULD NOT suffice: independently
held keys and an admitted k-of-n set of valid signatures (`DO => ValidSigners >= k`).
Until a threshold construction has sufficient standardization and implementation
standing, prefer multiple independent standardized signatures over bespoke threshold
cryptography. `Compromise(Signer_i)` does not imply DO for `k > 1`.

## 16. Final actuation fence

The actuator MUST independently verify, immediately before DO: protocol version;
canonical PreparedEffect digest; principal; exact subject; capability; consequence class;
effect-instance identity; resource bounds; policy epoch; certificate validity; signature
algorithm; required quorum; expiry; revocation state; effect-claim ownership; whether the
effect instance has previously completed; whether the execution generation is current.
No positive assertion from the candidate or control plane substitutes. Fail closed.

## 17. No ambient credentials

Protected actuator credentials MUST NOT exist as ordinary application environment
variables, agent state, model context, tool configuration, callback state, planner state,
process-dictionary values, generic application secrets or inherited service credentials
inside the untrusted control plane. A compromised control-plane node MUST remain
cryptographically incapable of manufacturing a valid ActuationCertificate.

## 18. Complete mediation

All protected consequence crosses one normative actuation interface. No alternate
dispatcher, direct Ash action, plugin, callback, worker, MCP tool, A2A method, scheduled
job, shell command, HTTP adapter, database adapter or developer escape hatch produces
equivalent protected consequence without the same certificate and effect-instance checks.
Complete mediation is a graph property, not a caller convention.

## 19. Confused-deputy resistance

The initiating principal survives every transformation to the actuator; an intermediary
MUST NOT substitute its own service identity for authorization. `Principal_DO =
Principal_PreparedEffect = Principal_Authority` unless an explicit, bounded,
provenance-preserving delegation is admitted. Delegation MUST NOT amplify authority.

## 20. Replay

Replay retrieves or reconstructs evidence and never repeats consequence:
`Replay(effectInstance) -> PriorEvidence`, never `-> SecondDO`. A new intentional
consequence requires a new effect-instance identity.

## 21. Unknown outcome

An execution whose external result cannot be established enters `UNKNOWN_OUTCOME`, which
is not ordinary failure. Automatic retry of the same effect instance is prohibited.
Permitted exits: observation, reconciliation, verification, compensation under separate
authority, explicit administrative resolution. Process restart does not imply consequence
retry: `WorkerFailure != EffectFailure`.

## 22. Dangerous primitive elimination

Within the kernel and actuator, project-controlled code SHOULD eliminate generic dangerous
representations rather than sanitize them: no arbitrary shell command strings, executable
module/function names, host filesystem paths, network URLs, SQL strings, object
deserialization or unrestricted dynamic code loading. Use narrow typed capabilities:
`EndpointCapability`, `FileObject`, `DeclaredExecutable` plus typed arguments, typed data
operations. Objective: `DangerousRepresentation` not in `ReachableProtocolValues`.

## 23. BEAM/OTP kernel constraints

The security kernel SHOULD remain ordinary memory-safe BEAM code, avoiding NIFs, arbitrary
ports, shell invocation, dynamic code evaluation, uncontrolled `apply/3`, atoms generated
from untrusted values, security-sensitive process-dictionary state, unrestricted node
distribution and unsupervised long-lived processes. This does not assert BEAM/OTP
eliminate all defects; it minimizes lower-level mechanisms AshA2A itself introduces.

## 24. Standing

Derived from evidence; a candidate SHALL NOT self-assign admitted, authorized, executed,
verified, alive, trusted or released standing. `Standing = f(Admission, Authority,
Execution, Observation, Verification, Provenance)`. Receipt existence does not imply truth.

## 25. Receipts

A terminal receipt binds the PreparedEffect digest, ActuationCertificate identity,
authority identities, effect-instance identity, execution identity, observed response and
consequence, verification result, terminal status, policy/release identity, predecessor,
timestamp/ordering evidence and integrity protection. Receipts crossing trust boundaries
use authenticated integrity; unsigned internal logs do not gain standing by being stored.

## 26. Control-plane compromise court

The harness gets arbitrary control of the candidate/control plane and attempts at least:
forged Command; forged capability; forged PreparedEffect; forged internal receipt; fake
standing; direct Dispatcher invocation; direct Ash mutation; mutated exact subject;
mutated canonical input; fresh request id for an existing effect instance; replay of a
valid certificate; expired certificate; stale policy epoch; revoked authority;
insufficient quorum; single compromised signer below quorum; duplicated DO; worker crash
before DO; crash during uncertain DO; restart after unknown outcome; resource-budget
amplification; recursive agent spawning; fan-out amplification; policy-option removal;
kill-switch bypass; alternate adapter path; arbitrary URL substitution; path
substitution; command injection; arbitrary deserialization payload. Required outcome:
refusal or no unauthorized consequence. An exception, crash or timeout alone is not proof
if an external consequence may have occurred.

## 27. Architecture closure court

Source-regex scanning is insufficient evidence of complete mediation. AshA2A SHALL derive
or inspect the actual dependency/call topology; every protected effector edge MUST
originate from the admitted consequence boundary; the court fails if a new module adds a
second DO path: `Paths(Candidate, ProtectedDO) = {CanonicalConsequencePath}`.

## 28. Resource-conservation court

For arbitrary recursive generation, delegation, retry, scheduling and spawning,
`AllocatedDescendants <= AllocatedAncestor` MUST hold; property-based adversarial
generation SHOULD attempt amplification; CMCA MUST refuse or normalize structures that
would manufacture resource mass.

## 29. Fault-injection court

Inject failures at: before/after request claim; after effect claim; before/after durable
prepare; before/after authority; before actuator submission; during actuator execution;
after DO before response; during verification; before receipt commit. For every point
prove one of: no consequence occurred; exactly one consequence occurred and is
reconcilable; outcome is explicitly unknown and automatic replay is prohibited.

## 30. CWE elimination claims

Only where an executable court shows the weakness precondition unreachable within the
declared AshA2A scope. Reports distinguish UNREPRESENTABLE (primitive does not exist),
UNREACHABLE (state cannot be reached through the admitted graph), CONTAINED (defect cannot
independently reach protected DO) and RESIDUAL (still depends on this mechanism). No claim
outside the declared control boundary.

## 31. Conformance profiles

- **SA2A-C0 Semantic separation:** candidate/admitted separation, exact subject,
  SELECT/CONSTRUCT/DO. No strong compromise-tolerance claim.
- **SA2A-C1 Receipted consequence:** adds effect-instance identity, mandatory effect
  claim, durable preparation, exclusive DO path, unknown-outcome semantics, receipt/replay.
  Claim: `Compromise(Intelligence)` does not imply UnauthorizedDO, assuming the kernel is
  trustworthy.
- **SA2A-C2 Adversarial control plane:** adds authority outside the control-plane trust
  domain, cryptographically bound exact-effect authorization, actuator-side independent
  verification, no protected credentials on the control-plane host. Claim:
  `Compromise(ControlPlane)` does not imply UnauthorizedDO, assuming authority and
  actuator domains remain uncompromised.
- **SA2A-C3 Multi-authority actuation:** adds independent authority domains, admitted
  k-of-n authorization, signer independence court, CMCA resource-conservation court.
  Claim: `Compromise(ControlPlane + fewer than k signers)` does not imply UnauthorizedDO.

## 32. Required AshA2A changes

Remove: caller-authoritative `resolved_skill`; process-dictionary BRCE anchors as security
proof; caller-selected security modes; permissive effect dedup for consequential effects;
portable identity from Erlang term serialization; generic direct Dispatcher paths;
security-critical source-regex verification; unsigned authoritative outbox records;
semantic standing supplied by caller data.
Create: `EffectInstance`; `PreparedEffect`; canonical protocol encoder;
`PreparedEffectStore`; mandatory effect-claim store; generation/fencing token;
`ConsequenceKernel`; external `AuthorityClient`; `ActuationCertificate`; independent
`Actuator`; PQ signature suite registry; multi-authority verifier; CMCA budget envelope;
graph-based architecture verifier; CWE/failure falsification courts.
Preserve from OTP rather than reinvent: worker lifecycle, supervision, restart topology,
monitoring, failure propagation, process ownership, process communication.

## 33. The security theorem

Let C be arbitrary control-plane state, E a protected effect, A(E) a valid independently
issued ActuationCertificate for exact E, D(E) successful protected actuation. Then
`D(E) => A(E)` and `C does not imply A(E)`, therefore `Compromise(C)` does not imply
`D(E)`. For C3 with threshold k: `D(E) => |ValidIndependentAuthorities(E)| >= k`, so
`Compromise(C + m authorities)` does not imply `D(E)` for all `m < k`.

## 34. Consequence of the model

The objective is no longer "keep the autonomous agent under control" but "ensure that
control of autonomous computation is insufficient to obtain control of protected
consequence." Prompt injection, planner compromise, memory poisoning, peer-agent
compromise, model-provider compromise and control-plane host compromise become candidate
or orchestration corruption; none independently constitutes actuation authority.

## 35. Architectural non-equivalence

A framework SHALL NOT claim conformance because it has objects named supervisor, actor,
receipt, guardrail, authorization, sandbox, directive, capability or agent.
`OTPLooking != OTP`; `GuardedToolCall != CryptographicallyBoundConsequence`;
`AgentPermission != ExactEffectAuthority`. A framework whose intelligence-generated
directive directly triggers consequential execution is non-conformant with C1 and above
unless the directive is demoted to a powerless candidate that traverses the full pipeline.

## 36. Design criterion

`NoveltyRatio = NovelSecurityCriticalMechanisms / SatisfiedSecurityRequirements`; lower is
preferred. A mature mechanism is reused where its admitted semantics satisfy the
requirement; new software gains no standing for being simpler, newer or more convenient.

## 37. Final normative principle

Intelligence may propose. Evidence may inform. CMCA may allocate. SELECT may choose.
CONSTRUCT may manufacture. Authority may authorize. Only the independently fenced actuator
may DO. Only observation and verification may establish what happened. No preceding layer
inherits the authority of a later one; no transformation silently increases authority; no
delegation manufactures resources; no process restart implies consequence retry; no
receipt manufactures truth; no control-plane compromise manufactures an actuation
certificate.

## 38. Reference alignment (as stated by the source text; not independently verified here)

NIST SP 800-160 Vol. 1 Rev. 1 and Vol. 2 Rev. 1; FIPS 204 (ML-DSA); FIPS 205 (SLH-DSA);
NIST IR 8214C threshold-cryptography work; MITRE CWE-862/863/441/294; Erlang/OTP Design
Principles (supervision trees, links, monitors).

## 39. Implementation target

`ash_a2a` is the reference implementation: BEAM + OTP + Ash + DfCM + CMCA + SA2A + BRCE +
independent cryptographic authority + receipted evidence, with AI as an intentionally
untrusted, replaceable producer of candidate intelligence.

## See Also

- `docs/rfc/RFC-SA2A-004-v26.9.28.md` — normative consequence protocol
- `docs/rfc/RFC-SA2A-005-security-profile-v26.9.28.md` — CWE court profile and current-code status
- `docs/rfc/RFC-SA2A-006-existing-substrate-map-v26.9.28.md` — requirement to existing-tech map
- `docs/jira/v26.9.28-kernel/_LANES.md` — kernel lane map
