# Wave 2 Backlog And Lane Contract

Standing: UNVERIFIED

Subject: ash_a2a working tree (base 68a8bd5e, uncommitted) and beam4pm working tree
(base 674a316b, uncommitted). Source: 18 Phase-1 Explore reports (14 ash_a2a, 4 beam4pm),
static reads only; every row below is UNVERIFIED until its lane gate runs.

Dropped (premise rot / LOW doc drift / not ours): pure line-length drift, ggen_igniter pin,
PDF tracking decision (user's), beam4pm 8 SHA_DRIFT + 25 UNADMITTED files (other people's
dirty work; BLOCKED, owner decision), beam4pm GenericAction vocabulary (needs ontology design;
BLOCKED), gall/DfCM/Ocel2 orphan wiring (design decisions; recorded as OPEN, not built).

## Lane contract (every lane)

- Owned files only (below). Another lane's file needs a minimal-unblock disclosed in BOTH receipts.
- Never run git state commands. Never `git stash`. No worktrees.
- Per-lane build lease: `MIX_ENV=test MIX_BUILD_ROOT=/Users/sac/ash_a2a/_build-w2-<lane>`; delete
  that directory when done (`rm -rf`; if denied, say so in the receipt).
- Gate = the lane's named command, actual output + exit in the receipt.
- Receipt: `docs/jira/v26.11.10/w2/<lane>.md`, H1, then `Standing: <ALIVE|PARTIAL_ALIVE|PASS|BLOCKED|UNVERIFIED|PARTIAL>`
  on line 3, then Subject (files touched), Commands + exits, Disclosures, Not done.
- Chicago style: real collaborators, no mock libraries; no new sleeps (bounded deadline polls).
- Compile-freeze SLA ~10 minutes: a lane breaking the shared compile must fix/revert quickly.

## ash_a2a lanes

| lane | owned files | items | gate |
|---|---|---|---|
| a-proto | lib/ash_a2a/protocol/agent.ex, protocol/task/orphan_sweep.ex, protocol/task_store.ex | `tasks/list` always `{:error,:unsupported}` (agent.ex:458-469): implement owner-scoped listing via task store or stop claiming it; orphan sweep returns loud error + telemetry when store lacks `list_all` | `mix test test/ash_a2a/protocol test/ash_a2a/a2a_transport test/ash_a2a_v1_bidi_test.exs` |
| a-receipt | lib/ash_a2a/receipt_outbox.ex, receipt/evidence_chain.ex, receipt_store.ex, consequence_kernel/closure/receipt_digest.ex, consequence_kernel/prepared_effect_store/journal.ex, evidence/class.ex, authority.ex(term_to_binary site only), replan/replay_key.ex | non-deterministic `term_to_binary` (add `[:deterministic]`, keep decode back-compat); journal key floor 32 bytes shared with durable_file; loud warning when outbox dir defaults to tmp / no integrity key / nil prepared_journal_dir outside dev+test | tests for receipt*, consequence_kernel prepared_effect, plus a new determinism test |
| a-authority | lib/ash_a2a/dispatcher.ex, authority/**, info.ex, verify.ex, security/** | dispatcher must read `AshA2A.Info.authority_gate/1` + hooks (pre/post_dispatch) or the DSL must stop advertising them; `AllowAll` runtime release guard; `:unpinned`-style switches. Must NOT touch protocol/agent.ex | `mix test test/ash_a2a/authority test/dsl_mapping_card_test.exs` + a dispatch test that sets gate+hook and asserts both fire |
| a-copilot | lib/ash_a2a/copilot/**, strain/bridge.ex, twin/ceo.ex, ingress/channel.ex | F8/A3: strain key bound to attested actor, refuse mismatched `coordinator_id`, no auto-register of unknown id; observable skip when mechanical prior/authority_source absent; CEO default-prior reconciliation | `mix test test/copilot* test/twin* test/attention* test/ingress* test/ash_a2a/copilot*` + forged-coordinator test |
| a-semantic | lib/ash_a2a/semantic/falsifier_suite.ex, falsifier_fixtures.ex, vocabulary.ex, graph_law_bridge.ex | SPARQL `:ask` evaluation through AshGraphLaw with structural evaluator as differential oracle (fail closed on empty verdicts); single `sa:` namespace constant. PARTIAL honest landing allowed | `mix test test/ash_a2a/semantic*` (+ differential test) |
| a-graphlaw | lib/ash_a2a/graph_law/**, graphlaw/**, graphlaw.ex, semantic/hook_reactor/engine.ex, semantic/root_manifest/engine_probe.ex | one wasm path resolver (single env var, existence-checked); `:unpinned` refused outside test env; hook_reactor engine returns real `wasm_digest`, `close/1` honest | `mix test test/ash_a2a/graph_law* test/ash_a2a/semantic/engine* test/semantic_engine_test.exs` |
| a-replan | lib/ash_a2a/planning.ex, replan/port/ferroplan.ex, replan/port/beam4pm.ex, replan/provider_registry.ex, callback_registry.ex, consequence_kernel/closure/exceptions.ex | `plan_with_ferroplan` + `Port.Ferroplan` over HTTP A2A (`:beam4pm_url`/`:ferroplan_url`), no in-process `BeamPM.*` reference in lib/; typed `:ferroplan_unavailable`; prune closure exceptions; boot-time warning when beam4pm selected with no URL | `mix test test/ash_a2a/replan test/ash_a2a/planning* test/ash_a2a/c1_closure` + `grep -rn 'BeamPM\.' lib` empty |
| a-telemetry | lib/ash_a2a/telemetry/ocel_forwarder.ex, config/runtime.exs, application.ex(ocel warn only) | OCEL forwarder boot warning when no `:ocel_ingest_url`; `ASH_A2A_OCEL_INGEST_URL` runtime hook; drop-counter on catch-alls | `mix test test/ash_a2a_telemetry_ocel* test/ash_a2a/telemetry` |
| a-ci | .github/workflows/ci.yml, scripts/sleep_gate.sh, scripts/beam4pm_up.sh, scripts/beam4pm_down.sh | sleep-gate job unconditional (no `if [ -f ]` green-skip); gate fails on rg error / missing lib root and scans sa2a_crypto/lib; beam4pm_up records PID, fails fast on dead BEAM, verifies card body | `bash scripts/sleep_gate.sh` exit semantics; `bash -n`; `BEAM4PM_DIR=/nonexistent scripts/beam4pm_up.sh` exits 2 |
| a-chicago | lib/ash_a2a/chicago/**, telemetry/siem.ex, runtime_identity/execution.ex, test/runtime_hardening_test.exs | the 14 unannotated `Process.sleep` lib sites: poll observable or annotate SCHEDULING/POLL-STEP; widen allowed classes in sleep_gate only via a-ci's file (coordinate: lane a-chicago uses SCHEDULING/POLL-STEP only) | `bash scripts/sleep_gate.sh` exit 0 + chicago tests |
| a-tests | test/ash_a2a_pplan_notify_test.exs, test/ash_a2a/telemetry/obs_hardening_test.exs, test/support/c2_harness/faults.ex, test/telemetry_bridge/pplan_hazard_bridge_test.exs, test/ash_a2a_skip_reason_discipline_test.exs, test/support/wo_checkin_sim_fixture.ex | negative-wait sleeps -> barrier/sentinel; c2 faults poll; silent boolean skips -> reason strings + extend discipline test to catch `skip: true`/`skip: not`; quoted-atom warning debt | `mix test` on those files, repeated with 3 seeds; `mix compile --warnings-as-errors` |
| a-docs | docs/reference/a2a-v1-conformance.md, docs/jira/v26.11.10/OPEN-ITEMS.md, docs/reference/generated/reference.md (regenerate only), priv/sa2a_conformance/MANIFEST.json | court count 34->35; OPEN-ITEMS rows L17-L19 from receipts/lane reports; denials.n3 manifest entry regenerated by its tool (not hand-edited); reference.md regenerated | the corpus manifest verify + doc_quality court; `mix test test/ash_a2a/docs*` |

## beam4pm lanes (REPO /Users/sac/beam4pm; per-lane `MIX_BUILD_ROOT=/Users/sac/beam4pm/_build-w2-<lane>`)

| lane | owned files | items | gate |
|---|---|---|---|
| b-app | lib/beam4pm_a2a_router.ex, lib/beam4pm_a2a_agent.ex, lib/beam4pm_application.ex, config/test.exs, config/config.exs, mix.exs | router base_url from runtime (not compile_env port 0/4211); remove hex `a2a` dep + `use A2A.Agent` bootstrap branch; stale A2A.* comments; named boot warning per skipped engine. Any edit to an admitted file requires re-admission: ONLY via ontology.ttl sha edit + `rm -f ggen.lock && ggen sync run --skip-ea-admission` by the coordinator, not the lane | `MIX_ENV=test mix compile`; the b-tests HTTP test |
| b-tests | test/beam4pm_a2a_router_http_test.exs (new), test/beam4pm_dfcm_sa2a_validate_card_test.exs, qualification/sa2a_e2e_qualification.exs (comment), .github/workflows/beam4pm-ci.yml | HTTP test through `BeamPM.A2ARouter` (card + message/send round trip + 404); card fixture regenerated from the live router (drop 1194/protocolVersion assumptions); CI checks out sibling ash_a2a or sets ASH_A2A_PATH; new test files must be admitted by the coordinator after landing | `MIX_ENV=test mix test test/beam4pm_a2a_router_http_test.exs test/beam4pm_dfcm_sa2a_validate_card_test.exs` |

## Coordinator-owned (not lanes)

Authorship re-admission + ggen sync (beam4pm), explicit-path staging, integration ladder, cleanup.

## BLOCKED / OPEN (not built)

- beam4pm: 8 SHA_DRIFT + 25 UNADMITTED authorship findings (others' dirty files); `bpm:GenericAction`
  vocabulary for replan/plan skills; 119 debt rows expire 2026-12-31; ggen needs `ea.graph.json` or
  `--skip-ea-admission` (docs say neither).
- ash_a2a: CastleOcel/gall telemetry envelope/DfCM.Court/Evidence.Ocel2/Actuation.Engine/AuthZEN.Absorption
  have no lib/ caller (wire-or-delete design decision); 3 `sa:` namespaces beyond a-semantic's slice;
  tracked LaTeX artifacts (user decision); CI soft gates (`continue-on-error`) promotion.
