# RFC-SA2A-003-v26.9.28

Implementation-Derived SA2A Protocol and Core Semantics

## Table of contents

1. Status
2. Exact subject
3. Abstract
4. Motivation
5. Scope and non-goals
6. Terminology
7. Ontology
8. State model
9. Topology
10. Identity
11. Capability
12. Admission
13. Planning, selection, construction
14. Authority and consequence
15. CommandBus and BRCE
16. Receipt and evidence
17. Replay, idempotency, durability
18. SPG
19. GALL closure
20. OCEL and observability
21. Refusal algebra
22. Provider and transport independence
23. Conformance
24. Falsification
25. Interoperability
26. Current AshA2A realization
27. Contradictions
28. Gaps
29. Open questions
30. Security and authority considerations
31. Backward compatibility
32. Evidence appendix

Closing material after section 32: generalization candidates, ERRC, See Also.

## 1. Status

**Status:** OBSERVED BASELINE. Not a roadmap. Not a specification the code is required to meet.

**Precedence:** code + tests + courts > RFCs > docs. Where an RFC or doc disagrees with code, the
disagreement is recorded in section 27 as evidence. RFC-SA2A-001 and RFC-SA2A-002 are not
rewritten and the implementation is not conformed to them by this document.

**Labels used.** OBSERVED (read in code or executed), DERIVED (follows from observed code),
PARTIAL, UNSUPPORTED, CONTRADICTED, OPEN.

**Law classes used.** IMPLEMENTED, PARTIALLY_IMPLEMENTED, TEST_ONLY, DOCUMENTED_ONLY,
CONTRADICTED, ABSENT.

**Normative language.** MUST / MUST NOT in section 7 through 22 describe what the observed
implementation enforces. They are descriptive of behavior, and each names its evidence.
Statements without evidence are labeled OPEN.

## 2. Exact subject

| Field | Value |
|---|---|
| Repository | `/Users/sac/ash_a2a` |
| Branch | `main` |
| Local HEAD | `84bbe18f6f07ff5d6b79adf3755bd94cb73478d4` |
| origin/main | `0da2e1588166d455368a655b12faa24bf8b876a2` |
| mix.exs version | `26.9.28` |
| PR #56 | MERGED (`gh pr view 56`), merge commit `0da2e158` |
| PR #56 title | Deduplicate closure implementations under canonical Gall.Closure |

Local HEAD is origin/main (which contains PR #56) plus merge and fix-forward commits. During
authoring HEAD moved from `8d4f932` to `84bbe18`; the only commit between them is
`84bbe18 test: align agent tests with async transport and fail-closed auth default`, and
`git diff --stat 8d4f932 84bbe18 -- lib` is empty, so every `lib/` observation below holds at
both. The coordinator reports the full suite green at `84bbe18` (1908 tests, 0 failures);
that run was not repeated by this document. No delta section is provided; only the survivors
of PR #56 are recorded (section 19).

Working tree at the first observation had unrelated modifications (`config/test.exs`,
`test/ash_a2a_agent_moduledoc_test.exs`). They are not part of the subject.

One command was executed to obtain ground truth: `mix ash_a2a.verify_conformance`
(section 23). It ran with default environment, so no `:semantic_engine` was configured.

## 3. Abstract

AshA2A is an Elixir library that exposes Ash resource actions as A2A agent skills and routes
consequence-bearing calls through a receipted boundary (`AshA2A.CommandBus`). Around that core
sits a much larger semantic layer (standing chains, admission pipelines, planning, closure
policies, conformance corpora) most of which is library code reachable from tests and
Chicago courts rather than from the runtime dispatch path.

The runtime protocol actually enforced is small: consequence classification, authority match,
command and actuation claims, a durable pending receipt before DO, an execution fence, a
DO deadline, a postcondition check, and a chained receipt binding. Everything else is
candidate machinery. This document separates the two.

## 4. Motivation

Two earlier RFCs describe intended semantics. Neither says which parts run. A non-Elixir
runtime needs the enforced subset, the identity encodings, the refusal taxonomy, and the
places where the code disagrees with itself. This document is that extraction.

## 5. Scope and non-goals

In scope: behavior observable in `lib/ash_a2a`, `test/`, `priv/` corpora, and the Chicago
courts (`lib/ash_a2a/chicago/courts`, 47 modules).

Non-goals: fixing contradictions; proposing new features; specifying GraphLaw internals (an
external WASM engine); judging RFC-001/002 requirements not exercised by code.

## 6. Terminology

- **Command**: `AshA2A.Command`, one requested capability invocation with fingerprint.
- **Consequence**: `:observe | :change | :external_do | :unknown` per capability.
- **DO**: the single Ash action invocation in `AshA2A.Dispatcher`.
- **Anchor**: a `%Receipt{status: :pending}` durably appended before DO.
- **Actuation**: effect identity (`AshA2A.Actuation`), distinct from command identity.
- **Standing**: a named position on a lattice. Four independent axes exist (section 8).
- **Court**: a Chicago module that attempts to falsify a claim over a real run.
- **Evidence identity**: a digest carried for binding, granting no authority.

## 7. Ontology

Objects observed as first-class structs: Command, Authority, Receipt (with Binding),
Actuation, Skill (capability), Identity (kinds: command, agent, principal, task, execution,
actuation, idempotency, runtime), SemanticSubject, SpgIdentity, Envelope, IR, PlanPackage,
BoundedPlan, Preflight, WorkOrder (HILT), ExecutionIdentity, ExecutionSnapshot,
CapabilityRelease (Capability, Closure, Binding), Refusal.

Relations observed as code: command -> receipt (claim, anchor, finalize); command -> actuation
(effect digest); plan -> preflight (14 bound fields); work order -> command (metadata binding
into the fingerprint); closure -> capability (strict membership).

Ontology-as-RDF exists in `priv/ontology` and `priv/semantic` and is consumed by
`AshA2A.Semantic.*`; the runtime CommandBus path does not read RDF (DERIVED from
`command_bus.ex` aliases).

## 8. State model

### 8.1 Four standing axes

| Axis | Values | Driven by (lib, non-test) |
|---|---|---|
| `Semantic.Standing` | 17-chain `candidate .. attested` plus 5 terminals | Peer via Ledger |
| `Semantic.AdmissionStanding` | 10 stages `candidate .. admitted` | AdmissionPipeline |
| `IR.standing` | `:candidate` or `:admitted` | IR constructors |
| `Receipt.standing` | `:durable` set by `mark_standing/2` | CommandBus |

OBSERVED: `Standing.transition/3` has no caller in `lib/` outside
`chicago/courts/receipt_binding.ex`. The 17-state chain is not driven by CommandBus.
`Peer` records into `Standing.Ledger` through `Ledger.record/4`, which allows a bulk
`:candidate -> :admitted` edge that `transition/3` refuses (`standing.ex:1004-1130`).
`AdmissionPipeline` advances `AdmissionStanding` (`admission_pipeline.ex:411,845`), not
`Standing`. `AdmissionPipeline.admit/2` has no non-Chicago caller in `lib/`.

### 8.2 Terminal states

`Standing` terminals: `refused, blocked, unknown, unsupported, failed`, absorbing.
`Refusal.terminal_standing/1` maps classes to only four of them (`refused`, `blocked`,
`unknown`, `unsupported`); `:failed` is never produced by that function (DERIVED).

### 8.3 Receipt terminal status

`Receipt.terminal_statuses`: `executed, refused, failed, reconciled, compensated,
unknown_outcome`. `:pending` receipt has `terminal_status: nil`.

### 8.4 ExecutionSnapshot

`queued -> claimed -> running -> checkpointed -> completed`, plus `reclaimable` after
`worker_lost/1`. Checkpoint sequence must increase. Library only; see section 17.

### Falsification

Existing: `semantic_standing_test.exs` (chain order, every non-adjacent jump refused,
backward refused, terminals absorbing, 11 forbidden inference keys);
`semantic_admission_standing_test.exs`; `ash_a2a_execution_snapshot_test.exs`.
No falsifier exists for "runtime dispatch advances Standing", because it does not.
No falsifier reconciles the four axes with each other.

## 9. Topology

Runtime processes started by `AshA2A.Application` (`application.ex`): receipt store (Memory
default; Ekv opt-in), authority broker (Ekv opt-in), `ReceiptOutbox.Reconciler`,
`Telemetry.TaskSupervisor` (bounded, default 256), `Semantic.PackageStore`, `KillSwitch`,
GraphLaw Wasmex host, and the A2A agent supervisor.

Protocol-necessary (a peer runtime needs an equivalent): receipt store with claim/commit,
a durable pre-DO anchor journal, an authority source. OTP-incidental: process registry,
Task.Supervisor sizing, Wasmex pooling, telemetry forwarder.

`AshA2A.KillSwitch` is started but consulted only when a caller passes `:kill_switch_class`
(section 14). `TaskStore.Ekv` has no reference in `lib/` outside its own file (OBSERVED by
search; only `test/ash_a2a/task_store_ekv_test.exs` uses it).

## 10. Identity

### 10.1 Encodings in use

| Identity | Preimage | Encoding |
|---|---|---|
| `Command.fingerprint` | 9-tuple (below) | sha256 hex over `term_to_binary` deterministic |
| `Actuation.digest` | effect tuple | `"sha256:" <>` hex, same encoding |
| `WorkOrder.identity_digest` | 11 fields, no metadata | `Actuation.digest` |
| `Preflight` | 14 bound fields | `CanonicalTermDigest.digest` per field |
| `CapabilityRelease.portable_digest` | closure members | sha256 over JCS JSON |
| `Semantic.AdmissionHash` | canonical graph, validators, rules | BLAKE3 over netstrings |
| GraphLaw graph hash | RDFC graph | bare 64-hex, no prefix |
| `Receipt.Binding` links | 11 bound fields | sha256 (or HMAC-SHA256 if keyed) |

OBSERVED: encodings are not unified. A non-Elixir runtime cannot reproduce the
`term_to_binary` digests without emulating the Erlang external term format; only the JCS
and BLAKE3 identities are language-neutral.

### 10.2 Command fingerprint tuple

`{agent_id, principal_id, task_id, capability_id, input, authority.token_id,
SemanticSubject token, SpgIdentity token, semantic_metadata_identity}` (`command.ex:99-`).
`command_id` and `submitted_at` are excluded. Transport metadata is excluded.

### 10.3 Actuation identity

`effect_digest = H({capability_id, principal, semantic_subject token, input_digest,
external_token})`. `command_id` and `agent_id` are excluded by design (`actuation.ex`).
External token order: `opts[:idempotency_key]`, then `metadata.idempotency_key`, then
`authority.constraints.external_idempotency_token`.

### 10.4 Subject identities

`SemanticSubject{graph, projection, manufacturer digest, ephemeral?}` requires
`sha256:`+64 lowercase hex. `SpgIdentity{graph_id, graph_version, node_id, edge_id?,
projection_family?}` requires non-empty strings. Both are evidence identity only and both
enter the fingerprint.

### 10.5 Execution identity

`ExecutionIdentity{task_id, work_order_digest, command_digest, exact_subject,
candidate_digest, authority_digest, consequence_digest, capability_digest}`. Provider,
transport, worker and run identifiers are absent by construction.

### 10.6 Additional observations

- Atom-keyed and string-keyed `input` fingerprint differently (`term_to_binary` of distinct
  terms), so the same JSON-shaped input from two runtimes can yield two commands.
- `Gall.Closure.Determinism.digest/1` is a second "canonical" scheme: it stringifies map
  keys, flattens tuples to lists, then `term_to_binary`. `Command.fingerprint` uses raw
  terms. Neither is the other's canonical form. Collisions in `Determinism.canonical/1`
  (executed probe): `{"a",1}` vs `["a",1]`, `%{a: 1}` vs `%{"a" => 1}`; the coordinator
  additionally reports `%{1 => x}` vs `%{"1" => x}`. `determinism_test.exs` has one test
  (string keys only); no test pins the collisions.
- Metadata identity in the fingerprint uses `||` over `candidate_digest` and the legacy
  `gall_029_candidate_digest` spelling.

### Falsification

Existing: `ash_a2a_command_fingerprint_determinism_test.exs` (insertion order, map size
boundary, stable hex, fresh command_id keeps fingerprint, work-order binding changes it,
provider metadata does not); `ash_a2a_actuation_identity_test.exs`;
`ash_a2a_semantic_subject_command_test.exs`; `ash_a2a_spg_identity_test.exs`;
`hilt_work_order_execution_identity_test.exs`.
No falsifier exists that two runtimes compute equal `term_to_binary` digests.
No falsifier compares digest algorithms across the identities in 10.1.

## 11. Capability

A skill has `id`, `name`, `resource`, `action`, `consequence`. Consequence comes from the
capability definition (`skill.ex`, `AshA2A.Info.skill/2`), never from the request.

- A mutating action (`create/update/destroy`) declared `consequence: :observe` is refused at
  compile time (`observe_on_mutating_action`, class `refused_consequence`,
  `transformers`).
- An unclassified generic action resolves to `:unknown` and is refused
  `consequence_unclassified` on the Agent path and in `CommandBus.admit/2`.
- `CapabilityRelease` states `candidate -> admitted -> released -> retired`; only released
  capabilities enter a frozen closure; duplicate id cannot freeze; retired cannot re-freeze.

Strict release mode is opt-in (`opts[:capability_release_closure]` or
`config :ash_a2a, :capability_release_mode, :strict`); the default returns `{:ok, nil}`
(legacy). `Dispatcher` also calls `CapabilityRelease.guard/2` before actuation
(`dispatcher.ex:248`); `CommandBus` additionally records the binding.

### Falsification

Existing: `consequence_floor_test.exs`; `capability_release_test.exs` (strict refuses
outside closure, strict without closure fails closed, legacy compatible, filter parity
between advertised and executable); `ash_a2a_agent_command_bus_test.exs` (unclassified
refused, no receipt). No falsifier that legacy mode is unreachable in production.

## 12. Admission

Two admission systems exist and do not share code paths at runtime.

**Runtime admission (CommandBus).** Order in `run/4`: work order verify, target resolve,
release binding, plan preflight, authority/consequence admit, kill switch (opt-in), command
claim. Refusals before claim return `{:error, %{code:, detail:}}` with no receipt
(`ash_a2a_agent_command_bus_test.exs:215,338`).

**Semantic admission (library).** `AdmissionPipeline` runs stages
`parse, identity, shex, shacl, rule_closure, falsifiers, provenance, profile` through
GraphLaw WASM and advances `AdmissionStanding`. "Could not determine" refuses exactly like
"determined against" (moduledoc; `determinacy: :undetermined`). Empty falsifier set is
refused. Law documents need standing (`:law_without_standing`).

`Semantic.Peer.admit/2` wraps envelope receipt, profile negotiation, and GraphLaw, and
records to `Standing.Ledger`. Envelopes can only be constructed at `:candidate`; a payload
that declares its own standing is refused (`:standing_self_declared`).

### Falsification

Existing: `semantic_admission_pipeline_test.exs`; `semantic_standing_test.exs`; Chicago
courts `shex_shacl_admission`, `semantic_envelope`, `semantic_boundary`.
Gap: no test shows a runtime CommandBus call depending on a semantic admission verdict.

## 13. Planning, selection, construction

`Planning.admit/2`, `Planning.Preflight`, `BoundedPlan`, `PlanPackage` exist. Preflight
digests 14 fields: `plan_package, steps, fan_out, cascade_depth, parallelism, retry_count,
resource_budget, external_request_count, financial_envelope, authority_requirement,
semantic_subject, work_order_digest, standing, authority`. When a command is presented as a
plan step (`opts[:plan]` or `opts[:preflight]`), `Preflight.admit_step/3` re-digests the
plan and refuses a mutated field with `preflight_identity_mismatch` before claim. Commands
without `:plan` or `:preflight` skip this gate entirely (`command_bus.ex:1017`).

`Semantic.Select.select/3` and `Semantic.Construct.construct/4` return structs with
`standing: :candidate, authority: :none`. `construction_receipt` is a map, not an
`AshA2A.Receipt`. Their callers in `lib/` are Chicago fixtures and courts only.

`PlanningIR` is constructed with `standing: :admitted` by struct default and has no
`admit` function (`planning_ir.ex:18`); `mix ash_a2a.verify_conformance` reports
`Selected(p) => AdmittedPlan(p)` UNVERIFIABLE for this reason.

### Falsification

Existing: `chicago/plan_gates_test.exs`; `PlanAuthority` and `WholePlanPreflight` courts;
`ash_a2a_authority_non_implications_test.exs` (a constructed package is still authority
none). No falsifier that selection refuses an unadmitted plan.

## 14. Authority and consequence

### 14.1 Bus admission

`CommandBus.admit/2` (`command_bus.ex:920-941`):

- `:observe`: `:ok`, no authority.
- `:change | :external_do` with `Authority{source: :model}`: `model_authority_refused`.
- with Authority: `Authority.admits?/2` requires `subject == command.principal_id`,
  `capability_id` equal, and not expired; else `authority_mismatch`.
- without Authority: `authority_required`.
- `:unknown`: `consequence_unclassified`.

DERIVED: the bus does not consult the broker. A revoked grant that is still unexpired and
carried inside a Command admits. Revocation is enforced where the Agent builds the command
(`Authority.Grant.authorize/3`), not at the bus. No test located that pins this either way
at the bus level.

### 14.2 Grant policy

`config :ash_a2a, :authority_policy` defaults to `:broker`. The legacy
`:transport_verified_grants_capability` policy is refused when the security preflight is
strict (default in `:prod`) unless explicitly acknowledged (`authority/grant.ex:176-207`).

### 14.3 Portable decision

`AshA2A.Authority.Decision.verdict/1` is a serializable decision function pinned to the bus
by `ash_a2a_authority_non_implications_test.exs:305` and to a Node host
(`test/support/hosts/authority_host.mjs`) through shared vectors
(`authority_decision_conformance.json`). It is the only implementation of a runtime law
exercised in a second language.

### 14.4 Authority outside the bus (OBSERVED)

The claim "authority is concentrated in CommandBus + BrceAnchor" is FALSE as worded.
`Dispatcher.dispatch/6` is public and `BrceAnchor`'s moduledoc concedes it fences paths, not
in-VM callers (`brce_anchor.ex:38-41`). Bypass and weak-fence candidates:

- **B1** Caller-supplied `opts[:resolved_skill]` (`%Skill{}`) is accepted unchecked against
  the capability index (`dispatcher.ex:352`). A forged skill with `consequence: :observe`
  takes `decide(_, :observe, _) -> :not_required` (`brce_anchor.ex:130`): no anchor, no
  receipt. Falsifier: none.
- **B2** A forged anchor needs no outbox entry: `decide/3` checks status, capability and
  consequence only (`brce_anchor.ex:133`); `ReceiptOutbox.anchored?/1`
  (`receipt_outbox.ex:98`) is never called by `admit/2`. `brce_gate7_test.exs:208` appends to
  the outbox first, so non-durable forgery is untested.
- **B3** The outbox journal has no MAC: default dir `tmp_dir/ash_a2a_receipt_outbox`,
  `binary_to_term(..., [:safe])` only (`receipt_outbox.ex:53,437`); `reconcile/2` commits
  any decoded `%Receipt{}` (`receipt_outbox.ex:208`). Falsifier: none.
- **B4** `admit/2` rejects only `source: :model` (`command_bus.ex:925`);
  `Authority.admits?/2` ignores constraints, evidence and input (`authority.ex:129`);
  `CommandBus.run/4` is public. Falsifier: none.
- **B5** Continuation replan is not principal-scoped (`agent.ex:463,583`): a fingerprint
  fetches another principal's receipt or PackageStore entry and triggers LLM/HDDL. The
  result is candidate only (`authority: :none`). Falsifier: none.
- **B6** The `:observe` floor blocks only create/update/destroy
  (`transformers/build_capability_index.ex:93-107`); a `:read` or generic action marked
  `:observe` may side-effect with no authority or receipt. Falsifier: none.
- **B7** `on_cancel` hook runs `apply/3` on an arbitrary module and function
  (`agent.ex:1147`). Falsifier: `ash_a2a_on_cancel_hook_test.exs` (error path only).
- **B8** Unreceipted external I/O: OCEL `Req.post` (`ocel_forwarder.ex:239`), GraphLaw
  `node` System.cmd (`sa2a/graphlaw.ex:103`), push webhooks (`push_delivery.ex:125`),
  `runtime_identity.ex:115`, `standing_ref.ex:468`, `research/erc.ex:74-147`,
  `durability/durable_server.ex:139`, `kill_switch.ex:267`. Falsifier: none.
- **B9** Oban live broker re-verify is opt-in (`ObanAuthority.verify_live!/3`). Falsifier:
  `oban_authority_staleness_test.exs`.
- **B10** The adapter fence is a source-text regex over `AshA2A.Dispatcher` references
  (`architecture_verifier/adapters.ex:248`). Falsifier: `architecture_verifier_adapters_test`.
- **B11** Chicago fixtures ship in `lib/` and use `authorize?: false`
  (`chicago/fixtures/authority.ex`, 2 sites). Falsifier: none.

`DurableServer` provider operations return `RuntimeReceipt`, not `AshA2A.Receipt`.

Attempts to falsify the protocol's core were made by the authority court and did not
succeed: agent-path `:change` and `:external_do` always go through `CommandBus.run`; the
same `command_id` and fingerprint replay the stored receipt; a stale execution cannot commit
after reclaim (`confirm_claim` yields `:stale_execution`); the semantic route is capped at
standing `:candidate`, authority `:none`; `a2a.auth` is accepted only under the atom key; the
transport cannot pass `resolved_skill` or an anchor.

Classification: "authority concentrated in CommandBus + BrceAnchor" is
PARTIALLY_IMPLEMENTED (holds for the transport-reachable Ash DO path only).

### 14.5 Kill switch

`CommandBus.check_kill_switch/1` refuses `kill_switch_tripped` only when
`opts[:kill_switch_class]` is given; an unreachable switch refuses
`kill_switch_unavailable` (fail closed). `Agent.dispatch_skill` passes no
`kill_switch_class` (`agent.ex:726-731`), so the default A2A path never consults it. The
check runs before `claim_receipt/3` only; a switch tripped after the check and before DO is
not observed.

### Falsification

Existing: `ash_a2a_authority_non_implications_test.exs` (identity, authentication,
capability, task, plan validity, proof, model confidence, agent card each fail to imply
authority; CONTROL case reaches the actuator); `ash_a2a_authority_confused_deputy_test.exs`;
`command_bus_kill_switch_test.exs`; `ash_a2a_authority_killer_negative_test.exs`.
No falsifier exists for B1 through B6, B8 and B11 in 14.4; B7 has error-path tests only.

## 15. CommandBus and BRCE

### 15.1 Consequence state machine (OBSERVED, `command_bus.ex` moduledoc and code)

```text
ADMITTED -> CLAIMED(command_id) -> ACTUATION_CLAIMED(if enforced)
         -> RECEIPT_ANCHORED(:pending) -> FENCE(confirm_claim) -> EXECUTING
         -> CONSEQUENCE_OBSERVED -> POSTCONDITION -> RECEIPT_DURABLE | RECEIPT_OUTBOXED
```

- Anchor is mandatory for `:change` and `:external_do`; if the outbox cannot persist it,
  dispatch is refused (`receipt_anchor_unavailable`).
- `confirm_claim/3`, when exported by the store, must confirm this execution still owns the
  claim, else `stale_execution` with anchor removed and no DO.
- DO runs in a monitored child with deadline (default 30 000 ms). Timeout or lost worker
  yields a receipt with `terminal_status: :unknown_outcome`, anchor kept, actuation claim
  neither committed nor released.
- `:contradicted` postcondition sets status `postcondition_contradicted` and returns an
  error.

### 15.2 BrceAnchor fence

`BrceAnchor.admit/2` lets `:observe` through and requires, for every other class including
`:unknown`, a `:pending` anchor whose `capability_id` and `consequence` match the skill.
The anchor lives in the process dictionary (`Process.put`), single use via `take/0`.
It checks only status, capability and consequence; it does not verify that the anchor came
from the outbox (its moduledoc states the scope: it fences paths, not code already inside
the BEAM). Test `brce_gate7_test.exs` uses a hand-built anchor.

### Falsification

Existing: `chicago/brce_gate7_test.exs` (direct dispatch of `:change` refused, exactly one
dispatch per anchor, cross-capability anchor refused, take/0 single use);
`command_bus_hardening_test.exs` (deadline, lost worker, trapping caller, fence,
actuation commit failure, no OCEL stash leak);
`ash_a2a_command_bus_crash_window_chicago_test.exs`; `command_bus_test.exs`.
No falsifier that a forged in-process anchor is refused.

## 16. Receipt and evidence

### 16.1 Fields

Identity: `receipt_id, command_id, execution_id, task_id, agent_id, principal_id,
capability_id, semantic_subject, fingerprint`. Outcome: `consequence, status, standing,
reply, terminal_status, recorded_at`. Prepared-receipt: `actuation_id, idempotency_key,
actor, authority_grant, intended_effect, input_digest, plan_digest, projection_digest,
logical_clock, evidence_class, binding, reconciliation, replayed?, metadata`.

`Receipt.missing_required_fields/1` reports absent S31 fields; it never manufactures them.

### 16.2 Binding

`Receipt.Binding` digests 11 field groups separately with a predecessor link. Lawful
mutations append a link. Unkeyed mode is plain SHA-256 and records `keyed: false`. With
`:receipt_binding_key` it is HMAC-SHA256. A tampered receipt is not resealed by a transition.

### 16.3 What a receipt attests

It attests the intent, the observed reply, and the independent postcondition observation
when supplied. It does not attest effect truth by itself. There is no git SHA in a receipt;
exact-SHA subjects live in `StandingRef` and `Chicago.Release.ExactSubject` only.

### 16.4 Construction receipts

`Semantic.Construction.construction_receipt` is a distinct map with `kind:
:construction_receipt`, `authority: :none`. It is not accepted as an `AshA2A.Receipt`.

### Falsification

Existing: `ash_a2a_receipt_s31_fields_test.exs`; `chicago/receipt_binding_attestation_test.exs`;
`RECEIPT_BINDING` court; `ash_a2a_receipt_replay_counting_actuator_test.exs`.
No falsifier that an unkeyed binding resists a writer who recomputes all digests (the
module states it does not).

## 17. Replay, idempotency, durability

### 17.1 Command claim

`ReceiptStore.claim/2`: same `command_id` and same fingerprint returns
`{:replay, receipt}` once committed, `{:error, :in_flight}` while claimed;
same `command_id` with different fingerprint returns `{:error, :command_conflict}`.
An in-flight claim becomes reclaimable only if the lease (default 300 000 ms) elapsed AND
the outbox holds no anchor for that command (`claim_lease.ex`).

### 17.2 Actuation claim

Enforced only when the store exports `claim_actuation/3` AND mode allows: `:declared`
(default) enforces only if an external idempotency token exists; `:strict` always; `:off`
never. DERIVED: with the default mode, a client that retries a token-less `:change` under a
fresh `command_id` crosses DO again. Test `ash_a2a_actuation_identity_test.exs:163` asserts
this and says so in its title. On the A2A path `command_id` is the client's
`message_id` (`agent.ex` ~950) and the Agent never supplies `idempotency_key`, so the
default path is exactly the `:declared` gap. The limitation is documented in
`command_bus.ex:32-33`.

### 17.3 Durability

Memory store default. Memory TTL sweep (`:receipt_ttl_ms`, default nil = keep forever) and
`:max_entries` can evict committed entries; a later claim of an evicted command re-executes
(DERIVED; TTL tests only assert what is evicted). Ekv store is durable and opt-in.
`ReceiptOutbox` journal is file-based; the Reconciler drains it.

### 17.4 Worker death

`Transport.Runtime` monitors the handler worker; on `:DOWN` the task fails; no resume
(`runtime.ex:267-288`). `ExecutionSnapshot` and `TaskStore.Ekv` describe a resumable model
but are not wired into that path. Real leases: `ClaimLease` and `ActuationClaimLease`.
`SemanticWork.Lease` and `GallClosure.LeaseGuard` are shape checks (section 19).
A stale-checkpoint or stale-lease refusal against a clock or epoch: ABSENT.

### Falsification

Existing: `ash_a2a_actuation_identity_test.exs` (fresh command_id under `:strict`, external
token collapse, in-flight refusal, release cannot reopen executed effect),
`command_bus_hardening_test.exs`, `receipt_store/actuation_claim_lease_test.exs`,
`receipt_store/store_hardening_test.exs`, `durable_server_real_restart_test.exs`.
No falsifier that a Memory TTL eviction blocks re-execution.

## 18. SPG

`SpgIdentity` (5 fields) is evidence identity. It flows: Command fingerprint -> Receipt
metadata -> `SemanticProjection.ocel_event` attributes
(`ash_a2a_spg_identity_test.exs:6`). Nothing validates the SPG graph the ids name. No drift
test spans corpus and OCEL.

`SpgConformance` (`spg_conformance.ex`) with `priv/spg_conformance/v26.9.27/` (56 JSON
cases, 28 admit / 28 refuse). The reference evaluator decides from the fixture's own
`stimulus.checks` and then compares to `assertion`. The test suite
(`spg_conformance_runtime_test.exs`) confirms that flipping the oracle without changing the
stimulus is detected and that refusal-code laundering is detected. Classification:
PARTIALLY_IMPLEMENTED: it checks fixture self-consistency and evaluator-plug-in
discipline; no independent evaluator of the named predicates ships. `corpus_digest/1` is
computed and returned but not pinned to any expected value.

### Falsification

Existing tests listed above. No falsifier that the predicates (for example
`identity.subject_sha_mismatch`) are evaluated by any runtime code other than the
fixture's own check value.

## 19. GALL closure

Three trees exist: `Gall.Closure.*` (27 modules, `lib/ash_a2a/gall/closure`), and the PR #56
survivors `GallClosure.*` (4 modules) and `SemanticWork.*` (9 modules).

Consumption in `lib/`: only `AshA2A.Gall.Receipt` aliases `Gall.Closure.Determinism`.
`Pipeline.admit/2`, `Pipeline.preflight/3` and `AuthorityBinding.admit/4` have no caller
outside `gall/closure/` (OBSERVED by search). The survivors have no callers except their
own tests.

Behavior of survivors: `CheckpointBinding`, `InterventionClosure`, `FindingBinding` accept
any value other than nil/false/""; `LeaseGuard` accepts any non-negative integer
`lease_epoch` and compares it to nothing; `SemanticWork.*` `bind/1` only require key
presence (`Envelope.fetch/2`) and, for `Lease`, integer or DateTime `expires_at`.
`docs/explanation/closure-implementations.md` lists "Eliminate: presence-as-admission" and
"Raise: lease checks must compare against expected value"; the survivors do neither.

`Gall.Closure` defects OBSERVED:

- `Pipeline.preflight/3` runs CommandBinding, ScopePolicy, BudgetPolicy, IdempotencyPolicy,
  PostconditionPolicy; it does not run AuthorityBinding, ReceiptBinding, ReplayGuard,
  Compatibility or Migration.
- `Recovery.route/1` has clauses for 10 boundaries plus a generic refused clause; boundaries
  such as `authority_binding`, `capability_policy`, `idempotency_policy` fall to
  `{:repair, :reconstruct_candidate}` or `{:stop, :not_a_refusal}` depending on status.
- `Determinism.canonical/1` collides: probe executed in this session gave
  `canonical({"a",1}) == canonical(["a",1])` true and
  `canonical(%{a: 1}) == canonical(%{"a" => 1})` true (tuple/list and atom/string key
  collisions).
- `defp field(map, key)` is duplicated in about 20 sites (15 in `gall/closure`,
  `gall/receipt.ex:53`, `gall/process_intervention.ex:318`; a reverse variant at
  `planning/semantic_synthesis.ex:214`) as `Map.get(map, key) || Map.get(map, to_string(key))`;
  a stored `false` under the atom key falls through to the string key. Mechanism confirmed;
  no call site was found where it changes a decision (PARTIAL as a defect).
- `Gall.ProcessIntervention` has no callers in `lib/` either.
- Two lease shapes: `GallClosure.LeaseGuard` (integer `lease_epoch >= 0`) versus
  `Gall.WorkLease` (`gall/work_lease.ex`, URN-string epoch and lease IRI). The closure doc
  says `Gall.Closure` has no lease law and names `LeaseGuard` owner; `Gall.WorkLease`
  exists outside `Gall.Closure` and the two are not reconciled.
- Authority markers differ: atom `:none` (Select, Construct, PlanningIR, Preflight) versus
  strings `"NONE"` and `"CANDIDATE"` (Migration, SemanticWork.Candidate).

### Falsification

Existing: `test/ash_a2a/gall/closure/*` (per-module), `test/gall_closure/*`,
`test/semantic_work/*`, `gall_process_intervention_test.exs`,
`gall_checkpoint_003_command_authority_chicago_test.exs`.
No falsifier that the closure runs before DO in production. No falsifier for the
collisions above (the probe was executed once, not committed as a test).

## 20. OCEL and observability

Two OCEL builders exist with different shapes.

- `SemanticProjection.ocel_event/1`: flat event with `attributes` map and a
  `relationships` list that defaults to `[]`; SPG ids are attributes, not objects. Used at
  runtime by `Telemetry.OcelForwarder` (`ocel_forwarder.ex:338`).
- `Gall.Closure.OcelProjection`: OCEL 2.0 objects; referenced only by its test.

`Gall.Closure.TelemetryEnvelope` is never emitted at runtime. Boundary telemetry
`[:ash_a2a, :command_bus, ...]` is emitted at each transition (target, preflight, admission,
commitment, kill_switch, claim, prepare, actuate, postcondition, commit). The OCEL
pending-dispatch stash is deleted after every consequence path (`command_bus_hardening_test`
last test).

### Falsification

Existing: `ash_a2a_telemetry_ocel_forwarder_*_test.exs`, `chicago/ocel_validator_test.exs`,
`OCEL_VALIDITY` court. No falsifier that the two builders agree on shape.

## 21. Refusal algebra

`Semantic.Refusal` defines 18 S42 classes: 15 `refused_*`, `blocked_unknown`,
`blocked_resource`, `unsupported_profile`. `classify/1` accepts atoms only; unmapped atoms
return `:blocked_unknown`. Modules contribute codes through `__sa2a_refusal_codes__/0`,
merged at runtime and cached in `:persistent_term`.

`terminal_standing/1`: any `refused_*` -> `:refused`; `blocked_resource` -> `:blocked`;
`blocked_unknown` -> `:unknown`; `unsupported_profile` -> `:unsupported`.

The struct has `class, code, stage, detail, lawful?`. There is no retry or recovery field.
`in_flight` is classed `refused_identity`. `Gall.Closure.Refusal` and
`AdmissionRefusal` are separate shapes. Raw exceptions still occur on `new!` and `raise`
paths; the classification totality test only sees code-shaped literals.

Totality is enforced by `semantic_refusal_test.exs`, which regex-scans `lib/**/*.ex` for
four literal patterns (`code: :x`, `error(:x`, `refusal(:x`, `{:error, :x}`). Codes built
any other way are outside its reach.

### Falsification

Existing: `semantic_refusal_test.exs` (18 classes, partition, classification, scan);
`chicago/brce_gate7_test.exs:137` (fence code classified without editing the table);
`consequence_floor_test.exs:138`. No falsifier for dynamic-atom codes.

## 22. Provider and transport independence

`ExecutionIdentity` and `WorkOrder.identity_digest` exclude provider and transport. Test
`command_bus_test.exs:253` ("HILT work order is verified before claim and survives provider
substitution") and `hilt_work_order_execution_identity_test.exs` witness it.
`Command.fingerprint` excludes transport metadata. `TransportIndependence` court exists.
Authority is bound by grant identity and constraints, not by transport, except under the
legacy grant policy (14.2).

The A2A wire layer is a vendored `:a2a` 0.2.0. The semantic profile rides on
`supportedInterfaces[].protocolBinding` because the encoder drops
`capabilities.extensions` (`semantic/extension.ex`; asserted in
`ash_a2a_semantic_extension_test.exs`).

### Falsification

Existing tests above plus `chicago/cross_runtime_portability_test.exs` (GraphLaw in two WASM
runtimes). No falsifier that a non-BEAM runtime reproduces receipts or fingerprints.

## 23. Conformance

`mix ash_a2a.verify_conformance` was executed at the subject. Earned level: **none**.

| Profile | Result |
|---|---|
| SA2A-CORE | NOT CONFORMANT, 6/10 met |
| SA2A-LOGIC | NOT CONFORMANT, 6/14 met |
| SA2A-PLAN | NOT CONFORMANT, 7/20 met |
| SA2A-DO | NOT CONFORMANT, 13/26 met |
| SA2A-STRICT | NOT CONFORMANT, 14/34 met, 2 unverifiable |

DO-level requirements met: authority_broker, brce, prepared_receipts, execution_receipts,
reconciliation, replay_evidence. CORE unmet: canonical_graph_identity, shex, shacl, sparql
falsifiers. Caveat: ShEx, SHACL, SPARQL and Datalog rows depend on a configured
`:semantic_engine`; none was configured in this run, so those UNMET rows are
environment-conditioned, not proof that the engine paths fail.

Invariants from the same run: three HOLDS witnessed for Executed/Authorized/Prepared,
`LLMOutput => Candidate`, Projection, Message and Task non-implications; one VIOLATED
(private terms `acme:widget` and `acme/widget` mint the same IRI, un-admitted and
non-injective); three UNVERIFIABLE.

Other corpora: `priv/sa2a_conformance_vectors` (GraphLaw dual-runtime, 9 vectors),
`priv/spg_conformance`, `priv/sa2a/corpus`.

### Falsification

The conformance command is itself the falsifier and refuses. There is no test asserting the
conformance level is stable across commits.

## 24. Falsification

Aggregate view (details per section above).

- Courts: 47 modules in `lib/ash_a2a/chicago/courts`; runner and mutation harness in
  `lib/ash_a2a/chicago/`. Mutation catalog exists (`chicago/mutation/catalog.ex`).
- Corpora: SPG (56), SA2A vectors, `sa2a_chicago_mandatory_corpus`.
- Test-suite discipline: no-mock scan module `Chicago.Collaborators.MockScan`.

Claims with an existing falsifier are marked in section 32. Claims marked "none" in the
appendix have no located falsifier.

## 25. Interoperability

Enforced wire facts: A2A JSON-RPC via `:a2a`; semantic negotiation only through the exact
profile id `SA2A-PROFILE-v26.9.20` on both peers' cards (`Extension.negotiate/2`); ordinary
A2A traffic never becomes semantic traffic (`Extension.activated?/1`).

A non-Elixir peer can implement: the consequence classification, authority match (with the
Node host as an existing precedent), command/actuation claim protocol, receipt field set,
refusal taxonomy, release-closure JCS digest, GraphLaw calls. It cannot yet reproduce
fingerprints, actuation ids, work-order digests or binding links without Erlang
`term_to_binary`. DERIVED.

The profile constant is `v26.9.20` while the package is `26.9.28` (DERIVED drift).

## 26. Current AshA2A realization

Elixir, Ash 3 DSL (`AshA2A.Dsl`, transformers), `A2A.Agent` handler
(`AshA2A.Agent`), `Dispatcher` (single DO), `CommandBus`, `ReceiptStore` behaviours
(Memory, Ekv), `ReceiptOutbox` (file journal), `Authority.Broker` (InMemory, Ekv),
GraphLaw via Wasmex, Oban and Reactor adapters, Chicago courts and mutation harness.

Adapter fence: `ArchitectureVerifier.Adapters` detects `AshA2A.Dispatcher` references by
source-text regex (`adapters.ex:248-255`); aliasing through a variable module evades it
(DERIVED).

Runtime path reachable from an A2A message: Agent.dispatch_skill -> (`:observe`:
Dispatcher) | (`:change|:external_do`: build_command -> Grant.authorize ->
CommandBus.run) | (`:unknown`: refusal).

## 27. Contradictions

Preserved as evidence; none resolved here.

| # | Contradiction | Evidence |
|---|---|---|
| C1 | `transition` needs 8 steps to admitted; `Ledger.record` allows bulk edge | standing.ex:1004 |
| C2 | Stage/dialect map swapped between StateMachine and Standing | state_machine.ex:103 |
| C3 | peer.ex comment: AdmissionPipeline uses `Standing.transition` | pipeline.ex:411 |
| C4 | application.ex: KillSwitch not consulted; CommandBus consults on opt | command_bus.ex:953 |
| C5 | Closure doc: DO authority only in CommandBus + BrceAnchor | section 14.4 |
| C6 | Closure doc "Raise: value-checking" vs presence-only survivors | section 19 |
| C7 | `PlanningIR` default admitted vs `Selected => AdmittedPlan` | planning_ir.ex:18 |
| C8 | Private-term minting non-injective, un-admitted (strict needs admitted) | conformance run |
| C9 | `terminal_standing` never yields `:failed`, a Standing terminal | refusal.ex:922 |
| C10 | Profile id `v26.9.20` vs package `26.9.28` | extension.ex:43 |
| C11 | Two "canonical" digest schemes: `Determinism` vs raw `Command.fingerprint` | 10.6 |
| C12 | Lease: `LeaseGuard` integer epoch vs `Gall.WorkLease` URN epoch; doc names one | 19 |
| C13 | "Authority concentrated in CommandBus + BrceAnchor" vs public Dispatcher/opts | 14.4 |

Detail for C2: `SA2A.StateMachine` maps the SHACL dialect to `structurally_valid` and SHEX
to `semantically_valid`; `Standing` requires `shex_result` for `structurally_valid` and
`shacl_report` for `semantically_valid`.

## 28. Gaps

- ABSENT: stale-lease/stale-checkpoint refusal against a clock or epoch.
- ABSENT: receipt field for git SHA / exact subject commit.
- ABSENT: retry or recovery field on `Refusal`.
- ABSENT: pinning of `SpgConformance.corpus_digest`.
- ABSENT: bus-level broker liveness re-check (revocation at DO time).
- UNSUPPORTED: resume of a killed worker (snapshot model exists, not wired).
- TEST_ONLY: `Gall.Closure` pipeline, OcelProjection, TelemetryEnvelope, `Standing.transition`
  chain, `Select`/`Construct`, `AdmissionPipeline.admit/2` (reached only from tests and
  courts).
- ABSENT: refusal test for caller-supplied `resolved_skill`; MAC on the outbox journal;
  principal scoping of continuation replan.
- No falsifier: forged in-process BrceAnchor (durable-forgery variant, brce_gate7:208 appends
  first); Memory TTL re-execution; digest parity across
  runtimes; dynamic refusal codes.

## 29. Open questions

1. Which standing axis, if any, is the protocol's single authoritative standing?
2. Should `:declared` actuation dedup be the default given the fresh-command_id gap?
3. Should the bus consult the broker at DO time, or is admission-time enough?
4. Is the SHACL/ShEx stage order in `Standing` or in `SA2A.StateMachine` intended?
5. Do the `Gall.Closure` laws belong before DO, and if so where is the hook?
6. Should refusals of receiptless pre-claim failures leave durable evidence?
7. What is the canonical digest for a language-neutral fingerprint?
8. Is `:observe` truly outside the receipt boundary for read-only skills with side
   effects such as telemetry or on_cancel-like hooks?

## 30. Security and authority considerations

- Consequence classification is compile-time; a misdeclared `:observe` on a non-mutating
  generic action bypasses authority and receipt. The floor only covers create/update/destroy.
- BrceAnchor is a process-dictionary token; any code in the BEAM can `put/1` a hand-built
  pending anchor. The module says so.
- Unkeyed receipt binding does not resist a writer who recomputes digests.
- Bus admission uses expiry but not broker state (14.1).
- Legacy authority policy is refused only in strict/prod posture (14.2).
- Push webhooks (`Req.post`) are outside the receipt boundary; `WebhookPolicy` and IP
  pinning apply (`push_delivery.ex:125`, `webhook_policy.ex`).
- `Authority.grant_token_id/2` is an unkeyed sha256 of `{subject.value, capability_id}`.
- LLM output and model-sourced authority are candidates only:
  `model_authority_refused` (bus) and `LLMOutput => Candidate` HOLDS in the conformance run.

## 31. Backward compatibility

The code preserves compatibility deliberately in these places: legacy release mode returns
`{:ok, nil}`; `candidate_digest` reads the legacy GALL-029 metadata spelling with the same
fingerprint; fingerprints without semantic subject or SPG identity keep `nil` tokens;
`Receipt` literals with defaults still compile; `:declared` actuation mode preserves
pre-S55 behavior; stores without optional callbacks behave as before.
Fingerprint changes (adding identity tokens) would break persisted-receipt replay; the code
guards against this in `command_fingerprint_determinism_test.exs:114`.

## 32. Evidence appendix

Legend. `L:` = `lib/ash_a2a/`. `T:` = `test/`. Class: I = IMPLEMENTED,
P = PARTIALLY_IMPLEMENTED, T = TEST_ONLY, D = DOCUMENTED_ONLY, C = CONTRADICTED,
A = ABSENT. "none" = no falsifier located.

| Claim | Classification | Implementation evidence | Test/falsifier | Notes |
|---|---|---|---|---|
| Consequence from definition | I | L:skill.ex, transformers | T:consequence_floor | compile |
| Unknown consequence refused | I | L:command_bus.ex:941 | T:agent_command_bus:338 | no rcpt |
| Authority match on DO | I | L:command_bus.ex:930 | T:authority_non_impl | subj+cap+exp |
| Model authority refused | I | L:command_bus.ex:925 | T:authority_non_impl | conf. HOLDS |
| Bus checks broker liveness | A | L:authority.ex admits? | none | expiry only |
| Portable authority verdict | I | L:authority/decision.ex | T:..non_implications:305 | Node host |
| Command replay by id+fp | I | L:receipt_store/memory.ex | T:ash_a2a/command_bus_test:23 | |
| Same id, other fp refused | I | L:receipt_store/memory.ex:186 | T:command_bus_test:46 | |
| Actuation dedup default | P | L:command_bus.ex:628 | T:actuation_identity:163 | :declared |
| Actuation dedup strict | I | L:actuation.ex | T:actuation_identity:126 | |
| Pending anchor before DO | I | L:command_bus.ex:728 | T:command_bus_outbox_chicago | |
| Anchor forgery refused | A | L:brce_anchor.ex:133 | brce_gate7:208 | no outbox check |
| BRCE refuses anchorless DO | I | L:brce_anchor.ex:90 | T:chicago/brce_gate7:192 | |
| Execution fence | I | L:command_bus.ex:452 | T:command_bus_hardening:276 | if store exports |
| DO deadline unknown outcome | I | L:command_bus.ex:404 | T:command_bus_hardening:192 | |
| Postcondition contradiction | I | L:postcondition.ex | T:chicago/postcondition_test | |
| Receipt binding chain | I | L:receipt/binding.ex | T:chicago/receipt_binding_* | unkeyed dflt |
| Receipt has exact git SHA | A | L:receipt.ex fields | none | StandingRef only |
| Memory TTL blocks re-exec | A | L:receipt_store/memory.ex:327 | none | ttl default nil |
| Claim lease 300s | I | L:receipt_store/claim_lease.ex | T:receipt_store/hardening | no anchor |
| Worker death resumes | A | L:transport/runtime.ex:288 | T:ash_a2a_task_failed_state | fails task |
| ExecutionSnapshot wired | T | L:execution_snapshot.ex | T:execution_snapshot | no lib caller |
| TaskStore.Ekv wired | T | L:task_store/ekv.ex | T:ash_a2a/task_store_ekv | no lib caller |
| Standing chain at runtime | T | L:semantic/standing.ex:319 | T:semantic_standing | courts only |
| Ledger vs transition agree | C | L:standing.ex:1130 | none | bulk edge |
| Stage/dialect map agrees | C | L:sa2a/state_machine.ex:103 | none | swapped |
| AdmissionPipeline at runtime | T | L:semantic/admission_pipeline.ex:314 | T:semantic_adm_pl | |
| Select/Construct at runtime | T | L:semantic/select.ex, construct.ex | T:chicago/plan_gates | |
| Refusal 18 classes | I | L:semantic/refusal.ex:102 | T:semantic_refusal | |
| Refusal totality | P | L:semantic/refusal.ex:813 | T:semantic_refusal:139 | regex scan |
| Refusal retry field | A | L:semantic/refusal.ex:118 | none | |
| Release strict default | P | L:capability_release.ex:289 | T:capability_release:58 | legacy dflt |
| Preflight 14 fields | I | L:planning/preflight.ex:122 | WholePlanPreflight court | opt-in |
| Work order 11 fields | I | L:hilt/work_order.ex:79 | T:hilt_work_order_execution | |
| Provider-independent identity | I | L:execution_identity.ex | T:command_bus_test:253 | |
| Kill switch on A2A path | A | L:command_bus.ex:953, agent.ex:727 | T:command_bus_kill | opt-in |
| PlanningIR admit gate | A | L:semantic/planning_ir.ex:18 | none | default admitted |
| SPG id flows to OCEL | I | L:spg_identity.ex | T:ash_a2a_spg_identity:6 | attributes |
| SPG corpus independent | P | L:spg_conformance.ex:105 | T:spg_conformance_runtime | self-check |
| Gall.Closure at runtime | T | L:gall/closure/pipeline.ex | T:gall/closure/* | Receipt alias |
| GallClosure survivors | T | L:gall_closure/*.ex | T:gall_closure/* | presence only |
| LeaseGuard compares epoch | C | L:gall_closure/lease_guard.ex | T:gall_closure/lease | type only |
| Determinism collision | C | L:gall/closure/determinism.ex:10 | probe run, no test | executed |
| field/2 false fallthrough | P | L:gall/closure/scope_policy.ex:29 | none | no live site |
| resolved_skill checked | A | L:dispatcher.ex:352 | none | forged :observe |
| Outbox journal authenticated | A | L:receipt_outbox.ex:437 | none | no MAC |
| Continuation replan scoped | A | L:agent.ex:463 | none | any principal |
| Observe floor covers :read | A | L:transformers/build_capability_index.ex:93 | none | 3 types |
| Two lease shapes agree | C | L:gall_closure/lease_guard.ex | none | int vs URN |
| Two OCEL builders agree | A | L:semantic_projection.ex:82 | none | shapes differ |
| Conformance level | C | mix ash_a2a.verify_conformance | command run | level none |

## Implementation-derived generalizations (candidates, not normative)

1. **Fence before effect**: any consequence boundary is a durable pending record plus a
   single-use token, with unknown-outcome as a first-class terminal (not retry).
2. **Two-index dedup**: request identity (id + fingerprint) and effect identity
   (capability, principal, subject, input, external token) as separate claims.
3. **Refusal as classified total function** with an honest `unknown` bucket.
4. **Portable decision function pinned by shared vectors** (the Authority.Decision pattern)
   as the way to make a BEAM law testable in a second runtime.
5. **Evidence identity vs authority split**: SemanticSubject, SpgIdentity, closure digests,
   construction receipts all carry `authority: none` by construction.
6. **Standing as derived** rather than stored: the fourth axis (`Receipt.standing`) is the
   only one set by the runtime.
7. **One digest per identity** would remove the encoding table in 10.1 (candidate only).

## ERRC

| Action | Item |
|---|---|
| Eliminate | Presence-as-admission in `SemanticWork.*` and `GallClosure.*` survivors |
| Eliminate | Second stage-to-dialect mapping (C2); stale comments C3, C4 |
| Eliminate | 20 copies of `field/2`; parallel authority markers (`:none` vs `"NONE"`) |
| Reduce | Four standing axes to the axes a runtime path actually drives |
| Reduce | Digest encodings (10.1) toward language-neutral forms |
| Reduce | Library-only semantic code whose only callers are courts |
| Raise | Falsifiers for: forged anchor, TTL re-execution, dynamic refusal codes |
| Raise | Default of actuation dedup and strict release mode (open question 2) |
| Raise | Independent evaluator for SPG predicates; pin `corpus_digest` |
| Create | Bus-level broker liveness check candidate |
| Create | Receipt subject-SHA field candidate |
| Create | Test pinning `Determinism.canonical` collisions and `field/2 false` |

## See Also

- `docs/rfc/RFC-SA2A-001-v26.9.16.md`: semantic architecture (intended)
- `docs/rfc/RFC-SA2A-002-v26.9.16.md`: Chicago qualification standard (intended)
- `docs/explanation/closure-implementations.md`: closure ownership claims (see C5, C6)
- `docs/explanation/architecture.md`: architecture overview
- `docs/explanation/chicago-conformance-court.md`: court mechanics
