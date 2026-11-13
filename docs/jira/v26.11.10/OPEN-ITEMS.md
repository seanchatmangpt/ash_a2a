# OPEN-ITEMS v26.11.10

Standing: UNVERIFIED

Index of the registered backlog from the 2026-11-10 audit session. Lane IDs L01-L16 are
session-context IDs; this file materializes them. Scopes are intents, not completed work.

## Lanes

| Lane | Owned area | Scope |
|---|---|---|
| L01 | `lib/ash_a2a/attestation/`, `lib/ash_a2a/ingress/` | attestation gate/key/allowlist and ingress channel hardening |
| L02 | `lib/ash_a2a/actuation/` | actuation engine/adapter/ticket hardening; tests `test/actuation/` |
| L03 | `lib/ash_a2a/copilot/`, `lib/ash_a2a/attention/` | copilot pipeline and attention broker hardening |
| L04 | `lib/ash_a2a/authority/` | authority broker/pep/graph_pin/source hardening |
| L05 | `lib/ash_a2a/twin/`, strain modules | twin lease and strain hardening |
| L06 | `lib/ash_a2a/providers/pplan*.ex`, `lib/ash_a2a/execution/` | pplan runtime and execution (flame/pplan) |
| L07 | `lib/ash_a2a/task_store/`, `lib/ash_a2a/protocol/agent*` | task store and agent state |
| L08 | `lib/ash_a2a/telemetry_bridge/`, OCEL modules | telemetry and OCEL |
| L09 | `lib/` cross-cutting | sleeps, swallowed errors, `String.to_atom`, bidirectional queue |
| L10 | `lib/ash_a2a/protocol/` | protocol codec |
| L11 | DSL, `lib/ash_a2a/capability_index*` | DSL and capability index |
| L12 | `lib/ash_a2a/semantic/` | semantic/graphlaw: differential test + migration plan to AshGraphLaw |
| L13 | `test/ash_a2a_v1_*` | conformance courts and test sleeps |
| L14 | `mix.exs`, CI, `.gitignore` | mix, CI, gitignore |
| L15 | `docs/reference\|explanation\|how-to\|tutorials` | docs |
| L16 | `docs/jira/**`, `docs/sjira/**`, `docs/assurance/**`, `docs/dfcm/**`, `receipts/*.md` | receipts |
| L17 | ash_a2a Wave 2 lanes a-proto..a-docs | 11 lanes per `WAVE2-BACKLOG.md`; receipts in `w2/<lane>.md` |
| L18 | beam4pm Wave 2 lanes b-app, b-tests | router runtime base_url, HTTP router test; source `beam4pm-dogfood-receipt.md` |
| L19 | beam4pm BLOCKED set | 8 SHA_DRIFT + 25 UNADMITTED authorship findings, `bpm:GenericAction` vocabulary, ea.graph.json / `--skip-ea-admission` docs gap; owner decision |

## Open decisions

- ash_graphlaw dependency: path vs Hex.
- CastleOcel production caller (none registered).
- Namespace reconciliation: three `sa:` namespaces.
- Wire PEP into the `Actuation.Engine` default.
- Orphaned `:working` task recovery needs a hook in `lib/ash_a2a/transport/runtime.ex`.
- Untested C2/ConsequenceKernel modules (~70 modules): new test files needed.
- Tracked LaTeX/PDF artifacts need coordinator `git rm --cached`.

## See Also

`docs/jira/v26.11.4/receipts/a21-wip-finish.md` · `docs/sjira/v26.10.8/STANDING-RECEIPT.md`
