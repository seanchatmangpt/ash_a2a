# Documentation Audit -- v26.9.21

Internal session record (not shipped in the Hex package, not wired into
ExDoc extras -- same convention as `docs/archive/session-history/
MANUFACTURING_RECEIPT.md`). Prepared ahead of external review of the
v26.9.21 state. Every tracked `.md`/`.cff` file in the repo was inventoried;
this table is the accounting of what was done to each category and why.

## Archived (moved via `git mv`, history preserved)

### `docs/archive/jira/` -- 34 files, RFC-style scratch tickets/ARD-PRD pairs

| Original path | New path | Reason |
| --- | --- | --- |
| `docs/jira/GALL-CHECKPOINT-command-authority-003*.md` (3 files) | `docs/archive/jira/GALL-CHECKPOINT-command-authority-003*.md` | Cross-cutting milestone checkpoint/vision doc, not user documentation |
| `docs/jira/v26.9.11/*.md` (5 files) | `docs/archive/jira/v26.9.11/*.md` | Working specs/bug tickets from a closed milestone |
| `docs/jira/v26.9.14/{ERRC_TRACKER,RELEASE_RECEIPT}.md` | `docs/archive/jira/v26.9.14/...` | Tracker + release receipt from a closed milestone |
| `docs/jira/v26.9.15/{A2A-2601,A2A-2602,A2A-2603,README}.md` | `docs/archive/jira/v26.9.15/...` | Ticket specs from a closed milestone |
| `docs/jira/v26.9.16/*.md` (12 files) | `docs/archive/jira/v26.9.16/...` | Tickets, PRFAQ, RFC-closure notes from a closed milestone |
| `docs/jira/v26.9.17/{cleanup-merge-plan,production-readiness-docs-pass}.md` | `docs/archive/jira/v26.9.17/...` | Process/merge planning docs from a closed milestone |
| `docs/jira/v26.9.18/*.md` (6 files, GALL-003/029/030 ARD/PRD pairs) | `docs/archive/jira/v26.9.18/...` | Architecture/product req docs from a closed milestone; content is already reflected in `docs/reference/index.md`'s new GALL section |

### `docs/archive/reports/` -- 10 files, point-in-time evidence

| Original path | New path | Reason |
| --- | --- | --- |
| `docs/explanation/chicago-benchmark-report.md` | `docs/archive/reports/chicago-benchmark-report.md` | Measured evidence, not a guide |
| `docs/explanation/v26.9.17-stress-report.md` | `docs/archive/reports/v26.9.17-stress-report.md` | Version-pinned stress evidence |
| `docs/explanation/v26.9.17-hardening-audit.md` | `docs/archive/reports/v26.9.17-hardening-audit.md` | Version-pinned audit evidence |
| `docs/explanation/v26.9.17-commandbus-scale.md` | `docs/archive/reports/v26.9.17-commandbus-scale.md` | Version-pinned scale evidence; cited from `lib/ash_a2a/command_bus.ex` and a stress test -- citations updated |
| `docs/explanation/sa2a-v26-9-17-capability-coverage-sweep.md` | `docs/archive/reports/sa2a-v26-9-17-capability-coverage-sweep.md` | Version-pinned coverage evidence |
| `docs/explanation/sa2a-v26-9-17-hddl-reachability-analysis.md` | `docs/archive/reports/sa2a-v26-9-17-hddl-reachability-analysis.md` | Version-pinned reachability evidence |
| `docs/explanation/partisan-integration-investigation.md` | `docs/archive/reports/partisan-integration-investigation.md` | One-off spike/investigation note, not a standing explanation; cited from a test -- citation updated |
| `docs/AIRGAP_READINESS_REPORT.md` | `docs/archive/reports/AIRGAP_READINESS_REPORT.md` | Point-in-time security-posture snapshot (2026-09-15, kind-cluster scope, explicitly not an ATO); cited from `k8s/README.md`, `SECURITY.md` -- citations updated |
| `docs/ENTERPRISE_READINESS_REPORT.md` | `docs/archive/reports/ENTERPRISE_READINESS_REPORT.md` | Same as above |
| `docs/SSP_CONTROL_APPENDIX.md` | `docs/archive/reports/SSP_CONTROL_APPENDIX.md` | Same as above |

### `docs/archive/session-history/` -- 15 files

| Original path | New path | Reason |
| --- | --- | --- |
| `MANUFACTURING_RECEIPT.md` | `docs/archive/session-history/MANUFACTURING_RECEIPT.md` | One-off session/build receipt |
| `litho.docs/**` (14 files) | `docs/archive/session-history/litho.docs/**` | Internal session-generated deep-exploration essays, already labeled "internal session history" in README |

## Kept in place (durable, not point-in-time)

| Path | Reason |
| --- | --- |
| `docs/explanation/chicago-conformance-court.md` | Standing explanation of what the RFC-SA2A-002 conformance court is, not a dated snapshot |
| `docs/rfc/RFC-SA2A-001-v26.9.16.md`, `docs/rfc/RFC-SA2A-002-v26.9.16.md` | Versioned specs by design (Proposed Standard status); already excluded from the Hex package |
| `docs/PHOENIX_RUNTIME_PRIOR_ART_AUDIT.md` | Already a public "Project" ExDoc extra; content still holds |
| `research/`, `k8s/README.md`, `priv/*/README.md` | Out of scope for this pass; `research/` already excluded from the Hex package |

## Updated (real content changes)

| Path | Change |
| --- | --- |
| `docs/reference/index.md` | Added a "GALL structured-work-fabric & receipt courts" section documenting 9 modules that landed in v26.9.20 (`AshA2A.Gall.{Capability,Checkpoint,CommandReceipt,EvidenceReceipt,Fields,Message,ProcessIntervention,WorkLease}`, `AshA2A.Reconciliation.MapeK`) but were missing from the module-status table; found via a `defmodule` grep over `lib/` cross-checked against the existing tables. Updated the "re-verified at v26.9.17" line to v26.9.21. |
| `docs/reference/a2a-spec-version-mapping.md` | Was an orphan: on disk, shipped in the Hex tarball (whole `docs/reference/` dir ships), but not wired into ExDoc's `docs()` extras or linked from README. Added to both. |
| `docs/how-to/test-your-ash_a2a-app.md` | "Known flakiness" section named a stale v26.9.17 flake set (`:hddl_solve_error`, `:eaddrinuse`); replaced with the actually-observed current flakes (`BoundsExhaustionTest`, `CancelInflightTest`), sourced from this session's own full-suite runs, not assumed. |
| `README.md` | "Internal evidence and reports" section rewritten to point at the three `docs/archive/` subfolders instead of enumerating flat paths; added the `a2a-spec-version-mapping.md` Reference bullet. |
| `mix.exs` | Added `docs/reference/a2a-spec-version-mapping.md` to `docs()` extras; updated the `package()` comment to name `docs/archive` (was `docs/jira`, `litho.docs`) as an internal, non-shipped tree. |
| `CHANGELOG.md` | Added a "### Documentation" subsection under the existing `[26.9.21]` heading recording this pass. No version bump -- this prepares v26.9.21 for review, it doesn't cut a new version. |
| `lib/ash_a2a/command_bus.ex`, `lib/ash_a2a/agent.ex` | Moduledoc citation paths updated to the new `docs/archive/...` locations. Prose only, no logic changes. |
| `test/ash_a2a_partisan_integration_test.exs`, `test/ash_a2a_agent_semantic_router_wiring_test.exs`, `test/ash_a2a/chicago/stress/commandbus_tail_latency_tripwire_test.exs` | Same -- moduledoc/comment/error-message string citation paths updated. Confirmed none of these strings are asserted-on (no file-existence check depends on them); full suite reran green. |
| `docs/how-to/authenticate-agent-requests.md`, `docs/how-to/verify-authority-on-async-paths.md` | Citation paths to moved reports updated. |
| `k8s/README.md`, `SECURITY.md` | Citation paths to `AIRGAP_READINESS_REPORT.md`/`ENTERPRISE_READINESS_REPORT.md` updated. |

## Verification

- `grep` for every old archived path across `lib/`, `test/`, `README.md`,
  `SECURITY.md`, `k8s/`, `mix.exs`, and the active `docs/` tree (excluding
  `docs/archive/` itself and historical `CHANGELOG.md` entries, which are
  not edited on principle): zero dangling references.
- `mix format --check-formatted`, `mix compile --warnings-as-errors`: clean.
- `mix test --max-cases 6`: full suite rerun green (see CHANGELOG for the
  exact pass count) to confirm the moduledoc/comment edits in `command_bus.ex`/
  `agent.ex`/the three test files didn't break anything.
- `git status`/`git log --stat`: every archived file shows as a rename, not
  a delete+add.
