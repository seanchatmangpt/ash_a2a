# RFC-SA2A-001 v26.9.16

## Semantic A2A: Admitted Semantic Interoperation for Machine-to-Machine Systems

**Status:** FINAL_SPEC — closed for v26.9.24
**Version:** v26.9.16
**Category:** Protocol Architecture / Semantic Systems
**Intended audience:** Implementers of autonomous systems, enterprise agent infrastructure, semantic systems, planners, generators, authority brokers, workflow engines, and machine-to-machine protocols.

> This document uses RFC-style normative language but is not an IETF publication.

---

# Abstract

Semantic A2A defines a protocol architecture in which machines coordinate through **shared admitted semantics rather than runtime interpretation of arbitrary messages**.

Semantic A2A separates:

$$
SELECT \neq CONSTRUCT \neq DO
$$

and establishes that:

$$
Agent \neq Authority
$$

$$
Plan \neq Authority
$$

$$
Proof \neq Authority
$$

$$
Message \neq Fact
$$

$$
Received \neq Admitted
$$

$$
GeneratedCode \neq SemanticTruth
$$

The durable source of operational truth is an admitted semantic graph:

$$
O^*
$$

and lawful artifacts are manufactured from that graph:

$$
\boxed{A=\mu(O^*)}
$$

Candidate information, states, plans, rules, capabilities, policies, validators, and other artifacts MUST NOT acquire operational standing merely because an agent generated, transmitted, signed, or reasoned about them.

They acquire standing only through formal admission.

Semantic A2A combines RDF, public ontologies, ShEx, SHACL, SPARQL, N3, a bounded Datalog profile, formal planning such as FOND/HDDL, explicit authority, BRCE consequence control, receipts, replay, and projected ephemeral software into a single machine-to-machine protocol.

Its central invariant is:

$$
\boxed{\neg Standing(x)\Rightarrow\neg Consequence(x)}
$$

A conforming Semantic A2A system therefore does not attempt to make arbitrary agents trustworthy.

It makes arbitrary interpretation **non-authoritative**.

---

# 1. Normative Language

The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHALL**, **SHALL NOT**, **SHOULD**, **SHOULD NOT**, **RECOMMENDED**, **MAY**, and **OPTIONAL** are normative.

Where this RFC distinguishes between normative and informative material, normative requirements take precedence.

---

# 2. Problem Statement

Conventional agent-to-agent architectures commonly assume:

$$
Message
\rightarrow
Interpretation
\rightarrow
Reasoning
\rightarrow
Plan
\rightarrow
Action
$$

The receiver must reconstruct meaning from text, JSON, generated code, tool descriptions, private schemas, prompts, or other artifacts.

For sufficiently autonomous systems this produces five coupled problems:

1. semantic identity is reconstructed repeatedly;
2. planning depends on runtime interpretation;
3. agent capability becomes confused with authority;
4. execution may depend on open-ended reasoning;
5. knowledge discovered during one execution may not become reusable machine knowledge.

This creates **semantic individualism**: every intelligent worker may construct a private representation of reality.

At fleet scale this causes coordination to become another reasoning problem.

Semantic A2A replaces that architecture with:

$$
\boxed{
PublicSemantics
\rightarrow
Admission
\rightarrow
FormalClosure
\rightarrow
FormalPlanning
\rightarrow
SELECT
\rightarrow
CONSTRUCT
\rightarrow
Authority
\rightarrow
DO
\rightarrow
Receipt
}
$$

Natural-language interpretation and probabilistic reasoning MAY exist upstream.

They MUST NOT define operational truth downstream.

---

# 3. Design Objective

Semantic A2A optimizes for:

$$
\boxed{
\min I_{\mathrm{required}}
}
$$

subject to:

$$
\boxed{
\text{correct lawful outcome}
}
$$

where \(I_{\mathrm{required}}\) is the amount of exceptional or probabilistic intelligence required during operation.

For recurring work:

$$
\frac{\partial I_{\mathrm{required}}}
{\partial MachineExperience}
<0
$$

SHOULD hold.

A solved semantic class SHOULD progressively move through:

$$
UNKNOWN
\rightarrow
KNOWN
\rightarrow
FORMALIZED
\rightarrow
MACHINE
$$

A conforming deployment SHOULD NOT repeatedly purchase general inference for a problem class that has already acquired sufficient formal standing for deterministic execution.

---

# 4. Architectural Axioms

## 4.1 Received Is Not Admitted

A machine may receive arbitrary bytes.

Receiving those bytes MUST NOT alter canonical semantic state.

$$
Received(x)\not\Rightarrow Admitted(x)
$$

Only successful admission may produce:

$$
Standing(x)
$$

---

## 4.2 Agent Is Not Authority

An authenticated agent identity proves identity.

It does not prove permission.

$$
Authenticated(a)\not\Rightarrow Authorized(a)
$$

Likewise:

$$
Capability(a,c)\not\Rightarrow Authority(a,c)
$$

---

## 4.3 Plan Is Not Authority

A valid plan MAY describe a possible transition.

It MUST NOT authorize that transition.

$$
ValidPlan(p)\not\Rightarrow DO(p)
$$

---

## 4.4 Proof Is Not Authority

A proof that an operation is safe, consistent, optimal, or valid does not itself grant permission.

$$
Proof(x)\not\Rightarrow Authority(x)
$$

---

## 4.5 SELECT Is Not CONSTRUCT

`SELECT` chooses among already lawful possibilities.

`CONSTRUCT` manufactures an artifact from admitted semantics.

Neither operation implies consequence.

---

## 4.6 CONSTRUCT Is Not DO

A generated artifact, binary, configuration, plan, query, workflow, container, deployment manifest, or program MUST NOT change consequential external state merely because construction succeeded.

---

## 4.7 DO Is Explicit

All consequential actuation MUST traverse an explicit consequence boundary.

The reference consequence boundary is BRCE.

---

## 4.8 Zero Unreceipted Actuation

Every consequence-bearing attempt MUST have durable receipt identity established before external actuation begins.

$$
Attempted(a)
\Rightarrow
\exists r:\ PreparedReceipt(r,a)
$$

---

## 4.9 Public Semantics First

Existing public vocabularies, ontologies, standards, and semantic identities MUST be reused where they adequately describe the concept.

Private namespaces MUST be minimal.

Runtime invention of private semantic vocabulary is prohibited by the Strict profile.

---

## 4.10 Generated Code Has No Independent Semantic Authority

Generated software is a projection:

$$
C_t=\pi(O^*,G,T,E_t)
$$

where:

* \(O^*\) = admitted semantics,
* \(G\) = lawful generator,
* \(T\) = target environment,
* \(E_t\) = environment at generation time.

A projection MUST NOT become a second source of semantic truth.

---

# 5. Formal Model

Let:

$$
O
$$

denote candidate observations and representations.

Let:

$$
\alpha_B
$$

be the admission operator under boundary \(B\).

Then:

$$
\boxed{
O^*=\alpha_B(O)
}
$$

contains only information having standing.

An input rejected by admission maps to:

$$
\alpha_B(x)=\bot
$$

Lawful manufacture is:

$$
\boxed{
\mu:O^*\rightarrow A
}
$$

and therefore:

$$
\boxed{
A=\mu(O^*)
}
$$

This is the Chatman construction relation used throughout Semantic A2A.

The protocol MUST preserve the distinction between:

* candidate,
* admitted semantic object,
* selected possibility,
* constructed artifact,
* authorized intention,
* executed consequence,
* receipt,
* attestation.

---

# 6. Standing

An object has **standing** when it may participate in downstream formal reasoning or operation according to its admitted class.

Standing MUST be explicit.

A conforming implementation MUST NOT infer standing from:

* message origin;
* agent reputation;
* model confidence;
* natural-language assertions;
* successful parsing;
* a valid digital signature alone;
* syntactic correctness alone;
* passing only one validator;
* membership in an A2A Task;
* appearance in an A2A Artifact;
* successful code generation.

At minimum:

$$
Standing(x)
\Rightarrow
Identity(x)
\land
Structure(x)
\land
Semantics(x)
\land
Provenance(x)
\land
AdmissionReceipt(x)
$$

Additional standing requirements MAY apply by object class.

---

# 7. Semantic Identity

## 7.1 IRIs

Semantic subjects MUST be identified using stable IRIs wherever public semantic identity exists.

Human-readable labels MUST NOT function as canonical identity.

For example:

```text
"invoice"
"customer"
"deploy"
"account"
```

are labels, not sufficient semantic identifiers.

---

## 7.2 Public-Ontology Resolution

Before minting a new semantic term, a Semantic A2A manufacturer MUST perform the following resolution sequence:

1. search admitted public semantic sources for an exact concept;
2. reuse the existing public IRI if sufficient;
3. search for an equivalent or composable public representation;
4. express explicit mappings where multiple public models are required;
5. mint a private IRI only if the concept is genuinely absent or organization-private.

A private term MUST carry:

* provenance;
* scope;
* owning namespace;
* definition;
* mappings where relevant;
* version;
* admission receipt.

---

## 7.3 No Runtime Semantic Individualism

Under the Strict profile an agent MUST NOT invent a new vocabulary term during consequential operation and immediately use that term as operational semantics.

Novel semantic candidates MUST return to admission.

---

# 8. Relationship to A2A

Semantic A2A is designed as an extension profile over the Agent2Agent protocol rather than a replacement for its transport and task lifecycle.

The current A2A specification provides Agent Cards, Tasks, Messages, Artifacts, structured Parts, multiple protocol bindings, and declared extensions. A2A 1.0 also provides extension negotiation through Agent Card capabilities and message/artifact metadata. ([A2A Protocol][1])

Semantic A2A therefore uses A2A for:

$$
\boxed{\text{transport and interaction lifecycle}}
$$

and Semantic A2A for:

$$
\boxed{\text{meaning, admission, planning, authority and consequence}}
$$

An ordinary A2A `Task` MUST NOT be interpreted as authority to perform its requested consequence.

An A2A `Artifact` MUST NOT automatically acquire semantic standing.

An A2A `Message` MUST NOT automatically become canonical state.

---

# 9. Semantic A2A Extension Negotiation

A Semantic A2A endpoint MUST advertise Semantic A2A support through the A2A extension mechanism.

The final extension IRI MUST be stable and dereferenceable when this RFC is published to a permanent namespace.

For this draft the symbolic identifier is:

```text
SA2A-PROFILE-v26.9.16
```

An implementation MUST NOT silently treat ordinary A2A traffic as Semantic A2A traffic.

Both peers MUST explicitly negotiate a compatible Semantic A2A profile before semantic standing may cross the peer boundary.

---

# 10. Semantic Agent Card

A Semantic A2A Agent Card extends ordinary capability discovery with machine-readable semantic capability declarations.

A semantic capability MUST identify at least:

| Property               | Requirement                                 |
| ---------------------- | ------------------------------------------- |
| Capability IRI         | REQUIRED                                    |
| Input shape            | REQUIRED                                    |
| Output shape           | REQUIRED                                    |
| Preconditions          | REQUIRED for consequence-bearing capability |
| Effects                | REQUIRED for consequence-bearing capability |
| Consequence class      | REQUIRED                                    |
| Authority requirement  | REQUIRED                                    |
| Receipt class          | REQUIRED for DO                             |
| Planner compatibility  | REQUIRED when plannable                     |
| Cost/resource envelope | REQUIRED in bounded production profiles     |
| Semantic basis         | REQUIRED                                    |
| Version                | REQUIRED                                    |

A capability description is a statement of what machinery exists.

It is not a grant.

$$
Capability \neq Authority
$$

---

# 11. Semantic Envelope

Semantic A2A semantic objects MUST travel in a **Semantic Envelope**.

A Semantic Envelope contains:

```json
{
  "profile": "SA2A-PROFILE-v26.9.16",
  "kind": "CandidateGraph",
  "envelopeId": "urn:uuid:...",
  "subjects": [],
  "standing": "CANDIDATE",
  "semanticBasis": [],
  "graph": {
    "mediaType": "application/ld+json",
    "digest": "...",
    "content": {}
  },
  "provenance": {},
  "consequenceClass": "none",
  "authorityRequirement": "none",
  "bounds": {},
  "receipts": []
}
```

A2A `Part.data` MAY contain this structure.

An A2A `Part` MAY alternatively carry canonical RDF representations using an appropriate media type.

The Semantic Envelope MUST distinguish:

```text
CANDIDATE
ADMITTED
SELECTED
CONSTRUCTED
AUTHORIZED
EXECUTED
RECEIPTED
ATTESTED
REFUSED
BLOCKED
```

An upstream participant MUST NOT self-assert a stronger standing state than its receipts establish.

---

# 12. Canonical Graph Identity

Semantically equivalent RDF datasets MUST have deterministic identity where signing, hashing, replay, or comparison requires it.

Semantic A2A SHOULD use RDFC-1.0 canonicalization, a W3C Recommendation designed to produce canonical RDF dataset representations suitable for deterministic comparison and hashing. ([W3C][2])

A canonical semantic artifact SHOULD therefore carry:

$$
Digest=
H(Canonicalize(G))
$$

The digest MUST identify the exact graph admitted by the corresponding receipt.

---

# 13. Semantic Admission Pipeline

Admission is not a single validator.

It is a pipeline.

The reference pipeline is:

$$
Candidate
\rightarrow
Parse
\rightarrow
Identity
\rightarrow
ShEx
\rightarrow
SHACL
\rightarrow
RuleClosure
\rightarrow
SPARQLFalsifiers
\rightarrow
Provenance
\rightarrow
ProfileChecks
\rightarrow
ADMITTED
$$

Failure at any REQUIRED stage MUST prevent standing.

$$
Failure_i(x)
\Rightarrow
\neg Admitted(x)
$$

Canonical state MUST remain unchanged when admission fails.

---

# 14. ShEx Layer

ShEx defines structural membership.

The W3C Shape Expressions community describes ShEx as a grammar for RDF graph structure usable for description, validation, parsing, and transformation. ([W3C][3])

Semantic A2A uses ShEx primarily to answer:

$$
\boxed{\text{Is this object structurally a member of this semantic language?}}
$$

Typical ShEx constraints include:

* required predicates;
* cardinalities;
* datatypes;
* permissible node forms;
* nested structural relationships.

A structurally invalid object MUST NOT proceed to semantic admission.

---

# 15. SHACL Layer

SHACL defines semantic and graph invariants.

SHACL is an RDF-native constraint language in which shapes formally constrain RDF nodes and edges; current SHACL development also explicitly covers inferencing and generation use cases. ([W3C][4])

Semantic A2A uses SHACL to answer:

$$
\boxed{\text{May an object having this structure have standing in this domain?}}
$$

Examples include:

$$
Consequence(a)
\Rightarrow
AuthorityRequirement(a)
$$

$$
DO(a)
\Rightarrow
ReceiptRequirement(a)
$$

$$
Plan(p)
\Rightarrow
KnownCapability(action_i)
$$

$$
PrivateSemanticTerm(x)
\Rightarrow
PrivateNamespaceAdmission(x)
$$

Conformance-critical violations MUST fail closed.

Warnings MUST NOT override a failing MUST-level invariant.

---

# 16. Datalog Layer

Semantic A2A defines a **Safe Finite Datalog Profile** for deterministic recursive inference.

The Core Datalog Profile MUST be:

* function-free;
* range-restricted;
* finite-domain;
* side-effect free;
* free of runtime network access;
* deterministic;
* terminating by finite least-fixpoint closure.

Core Datalog MUST NOT invent unbounded new terms.

Given fact set \(F_0\) and program \(P\):

$$
F_{n+1}=T_P(F_n)
$$

until:

$$
F_{n+1}=F_n
$$

The resulting closure is:

$$
Closure_P(F_0)
$$

This layer converts classes of repeated “reasoning” into finite logical closure.

---

# 17. N3 Layer

N3 MAY be used for explicit graph implication, quoted graphs, proof-oriented transformations, and graph-to-graph rules.

The W3C N3 Community Group defines N3 as an assertion and logic language extending RDF with logical implications, graph terms, variables, and related rule machinery. ([W3C][5])

Under Semantic A2A:

* N3 rules MUST themselves have standing;
* external network access from an N3 rule MUST NOT silently alter admitted state;
* side-effecting built-ins MUST NOT constitute DO;
* non-admitted rule output is candidate output;
* rule execution MUST NOT grant authority.

N3 therefore remains:

$$
\boxed{\text{semantic derivation}}
$$

not:

$$
\boxed{\text{consequence execution}}
$$

---

# 18. SPARQL Layer

SPARQL provides exact graph interrogation and projection.

Current SPARQL 1.2 work continues to define RDF query, protocol, update, and related semantics; SPARQL queries can return result sets or constructed RDF graphs. ([W3C][6])

Semantic A2A assigns four principal roles:

### 18.1 Observation

SPARQL `SELECT` queries MAY inspect admitted state.

This is distinct from the Semantic A2A `SELECT` architectural phase.

### 18.2 Falsification

SPARQL `ASK` queries SHOULD encode graph-global falsifiers.

For example:

```sparql
ASK {
  ?action a :ConsequenceBearingAction .
  FILTER NOT EXISTS { ?action :requiresAuthority ?authority . }
}
```

A true result from a mandatory falsifier MUST block admission.

### 18.3 Projection

SPARQL `CONSTRUCT` MAY create candidate projections from admitted semantics.

A projection does not automatically acquire standing.

### 18.4 Update

Direct SPARQL Update against canonical admitted state is prohibited by the Strict profile.

SPARQL Update MAY modify staging graphs.

Any mutation intended for canonical consequential state MUST traverse the normal admission and consequence path.

---

# 19. Combined Semantic Admission

The accepted semantic universe is the intersection of all required predicates:

$$
\boxed{
O^*
=
G_{\text{identity}}
\cap
G_{\text{ShEx}}
\cap
G_{\text{SHACL}}
\cap
G_{\text{closure}}
\cap
G_{\text{falsifiers}}
\cap
G_{\text{provenance}}
\cap
G_{\text{profile}}
}
$$

Accordingly:

$$
BadState(x)\Rightarrow x\notin O^*
$$

$$
BadPlan(p)\Rightarrow p\notin O^*
$$

A candidate may physically arrive at the boundary.

It cannot become canonical semantic state without admission.

---

# 20. Meta-Admission: Blocking Unrigor

Semantic A2A applies admission recursively to the machinery defining admission.

The following are semantic artifacts:

* ShEx schemas;
* SHACL shapes;
* N3 rules;
* Datalog programs;
* SPARQL falsifiers;
* planning domains;
* generators;
* authority policies;
* receipt schemas;
* semantic mappings.

They MUST NOT acquire authority merely because they are configuration files.

A validator without standing cannot validate.

$$
\neg Standing(v)
\Rightarrow
\neg Validates(v,x)
$$

A rule without standing cannot derive canonical facts.

$$
\neg Standing(r)
\Rightarrow
\neg CanonicalDerivation(r)
$$

A planner domain without standing cannot supply production plans.

A generator without standing cannot manufacture production artifacts.

This gives:

$$
\boxed{
\text{unrigorous machinery itself is inadmissible}
}
$$

---

# 21. Root Manifest

Meta-admission MUST terminate at a deliberately small trust root.

The Strict profile defines a **Root Manifest** containing at minimum:

* admitted ontology roots;
* semantic profile versions;
* canonicalization algorithm;
* manufacturer identities;
* admitted validator/compiler identities;
* Authority Broker identity;
* BRCE contract;
* receipt law;
* cryptographic algorithms;
* version policy.

The Root Manifest MUST be content-addressed.

Changing the Root Manifest MUST be treated as a high-consequence transition.

No ordinary agent MAY mutate it.

---

# 22. Correct-by-Construction Closure

Assume canonical state:

$$
O^*_0
$$

satisfies invariant set \(I\).

Assume every admitted transition \(T\) satisfies:

$$
I(O^*_t)
\land
Admitted(T)
\Rightarrow
I(T(O^*_t))
$$

Then:

$$
\boxed{
\forall t,\ I(O^*_t)
}
$$

This is the core Semantic A2A state-closure property.

The operational objective is therefore not:

> detect arbitrary bad states after ingestion.

It is:

$$
\boxed{
\text{no inadmissible transition exists by which they gain standing}
}
$$

---

# 23. Planning

Semantic A2A separates semantic truth from planning.

A planning projection MAY be manufactured from \(O^*\):

$$
P=\pi_{\mathrm{plan}}(O^*)
$$

A conforming planner MUST operate only over admitted planning objects.

FOND and HDDL are RECOMMENDED representations for nondeterministic and hierarchical planning respectively.

The semantic graph remains authoritative.

The planning projection is derived.

---

# 24. Plan Package

A production plan package MUST identify:

* semantic goal;
* initial admitted state identity;
* planning-domain identity;
* method/action identities;
* preconditions;
* effects;
* nondeterministic outcomes where applicable;
* consequence class;
* required capabilities;
* maximum fan-out;
* maximum depth;
* maximum parallelism;
* resource envelope;
* authority requirements;
* receipt obligations;
* planner identity;
* plan digest.

A plan missing required production bounds MUST be rejected by the Strict profile.

---

# 25. SELECT

`SELECT` chooses among lawful possibilities represented in the admitted planning universe.

A SELECT component MAY be:

* deterministic planner;
* optimizer;
* scheduler;
* policy;
* FOND planner;
* HDDL planner;
* SAT/SMT/CP solver;
* other formally bounded selector.

SELECT MUST NOT itself perform consequential external mutation.

$$
SELECT(p)\not\Rightarrow DO(p)
$$

---

# 26. CONSTRUCT

`CONSTRUCT` manufactures an artifact from admitted semantics.

Examples:

* executable code;
* BEAM modules;
* Rust code;
* SQL;
* Kubernetes resources;
* deployment manifests;
* configuration;
* workflow definitions;
* messages;
* queries;
* proofs;
* protocol adapters.

The construction law is:

$$
\boxed{
A=\mu(O^*)
}
$$

A constructor MUST identify:

* admitted inputs;
* manufacturer identity;
* manufacturer version;
* target profile;
* produced artifact digest;
* construction receipt.

Manual edits to a projection MUST NOT become canonical semantic change.

---

# 27. Projected Ephemeral Software

The Strict profile treats executable software as disposable projection.

$$
O^*
\rightarrow
G
\rightarrow
C_t
\rightarrow
Verify
\rightarrow
Run
\rightarrow
Discard
$$

The durable system consists primarily of:

$$
\boxed{
Ontology
+
Rules
+
Shapes
+
Plans
+
Manufacturers
+
Receipts
}
$$

rather than independently maintained projections.

A projection MAY be retained for evidence, caching, performance, or audit.

Retention MUST NOT convert it into semantic authority.

If a projected artifact is incorrect, correction MUST occur in:

$$
O^*
$$

or:

$$
\mu
$$

rather than by establishing an independent hand-maintained truth in the projection.

---

# 28. Authority

Authority is an explicit admitted relation.

An Authority Broker evaluates whether a specific actor may perform a specific consequence under a specific context.

Authority MUST be:

* scoped;
* explicit;
* bounded;
* attributable;
* revocable where the domain permits;
* receipted.

Generic public policy vocabularies SHOULD be reused where adequate. ODRL, for example, provides standardized concepts for permissions, prohibitions, duties, parties, assets, and constraints. ([W3C][7])

A Semantic A2A implementation MAY extend such vocabularies for domain-specific consequence authority.

---

# 29. Authority Non-Implications

The following MUST hold:

$$
Identity\not\Rightarrow Authority
$$

$$
Authentication\not\Rightarrow Authority
$$

$$
Capability\not\Rightarrow Authority
$$

$$
TaskAssignment\not\Rightarrow Authority
$$

$$
PlanValidity\not\Rightarrow Authority
$$

$$
Proof\not\Rightarrow Authority
$$

$$
ModelConfidence\not\Rightarrow Authority
$$

$$
AgentCardDeclaration\not\Rightarrow Authority
$$

---

# 30. BRCE

BRCE is the reference consequence-bearing execution boundary.

No Semantic A2A peer may bypass BRCE merely because it has:

* generated a valid plan;
* generated valid code;
* passed SHACL;
* authenticated successfully;
* completed an A2A Task;
* received a message from a trusted peer.

The consequence path is:

$$
SELECT
\rightarrow
CONSTRUCT
\rightarrow
AuthorityBroker
\rightarrow
BRCE
\rightarrow
DO
$$

---

# 31. Zero Unreceipted Actuation

Before a consequence-bearing effect is attempted, BRCE MUST establish a durable prepared receipt containing:

* actuation identifier;
* idempotency identifier;
* actor;
* authority grant;
* semantic subject;
* intended effect;
* input digest;
* plan digest where applicable;
* projection digest where applicable;
* timestamp/logical clock;
* reconciliation metadata.

Only after durable preparation MAY execution begin.

After execution, the receipt MUST transition to a terminal status such as:

```text
EXECUTED
REFUSED
FAILED
RECONCILED
COMPENSATED
UNKNOWN_OUTCOME
```

A crash MUST NOT erase evidence that an attempt was authorized and prepared.

---

# 32. Replay

A receipt MUST contain sufficient deterministic identity to reconstruct the semantic basis of an execution.

Replay MAY reproduce:

* semantic admission;
* plan selection;
* construction;
* authorization decision;
* intended effect.

Replay MUST NOT automatically repeat external consequence.

Replaying evidence is not authority to re-actuate.

---

# 33. Attestation

An attestation asserts evidence about what occurred.

An attestation MUST identify:

* exact semantic revision;
* exact plan revision where applicable;
* exact manufacturer revision;
* exact projected artifact digest;
* exact authority decision;
* exact receipt set;
* observed post-state.

An attestation MUST NOT claim evidence beyond what was observed.

In particular:

```text
local verification ≠ hosted CI
hosted CI ≠ deployment
deployment ≠ runtime observation
runtime observation ≠ publication
publication ≠ merge
```

Evidence classes MUST remain separate.

---

# 34. Bounded Fan-Out

Production Semantic A2A plans MUST have explicit concurrency and fan-out bounds.

At minimum:

$$
FanOut\leq F_{\max}
$$

$$
Depth\leq D_{\max}
$$

$$
Parallelism\leq P_{\max}
$$

where the relevant values are admitted properties of the plan or execution profile.

A subtask MUST inherit or receive an explicitly delegated resource and authority envelope.

Delegation MUST NOT manufacture additional authority.

---

# 35. Resource Bounds

Known production work MUST declare a finite resource envelope wherever resource use is under protocol control.

Examples include:

* execution count;
* fan-out;
* concurrency;
* memory;
* runtime;
* retries;
* external requests;
* financial expenditure.

Exhaustion of the envelope MUST fail closed.

A production system MUST NOT silently convert resource exhaustion into permission for open-ended LLM reasoning.

---

# 36. UNKNOWN

Semantic A2A explicitly represents epistemic incompleteness.

If the admitted machinery cannot classify, plan, or construct a lawful solution, the state MAY become:

```text
UNKNOWN
```

UNKNOWN is not failure.

UNKNOWN means:

$$
\boxed{\text{existing admitted machinery is insufficient}}
$$

UNKNOWN MUST NOT silently become DO.

---

# 37. UNKNOWN Resolution

UNKNOWN work MAY be sent to:

* an LLM;
* a human;
* a theorem prover;
* a search process;
* a synthesis process;
* an experiment;
* another bounded discovery mechanism.

The result MUST return as:

$$
\boxed{\text{candidate}}
$$

not as canonical truth.

Thus:

$$
UNKNOWN
\xrightarrow{Intelligence}
Candidate
\xrightarrow{Admission}
KNOWN
$$

Only admission performs:

$$
Candidate\rightarrow O^*
$$

---

# 38. CMCA Allocation Boundary

Semantic A2A SHOULD place an explicit resource allocator before expensive UNKNOWN resolution.

CMCA — Chatman Multifractal Cascade Allocation — is the reference allocation strategy.

CMCA operates over the admitted candidate frontier:

$$
\mathcal F_t
\xrightarrow{CMCA}
\mathcal B_t
$$

where \(\mathcal B_t\) is the bounded subset receiving scarce resources.

Resources may include:

* model inference;
* compute;
* experimentation;
* search;
* verification;
* external services;
* authority review.

A model MUST NOT grant itself additional budget merely because its previous allocation was insufficient.

---

# 39. Machine Experience

A successfully resolved UNKNOWN SHOULD produce reusable machine experience.

The preferred lifecycle is:

$$
UNKNOWN
\rightarrow
CandidateKnowledge
\rightarrow
Admission
\rightarrow
O^*
\rightarrow
Rule/Shape/Plan/Generator
$$

Future observations of the same semantic class SHOULD route to that machinery rather than repeat the original discovery process.

Thus:

$$
Allocation_{LLM}(class,t+1)
\le
Allocation_{LLM}(class,t)
$$

with the desired stable state:

$$
Allocation_{LLM}(KNOWN)=0
$$

where deterministic machinery is sufficient.

---

# 40. LLM Boundary

An LLM MAY:

* interpret unstructured observations;
* propose ontology mappings;
* propose new rules;
* propose shapes;
* propose plans;
* propose code;
* identify candidate public prior art;
* investigate UNKNOWN states.

An LLM MUST NOT, solely by model output:

* admit facts;
* create canonical semantic identity;
* grant authority;
* alter canonical state;
* promote its own rule;
* modify a Root Manifest;
* execute consequential DO in the Strict profile.

The fundamental relation is:

$$
\boxed{
LLMOutput\Rightarrow Candidate
}
$$

never:

$$
LLMOutput\Rightarrow Standing
$$

---

# 41. Semantic A2A State Machine

The full reference lifecycle is:

```text
RECEIVED
  ↓
PARSED
  ↓
IDENTIFIED
  ↓
STRUCTURALLY_VALID
  ↓
SEMANTICALLY_VALID
  ↓
CLOSED
  ↓
FALSIFIER_CLEAN
  ↓
ADMITTED
  ↓
PLANNABLE
  ↓
SELECTED
  ↓
CONSTRUCTED
  ↓
AUTHORIZED
  ↓
PREPARED
  ↓
EXECUTED
  ↓
RECEIPTED
  ↓
ATTESTED
```

Any stage MAY instead terminate as:

```text
REFUSED
BLOCKED
UNKNOWN
UNSUPPORTED
FAILED
```

No transition may skip a REQUIRED predecessor.

---

# 42. Refusal Classes

A conforming implementation SHOULD expose machine-readable refusal causes.

Recommended classes include:

```text
REFUSED_IDENTITY
REFUSED_NAMESPACE
REFUSED_STRUCTURE
REFUSED_SHACL
REFUSED_RULE
REFUSED_FALSIFIER
REFUSED_PROVENANCE
REFUSED_PROFILE
REFUSED_PLAN
REFUSED_CAPABILITY
REFUSED_AUTHORITY
REFUSED_CONSEQUENCE
REFUSED_RECEIPT
REFUSED_BOUNDS
REFUSED_META_RIGOR
BLOCKED_UNKNOWN
BLOCKED_RESOURCE
UNSUPPORTED_PROFILE
```

A refusal is an expected lawful outcome.

It is not necessarily a system error.

---

# 43. Semantic Error Handling

Semantic A2A MUST fail closed.

If an implementation cannot determine whether an input satisfies a REQUIRED predicate, the result MUST NOT be `ADMITTED`.

Formally:

$$
Unknown(Valid(x))
\Rightarrow
\neg Admitted(x)
$$

An inability to validate MUST NOT be interpreted as validation success.

---

# 44. Semantic Transaction Rule

Canonical semantic state MUST change only through admitted transitions.

Let:

$$
O^*_t
$$

be canonical state before a candidate transition \(T\).

Then:

$$
O^*_{t+1}
=
\begin{cases}
T(O^*_t), & Admitted(T)\land Authorized(T)\land ConsequenceLaw(T)\\
O^*_t, & otherwise
\end{cases}
$$

Receiving a candidate alone leaves:

$$
O^*_{t+1}=O^*_t
$$

---

# 45. Semantic Immutability and Versioning

Admitted artifacts SHOULD be immutable by semantic identity.

A change SHOULD create a new version or revision identity.

Semantic A2A uses CalVer for this RFC:

```text
vYY.M.DD
```

Compatibility MUST be declared separately from version numbering.

A newer version MUST NOT be assumed compatible merely because its CalVer is greater.

---

# 46. Ontology Import Discipline

Ontology imports MUST be explicit.

Production admission MUST NOT dereference arbitrary mutable web resources in a way that changes semantics nondeterministically during execution.

Imported semantic resources SHOULD be:

* version-pinned;
* content-addressed where possible;
* canonicalized;
* admitted;
* locally cacheable.

A new upstream ontology revision MUST enter as a new candidate semantic revision.

---

# 47. No Silent Semantic Drift

Two peers claiming the same semantic capability MUST either reference the same semantic identity or an explicitly admitted mapping.

Textual similarity is insufficient.

$$
label_A = label_B
\not\Rightarrow
meaning_A = meaning_B
$$

Semantic equivalence requires explicit standing.

---

# 48. Capability Composition

Capabilities MAY compose when their semantic contracts compose.

For capabilities \(c_1,c_2\):

$$
Effects(c_1)
\models
Preconditions(c_2)
$$

is required for direct semantic composition.

Authority requirements remain independent.

The ability to compose two capabilities MUST NOT increase either participant's authority ceiling.

---

# 49. A2A Task Semantics

An A2A Task is a coordination container.

Semantic A2A MUST distinguish:

$$
Task
$$

from:

$$
Plan
$$

and:

$$
Authority
$$

A Task MAY contain or reference a semantic goal.

The Task itself MUST NOT function as proof that:

* the goal is valid;
* the plan is admissible;
* the requesting party has authority;
* execution succeeded.

---

# 50. Artifact Semantics

An A2A Artifact may carry:

* candidate semantic graphs;
* admission receipts;
* formal plans;
* generated projections;
* proofs;
* execution receipts;
* attestations.

Its A2A Artifact status alone provides no Semantic A2A standing.

Standing is established by Semantic A2A receipts.

---

# 51. Transport Independence

Semantic A2A semantics MUST remain invariant across supported A2A bindings.

The same admitted semantic envelope transported over different bindings MUST produce equivalent semantic interpretation.

Transport-specific metadata MUST NOT silently alter semantic meaning.

---

# 52. Provenance

Semantic artifacts MUST identify provenance sufficient to answer:

```text
What is this?
Where did it come from?
Which semantic source generated it?
Which manufacturer produced it?
Which revision was used?
Which admission process accepted it?
```

Public provenance vocabularies SHOULD be reused where adequate.

Provenance itself does not grant authority.

---

# 53. Security Model

Semantic A2A security is based primarily on reducing the consequential language accepted by the system.

The accepted set is progressively contracted:

$$
\mathcal C
\supseteq
\mathcal C_{identity}
\supseteq
\mathcal C_{structure}
\supseteq
\mathcal C_{semantic}
\supseteq
\mathcal C_{closure}
\supseteq
\mathcal C_{plan}
\supseteq
\mathcal C_{authority}
\supseteq
DO
$$

Security therefore does not depend on an agent correctly recognizing every dangerous possibility.

Objects outside the admitted language have no standing.

---

# 54. Confused Deputy Prevention

A peer MUST NOT use its own authority merely because another peer requested an operation.

The requesting agent's message identifies intent.

The Authority Broker determines lawful permission.

Delegation MUST be explicit and bounded.

---

# 55. Replay Protection

Consequence-bearing requests MUST include stable actuation and idempotency identities.

BRCE MUST detect previously prepared or executed identities before repeating an effect.

Where an external system supports idempotency tokens, the Semantic A2A actuation identity SHOULD bind to the external token.

---

# 56. Rule Safety

Rules participating in canonical closure MUST be within the declared rule profile.

The Strict profile prohibits:

* arbitrary network access;
* unbounded term creation;
* direct external side effects;
* implicit authority derivation;
* self-modification of the admitted rule set.

A rule may produce candidates.

It may not bypass admission.

---

# 57. Bad-State Exclusion

The central ingestion invariant is:

$$
\boxed{
\neg Valid(x)\Rightarrow\neg Standing(x)
}
$$

Therefore a malformed or inadmissible:

* state;
* plan;
* rule;
* shape;
* capability;
* policy;
* authority claim;
* receipt;
* projection;
* semantic mapping

does not become “bad state inside the operational world.”

It remains outside \(O^*\).

---

# 58. Meta-Rigor Exclusion

The stronger invariant is:

$$
\boxed{
\neg Rigorous(m)\Rightarrow\neg Standing(m)
}
$$

for semantic machinery \(m\).

Therefore:

$$
BadValidator\notin O^*
$$

$$
BadRule\notin O^*
$$

$$
BadPlannerDomain\notin O^*
$$

$$
BadManufacturer\notin O^*
$$

The system blocks not only invalid state, but machinery lacking standing to determine validity.

---

# 59. Conformance Profiles

## 59.1 SA2A-CORE

Requires:

* semantic identity;
* RDF representation;
* canonical graph identity;
* public-semantics-first policy;
* ShEx structural admission;
* SHACL admission;
* SPARQL falsifiers;
* provenance;
* admission receipts;
* fail-closed semantics.

No DO capability is required.

---

## 59.2 SA2A-LOGIC

Adds:

* Safe Finite Datalog;
* admitted N3 rules;
* deterministic closure;
* rule provenance.

---

## 59.3 SA2A-PLAN

Adds:

* formal planning projection;
* FOND and/or HDDL;
* capability preconditions/effects;
* bounded fan-out;
* bounded resource envelope;
* plan admission.

---

## 59.4 SA2A-DO

Adds:

* explicit Authority Broker;
* BRCE;
* prepared receipts;
* execution receipts;
* reconciliation;
* replay evidence.

---

## 59.5 SA2A-STRICT

Requires all prior profiles plus:

* no runtime semantic invention;
* meta-admission;
* admitted Root Manifest;
* projected ephemeral software;
* no direct mutation of canonical graph outside consequence law;
* no LLM authority;
* no LLM on the production DO path;
* no unbounded production planning loop;
* explicit finite resource bounds for known work.

---

# 60. Conformance Invariants

A Strict implementation MUST satisfy at least:

$$
Executed(a)\Rightarrow Authorized(a)
$$

$$
Executed(a)\Rightarrow PreparedReceipt(a)
$$

$$
Authorized(a)\Rightarrow Admitted(a)
$$

$$
Selected(p)\Rightarrow AdmittedPlan(p)
$$

$$
Constructed(c)\Rightarrow AdmittedSource(c)
$$

$$
Canonical(x)\Rightarrow Admitted(x)
$$

$$
Derived(x,r)\land Canonical(x)
\Rightarrow Standing(r)
$$

$$
Validated(x,v)\land Admitted(x)
\Rightarrow Standing(v)
$$

$$
PrivateTerm(x)\land Strict
\Rightarrow AdmittedNamespace(x)
$$

$$
LLMOutput(x)\Rightarrow Candidate(x)
$$

$$
Projection(x)\not\Rightarrow SemanticAuthority(x)
$$

$$
Message(x)\not\Rightarrow Fact(x)
$$

$$
Task(x)\not\Rightarrow Authority(x)
$$

---

# 61. Minimum Falsifier Suite

A Strict deployment MUST test at least for:

```text
consequence without authority requirement
DO without prepared-receipt requirement
unknown capability referenced by plan
unadmitted ontology term
unadmitted rule
unadmitted validator
plan exceeding fan-out bound
plan exceeding resource envelope
semantic artifact lacking provenance
semantic artifact lacking canonical identity
projection attempting to become canonical source
authority derived from agent identity alone
LLM output marked directly as ADMITTED
canonical mutation outside BRCE
```

Any positive result MUST fail closed.

---

# 62. Reference Admission Algorithm

Conceptually:

```text
admit(candidate):
    parsed = parse(candidate)
    require parsed

    canonical = canonicalize(parsed)
    require identity_policy(canonical)

    require shex_validate(canonical)
    require shacl_validate(canonical)

    closure = datalog_close(canonical)
    closure = n3_derive(closure)

    require all_required_falsifiers_false(closure)
    require provenance_valid(closure)
    require profile_valid(closure)
    require meta_sources_have_standing(closure)

    receipt = issue_admission_receipt(closure)

    return ADMITTED(closure, receipt)
```

Every `require` is fail-closed.

No failed candidate mutates canonical state.

---

# 63. Reference DO Algorithm

Conceptually:

```text
do(intent):
    require standing(intent)
    require admitted_plan(intent.plan)
    require admitted_projection(intent.artifact)

    grant = authority_broker.evaluate(intent)
    require grant.authorized

    prepared = receipt_outbox.prepare(intent, grant)
    require durable(prepared)

    result = actuator.execute(intent)

    receipt = receipt_outbox.finalize(prepared, result)

    return receipt
```

No execution occurs before durable preparation.

---

# 64. UNKNOWN Algorithm

Conceptually:

```text
resolve_unknown(x):
    require standing_of_observation(x)

    allocation = allocator.allocate(x)

    if allocation.refused:
        return BLOCKED_RESOURCE

    candidate = discovery_engine.run(x, allocation)

    return admit(candidate)
```

A discovery engine does not self-admit.

---

# 65. Machine-Experience Compilation

After admission of a successful UNKNOWN resolution:

```text
resolved candidate
    ↓
canonical ontology/rule/shape
    ↓
planning projection
    ↓
manufacturer
    ↓
qualification
    ↓
future deterministic route
```

The architecture SHOULD attempt to ensure the same semantic class no longer requires equivalent exploratory inference.

---

# 66. Deterministic Coordination

When two Semantic A2A participants share:

* semantic identity;
* capability semantics;
* state semantics;
* planning vocabulary;
* authority vocabulary;
* receipt vocabulary;

coordination becomes protocol operation rather than natural-language negotiation.

The desired condition is:

$$
URI_A=URI_B
$$

or:

$$
Mapping(URI_A,URI_B)\in O^*
$$

not:

$$
LLM_A\approx Meaning_B
$$

---

# 67. Information Partitions

A peer MAY possess private information.

Semantic A2A does not require every peer to share all internal state.

It requires that information crossing a semantic boundary acquire explicit identity and standing appropriate to the receiving domain.

Private information does not imply private semantics.

---

# 68. Privacy and Disclosure

A semantic message SHOULD disclose only the graph required for the authorized interaction.

Named graphs, graph projections, capability-specific shapes, and information partitions SHOULD be used to minimize unnecessary disclosure.

Admission MUST NOT imply permission to redistribute received information.

---

# 69. Observability

All consequential state transitions SHOULD produce machine-readable evidence.

Operational observability SHOULD be expressed in terms such as:

```text
OBSERVED
ADMITTED
SELECTED
CONSTRUCTED
AUTHORIZED
EXECUTED
CHANGED
VERIFIED
REFUSED
BLOCKED
UNSUPPORTED
```

Observation MUST remain distinguishable from inference.

---

# 70. Evidence Boundaries

A Semantic A2A implementation MUST NOT promote evidence across boundaries without new evidence.

For example:

$$
LocalTest\not\Rightarrow HostedCI
$$

$$
HostedCI\not\Rightarrow Production
$$

$$
ProductionBuild\not\Rightarrow RuntimeAlive
$$

$$
RuntimeAlive\not\Rightarrow Publication
$$

$$
Publication\not\Rightarrow Merge
$$

Receipts SHOULD encode the exact evidence class.

---

# 71. Economic Resource Semantics

Semantic A2A treats model inference as a resource rather than an intrinsic property of an agent.

Known work SHOULD use the least costly lawful machinery capable of satisfying the admitted contract.

Conceptually:

$$
reuse
\rightarrow
compose
\rightarrow
extend
\rightarrow
invent
$$

General model inference belongs principally at the unresolved boundary.

---

# 72. Bounded Production Principle

A production operation MUST NOT require the system to solve an unrestricted question of the form:

> Continue reasoning until you believe the task is complete.

Known production work SHOULD instead reduce to a bounded formal contract.

This ensures that resource bounds belong to the constructed process rather than to an arbitrary search loop.

---

# 73. No Agent Blank Check

The Strict profile MUST NOT grant an agent an implicit right to recursively increase its own inference or execution budget.

A resource extension is a new allocation decision.

$$
NeedMoreResources
\not\Rightarrow
GrantMoreResources
$$

This rule applies independently of whether the requested resource is:

* tokens;
* compute;
* money;
* calls;
* agents;
* tools;
* authority.

---

# 74. Semantic A2A and General Agents

Semantic A2A does not prohibit general intelligence.

It removes general intelligence from the role of production control authority.

A highly capable model MAY exist upstream.

The consequential dependency remains:

$$
\boxed{
Intelligence
\rightarrow
Candidate
\rightarrow
Admission
}
$$

not:

$$
\boxed{
Intelligence
\rightarrow
DO
}
$$

Accordingly:

$$
\frac{\partial Authority}
{\partial Intelligence}
=0
$$

by architectural construction.

---

# 75. Interoperability With Non-Semantic A2A

A Semantic A2A peer MAY communicate with an ordinary A2A peer.

Traffic from a non-Semantic peer MUST enter as candidate information.

It MUST NOT inherit Semantic A2A standing.

A bridge MAY transform ordinary A2A messages into candidate RDF graphs.

The bridge MUST NOT manufacture semantic authority.

---

# 76. Downgrade Prevention

A Semantic A2A peer operating in Strict mode MUST NOT silently downgrade to ordinary A2A semantics for a consequence-bearing task.

If the counterparty does not support the required profile, the result MUST be:

```text
UNSUPPORTED_PROFILE
```

or an equivalent refusal.

---

# 77. Test Vectors

Every conforming implementation SHOULD ship deterministic tests covering at least:

### Valid admission

A correctly identified, structurally valid, semantically valid graph acquires standing and an admission receipt.

### Invalid structure

A graph failing ShEx remains candidate-only.

### Invalid invariant

A graph passing ShEx but failing SHACL is refused.

### Global falsifier

A graph locally valid but containing a prohibited graph-global condition is refused.

### Invalid plan

A plan referencing an unknown capability is refused.

### Missing authority

A perfectly valid plan without sufficient authority cannot DO.

### Missing receipt preparation

An implementation attempting DO without durable preparation fails closed.

### Hallucinated term

A model-generated unknown predicate cannot enter Strict canonical state.

### Invalid validator

A SHACL shape lacking standing cannot participate in canonical admission.

### Projection mutation

A manually changed generated artifact does not alter \(O^*\).

### UNKNOWN conversion

A discovery result enters as candidate and is not routable as KNOWN until admission succeeds.

### Bounded fan-out

A plan requesting more fan-out than its admitted envelope is refused.

---

# 78. Required Properties of a Semantic A2A Implementation

A complete implementation MUST be capable of answering mechanically:

```text
What does this semantic object mean?
Which public identities does it use?
Why does it have standing?
Which rules derived it?
Which validators admitted it?
Which semantic revision generated it?
Which plan selected it?
Which manufacturer constructed it?
Who had authority?
Which consequence occurred?
Where is the receipt?
Can the evidence be replayed?
```

If any REQUIRED question cannot be answered, standing MUST NOT be inferred.

---

# 79. Standard Technology Baseline

Semantic A2A deliberately composes existing public semantic machinery rather than inventing replacements.

The current standards landscape includes:

* RDF 1.2 as the current W3C RDF evolution, with RDF 1.2 Concepts and Semantics reaching Candidate Recommendation Snapshot in April 2026; ([W3C][8])
* RDFC-1.0 as a W3C Recommendation for deterministic RDF dataset canonicalization; ([W3C][2])
* SHACL as the RDF-native constraint system, with SHACL 1.2 under active W3C development in 2026; ([W3C][4])
* SPARQL 1.2 as the current W3C query/protocol evolution, presently on the Recommendation track; ([W3C][6])
* ShEx as an RDF graph grammar maintained through the W3C Shape Expressions Community Group; ([W3C][3])
* N3 as a community-developed RDF assertion and logic language; ([W3C][5])
* ODRL as a W3C Recommendation for machine-readable permissions, prohibitions, duties, and constraints. ([W3C][7])

Semantic A2A defines profiles around these technologies rather than requiring every implementation to depend on unstable draft-only features.

---

# 80. Semantic A2A Doctrine

The complete doctrine can be summarized as:

$$
\boxed{
Message\neq Meaning
}
$$

$$
\boxed{
Candidate\neq Fact
}
$$

$$
\boxed{
Fact\neq Authority
}
$$

$$
\boxed{
Plan\neq Authority
}
$$

$$
\boxed{
Proof\neq Authority
}
$$

$$
\boxed{
SELECT\neq CONSTRUCT\neq DO
}
$$

$$
\boxed{
Received\neq Admitted
}
$$

$$
\boxed{
GeneratedCode\neq SemanticTruth
}
$$

$$
\boxed{
Intelligence\neq Authority
}
$$

and:

$$
\boxed{
\neg Standing(x)
\Rightarrow
\neg Consequence(x)
}
$$

---

# 81. Reference Architecture

The complete Strict architecture is:

$$
\boxed{
\begin{aligned}
&\text{Public Ontologies}\\
&\downarrow\\
&\text{Canonical RDF }O^*\\
&\downarrow\\
&\text{ShEx + SHACL}\\
&\downarrow\\
&\text{N3 + Safe Datalog Closure}\\
&\downarrow\\
&\text{SPARQL Falsifiers / Projections}\\
&\downarrow\\
&\text{FOND/HDDL}\\
&\downarrow\\
&SELECT\\
&\downarrow\\
&CONSTRUCT\\
&\downarrow\\
&\text{Projected Ephemeral Artifact}\\
&\downarrow\\
&\text{Authority Broker}\\
&\downarrow\\
&BRCE\\
&\downarrow\\
&DO\\
&\downarrow\\
&\text{Receipt / Replay / Attestation}
\end{aligned}
}
$$

UNKNOWN branches before admission:

$$
UNKNOWN
\xrightarrow{CMCA}
\text{bounded intelligence}
\rightarrow
Candidate
\rightarrow
Admission
$$

It does not bypass the architecture.

---

# 82. Consequence of the Architecture

A Semantic A2A system does not ask every autonomous participant to understand every other participant.

It establishes a common admitted semantic substrate.

It does not attempt to make hallucination impossible.

It makes hallucination unable to acquire standing without admission.

It does not attempt to make arbitrary generated plans safe.

It prevents inadmissible plans from entering the production planning universe.

It does not attempt to make generated code the source of truth.

It makes code a disposable projection of admitted truth.

It does not attempt to make agents financially or operationally omnipotent.

It bounds resources and authority outside the agent.

It does not require increasingly intelligent systems to repeatedly solve known problems.

It compiles solved knowledge into machine experience.

---

# 83. Final Invariant

Semantic A2A SHALL be considered correctly implemented only when the following relation is structurally true:

$$
\boxed{
\text{No semantic object can produce consequential state merely by being generated, received, interpreted, planned, proven, or constructed.}
}
$$

Consequence requires the entire lawful chain:

$$
\boxed{
O
\xrightarrow{\alpha_B}
O^*
\rightarrow
SELECT
\rightarrow
CONSTRUCT
\rightarrow
Authority
\rightarrow
BRCE
\rightarrow
DO
\rightarrow
Receipt
}
$$

and every arrow has standing.

That is Semantic A2A.

---

# Appendix A — Compact Algebra

$$
O^*=\alpha_B(O)
$$

$$
A=\mu(O^*)
$$

$$
C_t=\pi(O^*,G,T,E_t)
$$

$$
LLM(x)\Rightarrow Candidate(x)
$$

$$
Candidate(x)\not\Rightarrow Standing(x)
$$

$$
Standing(x)\Rightarrow Admitted(x)
$$

$$
SELECT\not\Rightarrow Authority
$$

$$
CONSTRUCT\not\Rightarrow Authority
$$

$$
Plan\not\Rightarrow Authority
$$

$$
Proof\not\Rightarrow Authority
$$

$$
DO(a)\Rightarrow Authority(a)
$$

$$
Attempted(a)\Rightarrow PreparedReceipt(a)
$$

$$
\neg Standing(x)\Rightarrow\neg DO(x)
$$

$$
UNKNOWN\rightarrow Candidate\rightarrow O^*\rightarrow MACHINE
$$

$$
\frac{\partial I_{\mathrm{required}}}
{\partial MachineExperience}<0
$$

---

# Appendix B — Strict Semantic A2A Contract

A Strict node effectively promises:

> I will accept arbitrary candidates but not arbitrary truth.
> I will exchange semantic identity rather than private interpretation where public semantics exist.
> I will not treat an agent, message, task, plan, proof, capability, or generated artifact as authority.
> I will not allow inadmissible state, plans, rules, validators, or manufacturers to acquire standing.
> I will perform known production work through bounded formal machinery.
> I will route unresolved novelty through bounded discovery and return its output to admission.
> I will construct executable artifacts from admitted semantics rather than maintain them as independent sources of truth.
> I will not perform consequential actuation without explicit authority and durable receipt preparation.
> I will preserve replayable evidence of what was admitted, selected, constructed, authorized, attempted, changed, and verified.
> I will convert successfully resolved UNKNOWN classes into reusable machine experience so that intelligence is not repurchased indefinitely.

---

# Appendix C — One-Line Definition

$$
\boxed{
\textbf{Semantic A2A is machine-to-machine coordination in which shared admitted semantics, rather than agent interpretation, determine what may become real.}
}
$$

The most important addition relative to our earlier `ash_a2a` work is **meta-admission**: the RFC now formally prevents not only bad states and bad plans from acquiring standing, but also **unadmitted validators, rules, planner domains, manufacturers, and authority policies** from defining what “valid” means. That closes the “block the unrigor one level up” requirement.

[1]: https://a2a-protocol.org/dev/specification/ "Overview - A2A Protocol"
[2]: https://www.w3.org/TR/rdf-canon/ "RDF Dataset Canonicalization"
[3]: https://www.w3.org/groups/cg/shex/ "Shape Expressions | Community Groups | Discover W3C groups | W3C"
[4]: https://www.w3.org/TR/shacl12-core/ "SHACL 1.2 Core"
[5]: https://www.w3.org/community/n3-dev/ "Notation 3 (N3) Community Group"
[6]: https://www.w3.org/TR/sparql12-query/ "SPARQL 1.2 Query Language"
[7]: https://www.w3.org/TR/odrl-model/ "ODRL Information Model 2.2"
[8]: https://www.w3.org/TR/rdf12-concepts/ "RDF 1.2 Concepts and Abstract Data Model"


# Appendix — v26.9.24 Closure

This specification is terminal for the v26.9.24 semantic release boundary. Later implementation evidence may strengthen standing, but it must not silently change this protocol contract.

At closure, candidate/finding admission remains non-authoritative; consequential execution is confined to the CommandBus/BRCE DO boundary; exact producer/evidence/semantic-subject bindings and independent postcondition evidence remain required where the implementation profile declares them.

[
FinalSpec 
otRightarrow Authority qquad FinalSpec 
otRightarrow ProductionStanding
]
