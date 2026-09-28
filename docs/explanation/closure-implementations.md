# Closure implementations: one owner per law

Three overlapping implementations of the GALL closure laws exist under `lib/ash_a2a/`.
This page records which module owns which law, based on what the code does today.
Nothing is deleted or moved by this document.

## Standing and authority

Everything in these three trees is evidence or candidate only. None of it grants authority.
Their outputs are `{:ok, map}` / `{:error, refusal}` values that describe a candidate; they do not
act. Authority to DO exists only in `AshA2A.CommandBus` and the `AshA2A.BrceAnchor` sole-DO fence.
A guard passing, an envelope binding, or a receipt projection is never a DO grant. The
`authority: "NONE"` and `standing: "CANDIDATE"` values these modules emit are markers,
not permissions.

## The three trees

| Tree | Files | Shape | State |
|---|---|---|---|
| `AshA2A.Gall.Closure.*` (`lib/ash_a2a/gall/closure/`) | 27 | Policy modules with typed `{:refused_gall, module, reason}` refusals, composed by `Pipeline` (`admit/2`, `preflight/3`, ...) | Formatted, main line. The only tree consumed by other code: `AshA2A.Gall.Receipt` aliases `Gall.Closure.Determinism` for receipt digests. |
| `AshA2A.GallClosure.*` (`lib/ash_a2a/gall_closure/`) | 30 | Tiny `admit/1` guards on one key each | Being hardened (work in progress). At the last committed state, `AuthorityCeiling`, `OneDoGate`, `InterventionBudget`, `LeaseGuard`, `MigrationGuard` and `ScopeGuard` still only test that the key is not `nil`, `false` or `""`. |
| `AshA2A.SemanticWork.*` (`lib/ash_a2a/semantic_work/`) | 30 | `bind/1` identity envelopes, each with its own copy-pasted `req!/2` helper | Being refactored onto a shared `AshA2A.SemanticWork.Envelope` (work in progress; the committed modules still carry their own `req!/2`). |

Only `Gall.Receipt` references these trees from outside them. `gall_closure/` and `semantic_work/`
have no non-test consumers today, so nothing depends on them being kept as they are.

## ERRC

| | Item |
|---|---|
| **Eliminate** | Presence-as-admission: `admit/1` returning `{:ok, ...}` because a key is non-blank (for example `remaining_do: "x"` passes `InterventionBudget`). Also the per-module copy-pasted `req!/2` helpers (about 80 `req!` occurrences across `semantic_work/` and `gall_closure/`). |
| **Reduce** | Three parallel implementations to one canonical owner per law (table below). Reduction is by declaring ownership first; no module is deleted or renamed in this step. |
| **Raise** | Value-checking guards. A law-bearing guard must check the value, not the key: authority ceiling must be `"NONE"`, do-count exactly 1, remaining budget exactly 1, and so on. Scope, lease and version checks must compare against the expected value. |
| **Create** | This ownership map and the follow-up plan below. |

## Ownership by law

"Canonical" is the module that today carries the real check or the most complete behaviour.
Where no tree has a value-checking implementation, that is stated instead of guessed.

| Law | Canonical owner | Redundant equivalents |
|---|---|---|
| Authority ceiling | `Gall.Closure.AuthorityBinding` (subject, capability, scope and budget compared to the command); the `"NONE"` marker is set by `Gall.Closure.Migration` | `GallClosure.AuthorityCeiling` (presence only), `SemanticWork.AuthorityCeiling` (envelope with fixed `authority: "NONE"`) |
| One DO / one consequence | `Gall.Closure.BudgetPolicy` (must equal 1) | `GallClosure.OneDoGate` (presence only), `GallClosure.CommandBusBoundary`, `SemanticWork.CommandBoundary` |
| Intervention budget | `Gall.Closure.BudgetPolicy` | `GallClosure.InterventionBudget` (presence only), `SemanticWork.Budget` |
| Lease | No value-checking owner. Neither `Gall.Closure` nor `Gall.Receipt` handles leases. | `GallClosure.LeaseGuard` (presence only, so it becomes the owner once hardened), `SemanticWork.Lease` (identity envelope) |
| Scope | `Gall.Closure.ScopePolicy` (input digest and target compared to the command) | `GallClosure.ScopeGuard` (presence only), `SemanticWork.Scope` |
| Migration / version | `Gall.Closure.Migration` (`to_v1`) with `Gall.Closure.Compatibility` (fail-closed gate) | `GallClosure.MigrationGuard`, `GallClosure.CompatibilityGuard`, `SemanticWork.Migration`, `SemanticWork.Compatibility` |
| Exact subject | `Gall.Closure.ExactSubject`, plus `SemanticSubjectPolicy` for semantic subjects | `GallClosure.ExactSubject`, `SemanticWork.ExactSubject`, `SemanticWork.SourceIdentity` |
| Receipt binding | `Gall.Closure.ReceiptBinding` (receipt bound to the exact command and candidate), with `AshA2A.Gall.Receipt` for the receipt projection | `GallClosure.ReceiptBinding`, `SemanticWork.Receipt` |
| Replay | `Gall.Closure.ReplayGuard` (classifies exact replay, no second consequence) | `GallClosure.ReplayBinding`, `SemanticWork.Replay` (`consequence_budget: 0`) |
| OCEL | `Gall.Closure.OcelProjection` | `GallClosure.OcelIdentity`, `SemanticWork.OcelBinding` |
| Provenance | `Gall.Closure.Provenance` | `GallClosure.ProvenanceBinding`, `SemanticWork.Provenance` |
| Falsifier | `Gall.Closure.Falsifier` (bounded negative controls) | `GallClosure.Falsifier`, `SemanticWork.Falsifier` |
| Idempotency | `Gall.Closure.IdempotencyPolicy` | `GallClosure.Idempotency`, `SemanticWork.Idempotency` |
| Postcondition | `Gall.Closure.PostconditionPolicy` | `GallClosure.Postcondition`, `SemanticWork.Postcondition` |
| Capability / command binding | `Gall.Closure.CapabilityPolicy`, `CommandBinding` | `GallClosure.CommandIdentity`, `SemanticWork.Capability` |
| Determinism (digest) | `Gall.Closure.Determinism` (used by `Gall.Receipt`) | `GallClosure.Determinism`, `SemanticWork.Determinism` |
| Refusal / recovery | `Gall.Closure.Refusal`, `Recovery` | `GallClosure.TypedRefusal`, `RecoveryRoute`, `SemanticWork.Refusal`, `Recovery` |
| Audit, planning, simulation consumers | `Gall.Closure.AuditConsumer`, `PlanningConsumer`, `SimulationConsumer` | `GallClosure.AuditConsumer`, `PrimaryConsumer`, `SimulationConsumer`, `SemanticWork.Consumer` |
| Evidence / vocabulary / producer policy | `Gall.Closure.EvidencePolicy`, `VocabularyPolicy`, `ProducerPolicy` | `GallClosure.EvidenceBinding`, `PolicyGuard`, `StandingGuard`, `SemanticWork.Policy`, `Standing` |
| Telemetry | `Gall.Closure.TelemetryEnvelope` | `GallClosure.ObservationGuard` |
| Composition | `Gall.Closure.Pipeline` (`admit/2`, `preflight/3`) | none |

`SemanticWork.*` modules with no closure counterpart (`Admission`, `Candidate`, `Checkpoint`,
`GraphIdentity`, `Projection`, `Provider`, `WorkOrder`) and `GallClosure.*` modules likewise
(`CheckpointBinding`, `FindingBinding`, `InterventionClosure`) are not covered by this map.
Decide their owner when each is reached.

## Follow-up plan

1. Finish the in-progress `SemanticWork.Envelope` extraction so the `req!/2` copies go away. Keep the
   `{:refused_missing_identity, key}` and `:refused_invalid_envelope` refusals unchanged.
2. Finish value-checking hardening of the six `GallClosure` guards listed above, with
   negative tests per guard. `LeaseGuard` needs an expected-value source, since `Gall.Closure`
   has no lease law to defer to.
3. Have `GallClosure` and `SemanticWork` modules delegate to the canonical owner where one is
   named above, or document them as thin envelopes over it.
4. Only after that, and after confirming no callers remain, propose removal or merge. Removal is
   a separate change and is not part of this one.
