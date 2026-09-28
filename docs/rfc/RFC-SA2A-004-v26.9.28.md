# RFC-SA2A-004-v26.9.28

Exact Identity, Bounded Authority, Receipted Consequence

**Status:** PROPOSED NORMATIVE
**Version:** v26.9.28
**Derived from:** RFC-SA2A-003-v26.9.28 (the implementation-derived forensic baseline)
**Target:** SA2A implementations independent of language, transport, provider, planner,
storage engine and agent framework. RFC-SA2A-003 is preserved unmodified.

## 1. Abstract

SA2A turns semantic intent into bounded, attributable, replay-safe consequence. The
fundamental distinction is:

```text
CANDIDATE != ADMITTED != AUTHORIZED != DONE != VERIFIED != ATTESTED
```

An implementation MUST preserve those distinctions across every transformation. The thin
waist:

```text
exact subject -> candidate -> admission -> selection -> construction -> authority
  -> effect claim -> durable prepare -> DO -> observation -> verification
  -> receipt -> replay / standing
```

SA2A does not standardize an agent framework, planner, LLM, ontology engine, BEAM
topology, Ash resource system, workflow engine, provider or transport. It standardizes the
conditions under which a candidate may lawfully become consequence.

## 2. Core law

For every consequence-bearing operation, `A = mu(O*)`: `O*` is the admitted, bounded,
provenance-preserving subject; `mu` is a lawful construction and execution path; `A` is the
resulting artifact, observation or consequence with independently derivable standing.

- No component MAY infer authorization from semantic validity.
- No component MAY infer semantic validity from successful construction.
- No receipt MAY imply truth merely because execution occurred.
- No candidate MAY acquire standing by declaring it.

## 3. Invariants

| Law | Requirement |
|---|---|
| Exact Subject | Every consequential path MUST remain bound to an exact subject identity. |
| Candidate is not Truth | Candidate construction grants neither admission nor standing. |
| Admission is not Authority | Semantic acceptance grants no permission to act. |
| SELECT / CONSTRUCT / DO | Separate transitions with separate evidence. |
| Authority Cannot Increase | Projection, planning, transformation, provider substitution, replay or model output MUST NOT amplify authority. |
| Fence Before Effect | Consequence MUST NOT occur before a durable prepared record and effect claim exist. |
| One Effect, One Claim | One effect identity MUST NOT execute concurrently or repeatedly without a new explicit effect instance. |
| Unknown Is Not Success | Lost workers, deadlines and ambiguity become `unknown_outcome`, never implicit retry. |
| Receipt is not Truth | A receipt proves what the protocol observed and bound, not correctness of the effect. |
| Replay is not Re-execution | Replay returns evidence unless a new effect identity is explicitly constructed. |
| Transport is not Identity | Transport and provider choice MUST NOT change semantic or effect identity. |
| Refusal Is Typed | Every protocol refusal maps to a finite protocol class. |
| Standing Is Derived | Components MUST NOT independently mutate a generic standing field. |
| LLM Output Is Candidate | Model output constructs proposals; it MUST NOT manufacture authority or standing. |

## 4. State is a product

Protocol state is the product of four independent dimensions; `standing` is a pure function
over them and MUST NOT be independently assignable.

```text
semantic:  candidate | admitted | refused | unsupported
authority: none | authorized | expired | revoked | refused
execution: unclaimed | request_claimed | effect_claimed | prepared | executing
           | executed | unknown_outcome | failed
evidence:  none | receipted | verified | attested
```

semantic=admitted, authority=none, execution=unclaimed cannot exceed ADMITTED.
semantic=admitted, authority=authorized, execution=executed, evidence=verified may derive
VERIFIED.

## 5. Canonical identity

Portable identity MUST NOT depend on Erlang `term_to_binary`, language-native
serialization, map iteration order, atom identity, process identity, provider identity or
transport metadata.

- Protocol JSON objects are canonicalized with RFC 8785 (JCS) before hashing.
- Digest: `sha256(JCS(value))`, encoded `sha256:<64 lowercase hex>`.
- RDF graph identity first uses the profile-selected RDF canonicalization.

Request identity binds protocol_version, principal_id, task_id, capability_id,
semantic_subject, input, plan_identity, authority_grant_id and effect_instance_id. It
excludes provider, worker, transport, host, retry_count, message framing and telemetry ids.

Effect identity binds principal_id, capability_id, semantic_subject, canonical input digest
and effect_instance_id. A caller that legitimately intends the same effect twice MUST
construct a new `effect_instance_id`; a fresh request id alone MUST NOT create a second
effect.

## 6. Exact subject

A subject identity MUST distinguish the actual object of reasoning or consequence from
adjacent, derived or similarly named objects. A projection MAY carry the source subject
identity or produce a new derived one; it MUST NOT silently replace one with the other.
Source subject, projection, candidate, plan, command, effect, receipt and observation are
non-equivalent, and a subject-changing transform MUST be explicit.

## 7. Candidate and admission

Everything entering SA2A is a candidate. Admission MUST be deterministic over admitted
inputs, fail-closed, typed on refusal, provenance-preserving, subject-preserving and
independent of authority. Presence of a field is not evidence that it is valid: a guard
MUST validate values, relationships, bounds and expected identities, not key presence.

## 8. SELECT, CONSTRUCT, DO

- SELECT chooses among available candidates and cannot manufacture authority.
- CONSTRUCT derives a new candidate artifact; it stays a candidate until admitted.
- DO crosses the consequence boundary. Only DO may create externally relevant consequence.

A planner, model, constructor, projection engine, GraphLaw engine, workflow runtime,
provider adapter or transport MUST NOT implicitly perform DO.

## 9. Consequence classes

Capabilities declare one of `pure | observe | change | external_do | unknown`. `unknown`
MUST be refused. `pure` performs no externally visible I/O. `observe` MUST NOT mutate the
target subject and MUST produce an observation receipt whenever external I/O occurs.
`change` and `external_do` require authority and the full consequence protocol. An
`observe` declaration MUST NOT be accepted solely because a framework classifies an action
as a read; the adapter contract must support the declared floor.

## 10. Authority

Authority binds authority_id, issuer, principal_id, capability_id, subject constraint,
effect constraint, issued_at, expires_at and a revocation identity. Model-generated
authority is invalid; authentication, identity, capability-name possession, semantic
admission, a valid plan and confidence are not authority.

For consequence-bearing actions authority MUST be checked before preparation and again
immediately before DO, the second time against the authoritative source where the model
supports revocation. Checks MUST include constraints, not only principal, capability and
expiry.

## 11. Consequence protocol

```text
RECEIVED > ADMITTED > SELECTED > CONSTRUCTED > REQUEST_CLAIMED > EFFECT_CLAIMED
  > AUTHORITY_REVALIDATED > PREPARED > FENCED > DO > OBSERVED > VERIFIED
  > RECEIPT_COMMITTED
```

Any transition may refuse; refusing one edge does not terminate unrelated lawful work.

- **Request claim.** Atomically distinguish new / same+same-fingerprint / same+different
  fingerprint / in-flight / completed. Completed identical requests replay the receipt;
  conflicting fingerprints are refused.
- **Effect claim.** Claimed independently of request identity. Deduplication is mandatory
  for `change` and `external_do`; there is no permissive or token-dependent default.
- **Prepare.** Before DO, durably persist request identity, effect identity, principal,
  capability, exact subject, canonical input digest, authority identity, intended
  consequence, execution identity and predecessor binding. Failure to prepare means no DO.
- **Fence.** Immediately before DO prove the request and effect claims are still owned, the
  prepared record exists, authority is valid, subject and capability are unchanged and
  policy gates are open. The fence consults authoritative state; a process-local token is
  insufficient.
- **DO.** Exactly one component owns the transition; all effectors are reachable only
  through it. Direct adapter invocation that bypasses it is non-conformant.
- **Unknown outcome.** If the runtime cannot establish whether DO occurred it records
  `unknown_outcome`, retains the effect claim and MUST NOT repeat the effect. Recovery is
  observation, reconciliation, compensation or a new effect instance.

## 12. Receipts

A consequence receipt binds protocol_version, receipt_id, request_identity,
effect_identity, execution_identity, principal_id, capability_id, semantic_subject,
authority_id, input_digest, intended_effect, consequence_class, prepared_at, executed_at,
observed_outcome, postcondition_result, terminal_status, predecessor_binding and
binding_digest. An implementation SHOULD bind its exact software subject.

Receipt bindings crossing a trust boundary MUST use an authenticated construction; a plain
digest MUST NOT be described as tamper-resistant against a writer able to recompute it.
Durable prepare journals MUST have integrity protection appropriate to their threat model.
After a syntactically valid request identity exists, a terminal refusal SHOULD produce
durable refusal evidence.

## 13. Replay

Same request identity + same fingerprint returns the same prior evidence and never
executes again. Re-execution requires a new effect instance or an explicit recovery
protocol proving the original effect did not occur. Receipts record whether they are
original observations or replayed evidence.

## 14. Refusal algebra

Every refusal maps to one class: `refused_identity`, `refused_structure`,
`refused_authority`, `refused_consequence`, `refused_profile`, `refused_provenance`,
`refused_falsifier`, `refused_rule`, `refused_receipt`, `refused_plan`, `refused_bounds`,
`blocked_resource`, `blocked_unknown`, `unsupported_profile`. Finer codes may exist beneath
a class; unknown codes map to `blocked_unknown`, never success. A refusal SHOULD carry
class, code, stage, subject_identity, detail, recoverability and lawful_next_edges.
Refusal is edge-local; global `BLOCKED` exists only when no lawful path to a required
outcome remains.

## 15. Closure laws

Module names are not protocol. Before DO a conforming path MUST close over exact subject,
capability, scope, authority, effect budget, effect identity, idempotency, prepared
receipt, replay safety, postcondition, provenance, policy and version compatibility, in
any deterministic mechanism. A law that exists only in tests or documentation is not
protocol enforcement.

## 16. Planning

Planning is optional. A plan that participates in the decision has its admitted identity
in the request identity; a plan mutation after admission is a new candidate. Plan validity
grants no authority; planner output grants no standing; a command claiming a plan identity
is rejected if not derivable from that exact admitted plan.

## 17. Provider and transport independence

Transport, provider, worker, host, node, queue, engine, retry transport and storage
implementation MUST NOT alter request or effect semantics. A provider-specific constraint
that changes semantics belongs in the capability or authority contract.

## 18. Semantic engines and ontologies

RDF, ShEx, SHACL, SPARQL, Datalog and GraphLaw produce evidence consumed by admission; they
grant no DO authority. A missing required engine MUST yield an explicit unsupported or
blocked state, never silent degradation to weaker semantics.

## 19. SPG and projections

SPG identities are evidence identities and MUST preserve graph, version, node, edge and
projection-family identity through projection and receipts. A conformance corpus MUST be
evaluated independently of its own expected assertions and pinned by digest when used as
conformance evidence.

## 20. Observability and OCEL

Executions SHOULD project to OCEL 2.0 with lifecycle events: received, admitted,
request_claimed, effect_claimed, prepared, authority_revalidated, do_started, do_observed,
postcondition_verified, receipt_committed, refused, unknown_outcome, reconciled,
compensated. Events preserve request, effect, subject, execution and receipt identities.
Telemetry is evidence, not authority.

## 21. Security boundary

The boundary is the consequence protocol, not a public module name. A conforming
implementation MUST prevent: caller-supplied fake capability descriptors, caller-supplied
prepared anchors, direct effect adapter invocation, authority bypass through alternate
execution APIs, unclassified side-effecting observe operations, silent broker revocation
bypass, cross-principal continuation lookup and unauthenticated durable prepared-record
forgery. Source-code regexes MAY supplement but MUST NOT be the sole mechanism.

## 22. Conformance

| Court | Required evidence |
|---|---|
| Identity | Cross-runtime canonical digest vectors |
| Subject | Exact-subject mutation refusals |
| Admission | Value-checking negative corpus |
| Authority | Non-implication and revocation-at-DO tests |
| Request claim | Replay / conflict / in-flight tests |
| Effect claim | Fresh-request duplicate-effect test |
| Prepare | Crash-before-DO test |
| Fence | Stale owner / forged prepare / changed authority tests |
| DO | Exactly-one reachable consequence boundary |
| Unknown outcome | Timeout / lost-worker tests with no automatic retry |
| Receipt | Mutation and predecessor-binding tests |
| Replay | Evidence replay without DO |
| Transport | Provider/transport substitution invariance |
| Refusal | Total classification corpus |
| Projection | Identity-preservation vectors |
| Recovery | Unknown-outcome reconciliation without duplicate effect |

A green suite, PR, release or CI status does not establish conformance; courts over the
exact released subject do.

## 23. Cross-runtime requirement

At least one core conformance implementation MUST execute outside the primary runtime.
The portable specification includes canonical identity, authority decision, refusal
classification, effect identity, receipt binding and replay decision.

## 24. Legacy behavior

Legacy behavior MAY exist only through an explicit compatibility profile that identifies
itself in receipts and does not claim strict conformance. Not silent defaults:
term_to_binary portable identity, unkeyed security claims, token-optional effect
deduplication, unchecked caller-supplied resolved capabilities, optional revocation checks,
caller-selected consequence gates, implicit release-closure bypass, multiple independent
standing fields.

## 25. Runtime roles

Ingress, Canonicalizer, Admission, Selector/Constructor, Authority source, Request claim
store, Effect claim store, Prepared receipt journal, Consequence fence, Effector,
Observer/Postcondition verifier, Receipt store, Replay/Reconciliation. Roles may share
processes or modules but MUST NOT collapse semantically: admission is not authority,
prepare is not do, do is not verify, receipt is not standing.

## 26. Relationship to AshA2A

AshA2A is one implementation. The protocol does not standardize the Ash DSL, GenServer
topology, process dictionary, Ekv, Oban, Reactor, Wasmex, GraphLaw, Chicago module names,
or the `CommandBus` / `BrceAnchor` names. Divergence between AshA2A and this RFC is
implementation work, not a reason to weaken the protocol. RFC-SA2A-003 remains the
forensic record.

## 27. Required implementation convergence

| Current divergence | Required convergence |
|---|---|
| Multiple standing systems | Derived product state; no generic mutable standing |
| Multiple digest encodings | Portable JCS + SHA-256 protocol identity |
| Request dedup stronger than effect dedup | Mandatory independent effect claim |
| Broker not checked at DO | Revalidate authoritative grant immediately before DO |
| Process-local BRCE anchor | Durable prepared-record verification at the fence |
| Unauthenticated prepare journal | Integrity-protected durable prepare evidence |
| Public/forgeable effect paths | Effectors reachable only through the consequence boundary |
| Observe may hide effects | Explicit pure/observe/change/external_do contract |
| Kill/policy gates caller-opt-in | Active policy gates runtime-selected and mandatory |
| GALL closure mostly library-only | Required closure predicates execute before DO |
| Presence-as-admission | Value and relationship validation |
| SPG self-evaluation | Independent predicate evaluator |
| OCEL builder divergence | One normative event vocabulary/projector contract |
| Implicit legacy behavior | Explicit legacy profile only |

## 28. Falsification

Any single observation falsifies a major claim: same effect identity executing twice
without a new effect instance; revoked authority crossing DO; forged prepared evidence
crossing DO; provider substitution changing effect identity; model output creating
authority; projection increasing authority; a candidate self-declaring standing; unknown
outcome retrying automatically; receipt mutation preserving a valid binding; a direct
adapter path causing consequence outside the fence; two conforming runtimes deriving
different identity; a malformed or unknown consequence reaching DO. Every release claiming
conformance MUST attempt these falsifiers.

## 29. Compact protocol

```text
subject -> canonicalize -> admit/refuse -> select -> construct -> claim(request)
  -> claim(effect) -> authorize -> prepare(durable) -> fence -> DO -> observe
  -> verify -> receipt -> derive standing -> replay/reconcile
```

Invariants: authority_out <= authority_in for every transformation; every consequence has
prepared_before(DO), exact subject, valid authority and a unique effect claim; replay
yields evidence and never DO; candidate does not imply admitted, admitted does not imply
authorized, authorized does not imply executed, executed does not imply verified,
verified does not imply attested.

## See Also

- `docs/rfc/RFC-SA2A-003-v26.9.28.md` — implementation-derived baseline
- `docs/rfc/RFC-SA2A-004-delta-v26.9.28.md` — executable delta: MUST to module/test map
