# Manufacturing Receipt — ash_a2a v26.10.4

**Subject**: `/Users/sac/ash_a2a` local `main` @ `395b39b9` (v26.10.4, mix.exs bumped this
receipt-cycle). Artifact-free publication on origin:
`snapshot/v26.10.4-enterprise` and `snapshot/v26.10.4-enterprise-2` (squashed, parented on
`origin/main`, all `_build*`/`examples/a2a_demo/{deps,_build*}`/`.oclnr-cache` stripped;
oversize-blob check clean).

## Gate verdicts (all executed at/near final HEAD, 2026-10-05)

| Gate | Verdict | Evidence |
|---|---|---|
| `mix compile --warnings-as-errors` | **GREEN** (exit 0) | this receipt-cycle, build `_build-coord` |
| Perimeter grep (external `A2A.*` refs in lib/test/swarm) | **GREEN** (0 real hits; 8 SA2A/ontology false-positives) | Z13 rehearsal + re-run this cycle |
| `mix test` full fast lane | **3349 tests, 0 failures** (113 doctests, 51 properties) | G-O full-suite run; re-run at final HEAD in flight this cycle |
| `mix test --include serial --cover` | **78.77% vs 75% floor — FLOOR_MET** | COV-1 (976 modules, 41,781 relevant lines; serial included) |
| swarm subproject `(cd swarm && mix test)` | **29 tests, 0 failures** | Z13 rehearsal |
| Installer scratch (`mix ash_a2a.install` fresh consumer) | **GREEN** — no `{:a2a, ...}` dep written, scratch compiles | Z13 |
| `mix.lock` contains no `"a2a"` | **GREEN** (grep count 0) | this receipt-cycle |
| Dialyzer | **66 findings, all documented** (down from 86; 16 target classes eliminated in DZ-2, 17 in DZ-3; remaining are pattern-match triage class + intentional-raise pairs + MapSet-opaque false-positive family) | DZ-2/DZ-3 runs |
| Per-declared-transport TCK (A2A v1.0) | **JSONRPC MUST 0 failures; HTTP+JSON per-requirement 0; gRPC MUST matrix 10/0 over real HTTP/2** — echo-SUT residue class closed | G-F/G-P/X15 courts; docs/reference/a2a-v1-conformance.md |
| PRD §5 SLO budgets | **7/0 ×3** — all latency budgets measured against real modules | V4-19 court `test/ash_a2a/enterprise/slo_budget_test.exs` |
| DX docs-truth | 6 findings fixed, corroboration 61/0 | DX-1/DX-2 |

## FR-01..06 (PRD v26.10.4) — court-pinned standing

| FR | Surface | Court(s) | Standing |
|---|---|---|---|
| FR-01.1 | SPIFFE WorkloadWatcher + TrustBundle (UDS streaming, pre-expiry rotation, fail-closed) | `test/ash_a2a/enterprise/spiffe_workload_watcher_test.exs` 5/0 ×4 | ALIVE |
| FR-01.2 | SVID validator plug (real X.509 path validation, typed 401/503 refusals) | `test/ash_a2a/enterprise/svid_validator_test.exs` 19/0 | ALIVE |
| FR-01.3 | AuthZEN Client/DecisionPool + Absorption real-PDP path | `test/ash_a2a/enterprise/authzen_client_test.exs` 11/0 ×3 (+25/0 regression) | ALIVE |
| FR-01.4 | Monotonic grant narrowing (`C_child ⊆ C_parent`) | `test/ash_a2a/enterprise/monotonic_grant_test.exs` (323 lines) + DecisionGate courts | ALIVE |
| FR-02.1/02.2 | DLPFilter (PAN/SSN/key/PHI, HMAC-AES-GCM pseudonyms, bidirectional plug) | `test/ash_a2a/enterprise/dlp_filter_test.exs` 14/0; 64KB redact median 1632µs (budget 2500µs) | ALIVE |
| FR-02.3 | DataResidency fail-closed | `test/ash_a2a/enterprise/data_residency_test.exs` 18/0 (real Pipeline + Bandit; mutation-witnessed) | ALIVE |
| FR-03 | CMEK envelope (AES-256-GCM DEK/KEK wrap, rotation-without-rewrite, KMS-down fail-closed) + supervised KeyManager | `test/ash_a2a/enterprise/cmek_test.exs` 13/0; `key_manager_supervisor_test.exs` (18/0 combined) | ALIVE |
| FR-04 | Two-phase DRAIN (cordon→drain→exit; checkpoint + cross-node rehydrate) | `test/ash_a2a/enterprise/drain_test.exs` 4/0 ×3 — real OS `kill -TERM`, cordon 12-14ms (budget 3s), exit 4.1s (budget 28s), zero-drop rehydrate with 4-step cross-node ledger | ALIVE |
| FR-05 | FinOps BudgetStore/Enforcer + dispatcher pre-actuation gate + chargeback telemetry | `finops_test.exs` 13/0 ×3 + `finops_dispatch_wiring_test.exs` (16/0 combined; mutation-pinned) | ALIVE |
| FR-06 | Affidavit WASM (ML-DSA-65 KAT, byte-identical replay, tamper-evident BLAKE3 chain) + OCEL v2 + SIEM adapters (Splunk/Chronicle/Datadog, real mTLS) + pool/broadcaster | `affidavit_ocel2_test.exs` 7/0 (WASM-real); `siem_test.exs` 19/0; `affidavit_pool_test.exs`+`ocel_broadcaster_test.exs` 7/0 | ALIVE |
| ARD §2 | Ordered enterprise pipeline (all 10 stages, fail-closed, fixed order) | `test/ash_a2a/enterprise/pipeline_test.exs` 20/0 (real mTLS e2e) | ALIVE |

Plus the A2A v1.0 protocol surface (codec/plugs/clients/gRPC/transports, Passport, TRACE,
BiDi, elicitation, eval harness, livebooks, check gate, CI) — landed earlier in the wave
with its own courts, summarized in `docs/reference/a2a-v1-conformance.md` and the v1.1
readiness matrix.

## Transport failures (typed, honest)

- **origin/main publication**: BLOCKED — commit `7713b42e` carries a 207MB
  `examples/a2a_demo/_build-laneGE/...so` blob; GitHub pre-receive refuses (GH001).
  Remediation is force-push-class (history rewrite of `7713b42e..HEAD`, or re-land tracked
  content on a fresh branch); **awaiting explicit operator order** per the NEVER-FORCE
  standing rule. Crash protection is complete via the two snapshot branches.
- **Pre-existing ash_pplan suite drift** (7 deterministic failures): CLOSED by ERRC-P
  (`~/ash_pplan@5f10c97`, 55/0, incl. a real sync.sh provenance-sha bug).

## Typed residuals (documented, not hidden)

- Dialyzer 66 findings (classes above); coverage sub-floor modules enumerated in COV-1's
  report (C2/Chicago harness invalidation clusters + registration-only pb modules).
- `AshA2A.FinOps.BudgetCeiling` name never landed — the PRD name maps to the landed
  `BudgetEnforcer` (documented in both moduledocs).
- ggen-marketplace integration: `~/ggen-marketplace` is owned by the concurrent sibling
  session (a2a-security-pack removed there); not touched by this wave.
- Eleven wasm-execution tests skip when `native/graphlaw_host` release binary is absent.

## Replay

```
MIX_BUILD_ROOT=_build-coord mix compile --warnings-as-errors   # exit 0
MIX_BUILD_ROOT=_build-coord mix test                            # 3349 tests, 0 failures
MIX_BUILD_ROOT=_build-coord mix test --include serial --cover   # 78.77% >= 75
(cd swarm && mix test)                                          # 29 tests, 0 failures
mix ash_a2a.v1_conformance_report                               # JSON court verdicts
```
