# Closure implementations: one owner per law

Three overlapping implementations of the GALL closure laws exist under `lib/ash_a2a/`.
This page records which module owns which law, based on what the code does today.
The redundant modules have since been removed (see "Deduplication" below); this page now describes what remains.

## Standing and authority

Everything in these three trees is evidence or candidate only. None of it grants authority.
Their outputs are `{:ok, map}` / `{:error, refusal}` values that describe a candidate; they do not
act. Authority to DO exists only in `AshA2A.CommandBus` and the `AshA2A.BrceAnchor` sole-DO fence.
A guard passing, an envelope binding, or a receipt projection is never a DO grant. The
`authority: "NONE"` and `standing: "CANDIDATE"` values these modules emit are markers,
not permissions.

## Deduplication (done)

`AshA2A.Gall.Closure.*` (27 modules, `lib/ash_a2a/gall/closure/`) is the canonical
implementation and the only tree consumed by other code (`AshA2A.Gall.Receipt` aliases
`Gall.Closure.Determinism`). Every `GallClosure.*` and `SemanticWork.*` module that had a
canonical equivalent there was removed together with its tests: 26 of 30 `GallClosure`
modules and 21 of 30 `SemanticWork` modules. Nothing outside those trees referenced them.
Removed modules remain in git history.

Kept because no canonical owner exists yet:

| Module | Why kept |
|---|---|
| `GallClosure.LeaseGuard` | `Gall.Closure` has no lease law. Value-checking (non-negative integer epoch). |
| `GallClosure.CheckpointBinding`, `FindingBinding`, `InterventionClosure` | No `Gall.Closure` counterpart. |
| `SemanticWork.Lease` | Lease identity envelope (`expires_at` validated). |
| `SemanticWork.Admission`, `Candidate`, `Checkpoint`, `GraphIdentity`, `Projection`, `Provider`, `WorkOrder` | No `Gall.Closure` counterpart. |
| `SemanticWork.Envelope` | Shared `fetch/2` used by the kept envelopes; replaces the per-module `req!/2` copies. |

## ERRC

| | Item |
|---|---|
| **Eliminate** | Presence-as-admission: `admit/1` returning `{:ok, ...}` because a key is non-blank (for example `remaining_do: "x"` passes `InterventionBudget`). Also the per-module copy-pasted `req!/2` helpers (about 80 `req!` occurrences across `semantic_work/` and `gall_closure/`). |
| **Reduce** | Three parallel implementations to one canonical owner per law (table below). Reduction is by declaring ownership first; no module is deleted or renamed in this step. |
| **Raise** | Value-checking guards. A law-bearing guard must check the value, not the key: authority ceiling must be `"NONE"`, do-count exactly 1, remaining budget exactly 1, and so on. Scope, lease and version checks must compare against the expected value. |
| **Create** | This ownership map and the follow-up plan below. |

## Ownership by law

Each law below is owned by the listed `Gall.Closure` module. The former `GallClosure.*` /
`SemanticWork.*` equivalents were removed (except where noted in the kept table above).

| Law | Owner |
|---|---|
| Authority ceiling | `Gall.Closure.AuthorityBinding` (the `"NONE"` marker is set by `Gall.Closure.Migration`) |
| One DO / intervention budget | `Gall.Closure.BudgetPolicy` (must equal 1) |
| Lease | `GallClosure.LeaseGuard` (no `Gall.Closure` owner) |
| Scope | `Gall.Closure.ScopePolicy` |
| Migration / version | `Gall.Closure.Migration` with `Compatibility` |
| Exact subject | `Gall.Closure.ExactSubject`, `SemanticSubjectPolicy` |
| Receipt binding | `Gall.Closure.ReceiptBinding`, `AshA2A.Gall.Receipt` |
| Replay | `Gall.Closure.ReplayGuard` |
| OCEL | `Gall.Closure.OcelProjection` |
| Provenance | `Gall.Closure.Provenance` |
| Falsifier | `Gall.Closure.Falsifier` |
| Idempotency | `Gall.Closure.IdempotencyPolicy` |
| Postcondition | `Gall.Closure.PostconditionPolicy` |
| Capability / command binding | `Gall.Closure.CapabilityPolicy`, `CommandBinding` |
| Determinism (digest) | `Gall.Closure.Determinism` |
| Refusal / recovery | `Gall.Closure.Refusal`, `Recovery` |
| Audit / planning / simulation consumers | `Gall.Closure.AuditConsumer`, `PlanningConsumer`, `SimulationConsumer` |
| Evidence / vocabulary / producer policy | `Gall.Closure.EvidencePolicy`, `VocabularyPolicy`, `ProducerPolicy` |
| Telemetry | `Gall.Closure.TelemetryEnvelope` |
| Composition | `Gall.Closure.Pipeline` (`admit/2`, `preflight/3`) |

## Follow-up

Decide canonical owners for the kept modules, or move them under `Gall.Closure`, as they are reached.
