# Moat Claims Audit

Lane M20 (competitive-moat claims audit) over the one canonical checkout
`/Users/sac/ash_a2a` (HEAD `fbea16b`, tree dirty, 286 paths), plus
`/Users/sac/ggen-marketplace` and `/Users/sac/ash_pplan` (both READ-ONLY).
No git operations; the only write is this file. Compile gate used
`MIX_BUILD_ROOT=_build-laneM20`. Evidence labels: OBSERVED = read from the
tree by this lane at file:line or command output; RECEIPT = committed
receipt/doc restating a run (`docs/jira/v26.10.3-v1-protocol/MANUFACTURING_RECEIPT.md`,
`docs/reference/a2a-v1-conformance.md`); SESSION = run testimony with no
committed artifact.

Verdicts: PROVEN (court/test/artifact cited), PARTIAL (what exists +
what is missing), ASPIRATIONAL (no backing evidence). Claim text is the
operator's positioning; verdicts audit the claim as stated.

## Contents

- Competitive-moat claims (15)
- Concede-claims
- Structural claims (theory layer)
- Falsifiers and open items
- See Also

## Competitive-moat claims

Verdict summary:

| # | Claim (short) | Verdict |
|---|---|---|
| 1 | ~50 adversarial courts + fuzzing/spec-corpus/proto-fidelity/SPARQL mutation | PROVEN |
| 2 | TCK sensitivity (X6's control) | PARTIAL |
| 3 | Two-port gates + Grant.authorize/3 + proof-vs-authority | PROVEN |
| 4 | Monotonic delegation (FederatedDelegation court) | PROVEN |
| 5 | WASM-anchored Merkle receipts via WASM engine | PARTIAL |
| 6 | SEC-01 ownership + recursive credential stripping | PARTIAL |
| 7 | REJECTED-as-admission-refusal lifecycle | PROVEN |
| 8 | 306-pack catalog, 290 ALIVE, anti-vacuity on mutation | PROVEN |
| 9 | Self-hosting ggen.toml, byte-reproducible sync | PARTIAL |
| 10 | AAIF alignment (A2A+MCP+Goose+AgentGateway, one pack) | PROVEN |
| 11 | Three-repo coherence (documented seams) | NARRATIVE |
| 12 | Ed25519 passports (ZD1, in flight) | PARTIAL (pending-lane) |
| 13 | ELA-ITL envelope defense (aaif gates) | PARTIAL |
| 14 | OCEL2 process mining in autofde-lab | OUT OF CONTRACT |
| 15 | TCK 69.2% point-in-time JSONRPC verdict | PROVEN |

Tally: 9 PROVEN, 5 PARTIAL, 1 NARRATIVE, 1 OUT OF CONTRACT.

### 1. ~50 adversarial courts — PROVEN

- `ls lib/ash_a2a/chicago/courts/ | wc -l` = 50 court modules (OBSERVED).
- Wire-property fuzzing: `test/ash_a2a_v1_wire_properties_test.exs`
  (StreamData property suite over the real codec and JSON-RPC layer,
  4 properties incl. idempotence) + `test/ash_a2a_property_fuzz_test.exs`
  (real StreamData, no doubles).
- Spec corpus: `test/ash_a2a_v1_spec_corpus_test.exs` over curated
  `priv/a2a_v1_spec_corpus/` (includes the canonical `a2a.proto`).
- Proto fidelity: `test/ash_a2a_v1_proto_fidelity_test.exs`.
- Mutation-tested SPARQL gates:
  `lib/ash_a2a/chicago/mutation/catalog.ex:157-176` — mutations target
  the `:sparql_falsifiers` admission stage with named killers
  (`SA2A-SPARQL`, `CHI-ADM`), driven by `mix ash_a2a.chicago.mutate`
  and `lib/ash_a2a/chicago/mutation.ex`.
- Caveat: run-level counts (187 falsifiers / 134 killed / 0 survived)
  are RECEIPT-level, pinned to pre-removal subject `501a4fdb`
  (`dep:a2a 0.2.0`) — stale relative to HEAD; re-mint before quoting
  for the current subject.

### 2. TCK sensitivity — PARTIAL

- In-repo sensitivity control is real: pins the three TCK fixes
  (`-32009` version gate, resubscribe `-32001`, card §8.6.1 cache
  headers) in `test/ash_a2a/transport/transport_court_test.exs`
  (23 tests + 11 doctests, exit 0 — RECEIPT).
- Breaking a fix re-flags in-repo, not in the external TCK.
- Missing: any artifact of the TCK itself re-flagging a broken fix.
  Zero tree hits for `X6` (docs/, test/, swarm/); raw TCK reports are
  session-ephemeral (`/tmp/z19/tck_reports_ash_a2a_final`, disclosed in
  the conformance doc). X6 lane receipt is SESSION testimony only.

### 3. Two-port gates + Grant.authorize/3 + proof-vs-authority — PROVEN

- `lib/ash_a2a/authority/two_port_gate.ex` + court
  `lib/ash_a2a/chicago/courts/two_port_gate.ex`.
- `Grant.authorize/3` at `lib/ash_a2a/authority/grant.ex:115`;
  fail-closed broker contract at
  `lib/ash_a2a/authority/broker.ex:30,103`.
- Courts: `test/ash_a2a_authority_capability_grant_test.exs`,
  `test/ash_a2a_authority_confused_deputy_test.exs`,
  `test/ash_a2a_authority_decision_failclosed_test.exs`.
- Proof-vs-authority: `test/ash_a2a_authority_non_implications_test.exs:234`
  — "Proof NOT=> Authority: a cryptographic proof this test
  independently VERIFIES does not admit the command".

### 4. Monotonic delegation — PROVEN (as refusal-of-escalation)

- `lib/ash_a2a/chicago/courts/federated_delegation.ex`: positive leg
  `:98` — principal needs real grants at BOTH peers; peer B's own
  CommandBus independently admits and attributes to the originating
  principal.
- Negative leg `:122` — principal granted ONLY on peer A's
  `delegate_write` is refused; bypass path refused `:143`.
- Containment is pinned via the negative court; no literal
  `A_sub ⊆ A_parent` subset assertion exists in the module — restate
  the claim phrasing accordingly.

### 5. WASM-anchored Merkle receipts — PARTIAL

Two real surfaces; the coupled claim overstates:

- Passport Merkle: RFC 6962-style domain-separated SHA-256 + detached
  JWS (HS256), verified in-BEAM (`lib/ash_a2a/passport.ex:10-22`,
  `lib/ash_a2a/passport/merkle.ex`) — not WASM-validated.
- Deterministic WASM engine: vendored
  `priv/graphlaw/praxis_graphlaw.wasm`, MANIFEST sha256-pinned,
  executed by court-owned `WasmexHost`/`WasmexSession` (Wasmtime),
  courted by `lib/ash_a2a/chicago/courts/graphlaw_engine.ex`
  (SA2A-ENGINE).
- Receipt binding: ETF-at-rest + `AshA2A.Receipt.Binding.verify/2`,
  courted by `lib/ash_a2a/chicago/courts/receipt_binding.ex`
  (tampered evidence never retains standing).
- Missing: any artifact showing Merkle receipt validation INSIDE the
  WASM engine — the conjunction is not evidenced.

### 6. SEC-01 ownership + recursive credential stripping — PARTIAL

- SEC-01 owner scoping PROVEN: `lib/ash_a2a/a2a_transport/ownership.ex`
  (foreign task indistinguishable from missing, `-32001`);
  `lib/ash_a2a/transport/principal.ex`;
  `lib/ash_a2a/transport/runtime.ex:15-52`.
- Courts: `test/ash_a2a/a2a_transport/ownership_test.exs`;
  `test/ash_a2a/transport/transport_court_test.exs:285` (two real
  bearer principals over real HTTP).
- "Recursive" stripping NOT evidenced: `strip_task/strip_wire/
  sanitize_params` are single-level `Map.drop` of 3 metadata keys
  (`ownership.ex:55-84`) — no recursion into nested structures.
  "Cryptographic" applies to the verified bearer identity, not the
  stripping.

### 7. REJECTED-as-admission-refusal — PROVEN

- `test/ash_a2a_v1_rejected_state_test.exs` — authority-gate refusal
  lands terminal `:rejected` (`:83-101`), genuinely non-cancelable
  (`:94-98`), persisted in real agent state (`:100`), wire-encodes
  `TASK_STATE_REJECTED` (`:104-108`).
- Replaces the vocabulary-only v22 court (header `:5-11`); row 26
  flipped CONFORMANT via executed court (`_RESOLUTIONS.md` §7.5);
  v1 batch ran exit 0 (RECEIPT, 70 tests).

### 8. 306-pack catalog, 290 ALIVE — PROVEN

- `/Users/sac/ggen-marketplace/qualification/baseline.json`:
  `packs` = 306; `counts` = {ALIVE 290, REFUSED 6, SKIPPED 1,
  WARN 9}; `ggen_version` "ggen 26.9.28" (OBSERVED).
- Per-pack evidence entries cite m14 dogfood FALSIFIER_PASS renders
  and m18 `qualify_packs` runs with per-file sha256s (e.g.
  a2a-conformance-pack consequence_sha256 `121ec5a5...`; report
  `/tmp/m18_full.json` — session-ephemeral).
- Anti-vacuity witnessed firing: the m14 TEMPLATE_INERT finding
  recorded in a2a-durability-pack evidence; gates rewritten as
  violation-shaped queries in response.
- Observation: `packs/` on disk = 304 vs 306 in baseline — 2-pack
  drift, unexplained; recorded.

### 9. Self-hosting ggen.toml — PARTIAL

- Landed: `ggen.toml` (54 lines), `ggen.lock`,
  `generated/ash/semantic_map.ttl` + `semantic_map_a2a.ttl`;
  commit `02745ef` on main (`_RESOLUTIONS.md` §7.4).
- Byte-reproducibility ("sync green twice, third run unchanged,
  sha256 byte-identical") is commit-message testimony — no committed
  run artifact. Replay documented in the ggen.toml header.
  Not re-run in this lane (tree READ-ONLY except this report).

### 10. AAIF alignment — PROVEN

- `/Users/sac/ggen-marketplace/packs/aaif-vanilla-pack/ontology.ttl:8` —
  "Exhaustive formal representation of upstream AAIF open standards:
  A2A, MCP, Agentgateway, Agent Router, Goose, and AGENTS.md".
- Goose classes `:174-184`; 15 violation-shaped gates incl.
  `gates/070_envelope_defense_policy.rq`; pack status ALIVE in
  `qualification/baseline.json` (no evidence list — see #13).

### 11. Three-repo coherence — NARRATIVE

- `docs/explanation/pplan-seams.md` documents the
  ash_a2a<->ash_pplan division (two disjoint seams, no-delegation
  rationale, own staleness falsifier at `:64`) — two of three repos.
- autofde-lab appears only in archive/RFC cross-references
  (`docs/rfc/RFC-SA2A-006-existing-substrate-map-v26.9.28.md`).
- No cross-repo court exists: sibling-repo courts were excluded at
  run ("11 of 11 sibling repos absent" — RECEIPT, Transport
  Failures).

### 12. Ed25519 passports (ZD1) — PARTIAL (pending-lane, as stated)

- Landed under lane ZD1 is an HMAC-SHA256 JWS passport:
  `test/ash_a2a_passport_test.exs:3` ("real HMAC-SHA256 JWS");
  Merkle root + HS256 detached JWS
  (`lib/ash_a2a/passport.ex:19-22`).
- Ed25519 exists on a DIFFERENT surface: SA2A conformance checks
  `lib/ash_a2a/sa2a/conformance/checks/c2.ex:136,178,189` (real
  Ed25519 verify, tamper/garbage refusal, ML-DSA fail-closed) and
  `c3.ex:26,141` (custodian-distinct quorum).
- Asymmetric-curve passport signing is not in the tree; the claim's
  "in flight / pending-lane" framing is accurate.

### 13. ELA-ITL envelope defense — PARTIAL

- Present: `ontology.ttl:260,282` (Envelope-Layer Defense, "ELA-ITL
  isomorphic model: arXiv:2610.00392"); `pack.toml:8`; executable
  gate `gates/070_envelope_defense_policy.rq` (violation-shaped
  SELECT over `aaif:hasEnvelopeDefense`).
- Missing: the pack's baseline.json entry is
  `{"status": "ALIVE"}` with NO evidence list (unlike
  a2a-conformance-pack's 5 entries); no run artifact of the gate
  firing. Gate exists; firing unwitnessed in-tree.

### 14. OCEL2 process mining in autofde-lab — OUT OF CONTRACT

- `/Users/sac/autofde-lab` exists but is outside this lane's
  three-repo contract (ash_a2a + ggen-marketplace + ash_pplan,
  READ-ONLY); not entered.
- In-contract traces only: `ash_pplan/lib/ash_pplan/standing.ex:140,
  180,490` (`ocel2_sha256` evidence binding); autofde-* packs in the
  marketplace catalog. No verdict possible inside lane scope.

### 15. TCK 69.2% point-in-time — PROVEN (as scoped)

- `docs/reference/a2a-v1-conformance.md:132` — 69.2% (MUST 70.4%,
  SHOULD 42.9%, MAY 100%); matrix `:117-120` (agent_card 10/10;
  jsonrpc 68 pass / 5 fail / 15 skip of 88; grpc 0/72 skipped;
  http_json 3/83).
- The doc's own "What is not claimed" section (`:155-161`) bounds it:
  compatibility run, not certification. Raw reports
  `/tmp/z19/tck_reports_ash_a2a_final` are session-ephemeral,
  disclosed in the doc itself.

## Concede-claims

### gRPC/HTTP+JSON TCK residuals — CONFIRMED CONCESSION; "3/14" not on disk

- TCK matrix (`a2a-v1-conformance.md:117-120`): grpc 0/72 (all
  skipped), http_json 3 pass / 83 total / 80 skipped. No "14"
  denominator appears in the TCK section.
- G-P status: LANDED — `test/ash_a2a_v1_httpjson_tck_closures_test.exs:46`
  ("Lane G-P court: the A2A v1.0 HTTP+JSON/REST binding's TCK-closure
  surface").
- G-Q status: NO TREE ARTIFACT — zero hits over md/test/docs.
- Open items at `_RESOLUTIONS.md` §7.6 (declare GRPC/HTTPJSON
  interfaces, re-run the TCK per binding).

### Conventions copyable without rigor — CONFIRMED CONCESSION (one counterweight)

- Conventions/architecture prose is copyable markdown with no
  copy-protection court.
- Counterweight on the doc-defaults surface:
  `test/ash_a2a/docs_truth_test.exs` (8 tests) courts documented
  configuration defaults against executed code with an execution
  oracle — doc DEFAULTS are not copyable-without-rigor; conventions
  prose is.

## Structural claims (theory layer)

Verdict summary:

| # | Claim | Verdict |
|---|---|---|
| 1 | Courts-as-admission-function (A=mu(O*) operationalized) | PINNED |
| 2 | Rice's theorem -> sampled falsification discipline | PINNED (as practice) |
| 3 | Little's Law in the transport | PINNED |
| 4 | Gall's Law marketplace flywheel | PINNED |
| 5 | Chesterton's Fence encoded | PINNED (one sub-citation unverified) |
| 6 | BEAM/OTP substrate isolation | PINNED |
| 7 | Conway three-repo coherence | NARRATIVE |
| 8 | "Years and a philosophy change" projection | NARRATIVE / UNFALSIFIABLE |

### 1. Courts-as-admission-function — PINNED

- Fenced-ingress evidence:
  `lib/ash_a2a/chicago/courts/unknown.ex:401-419` —
  `fenced_candidate` + `admit_for_do_refused` asserted together
  (`LlmBoundary.fence/1` == :ok AND admit-for-DO refused).
- Zach kill-court: `test/ash_a2a_zach_courts_test.exs` — non-vacuity
  (invalid skill must fail compilation) + ToA2AError totality over
  globbed real `deps/ash` error modules; 7 tests, exit 0 (RECEIPT,
  OBSERVED in F6).
- Additional refusal branches: `lib/ash_a2a/chicago/courts/brce.ex:211-260`
  (refuse_unanchored_execution, planner authority ceiling).

### 2. Rice -> sampled falsification — PINNED (as practice)

- The theorem is narrative; the discipline is executable:
  `lib/ash_a2a/chicago/mutation.ex` +
  `lib/ash_a2a/chicago/mutation/catalog.ex:157-176` (SPARQL-stage
  mutations with named killers) + `mix ash_a2a.chicago.mutate`.
- Non-vacuity kill-court `test/ash_a2a_zach_courts_test.exs:50-53`.
- Self-bounding statement `docs/reference/a2a-v1-conformance.md:155-161`
  ("What is not claimed").

### 3. Little's Law in the transport — PINNED

- `lib/ash_a2a/transport/runtime.ex:46-52,73` — `max_in_flight`
  (default 256) refuses `:server_busy`; optional per-principal token
  bucket `rate_limit: {count, per_ms}`.
- Court: `test/ash_a2a/transport/transport_court_test.exs:480`
  asserts `{"code" => -32000, "data" => %{"reason" => "server_busy"}}`;
  `test/ash_a2a_v1_error_registry_test.exs:56,502` (refused before
  task creation; 503 mapping).

### 4. Gall's Law flywheel — PINNED

- Run-derived baseline
  `/Users/sac/ggen-marketplace/qualification/baseline.json`
  (306 packs, m14/m18 evidence strings, ggen 26.9.28).
- P5 self-host commit `02745ef` on main with `ggen.lock` +
  `generated/ash/` projections (`_RESOLUTIONS.md` §7.4).

### 5. Chesterton's Fence encoded — PINNED (one sub-citation unverified)

- REJECTED-as-admission-refusal court
  `test/ash_a2a_v1_rejected_state_test.exs` (moat claim 7).
- Refusal branches `lib/ash_a2a/chicago/courts/brce.ex:211-359`.
- Conformance rows flip only via executed courts, not hand-edits
  (`_RESOLUTIONS.md` §7.5; `mix ash_a2a.v1_conformance_report`
  FAIL verdict for a missing court file, `:81`).
- Gap: the "oclnr HMAC-approved cleanup" sub-citation has ZERO tree
  artifact (session-level osx-clnr) — UNVERIFIED on disk.

### 6. BEAM/OTP substrate isolation — PINNED

- `test/ash_a2a_command_bus_crash_window_chicago_test.exs:9` — a
  separate OS BEAM performs one real HTTP consequence and is killed.
- Kill-leg root cause + watcher fix `_RESOLUTIONS.md` §3
  (clause-order finding; `transport/runtime.ex:291-302` re-delivers
  a worker exit as the typed `internal_error` envelope).
- Companion courts: `test/ash_a2a_command_bus_outbox_chicago_test.exs`.

### 7. Conway three-repo coherence — NARRATIVE

- Same evidence as moat claim 11: `docs/explanation/pplan-seams.md`
  documents the ash_a2a<->ash_pplan division only; no cross-repo
  court; sibling courts excluded at run.

### 8. "Years and a philosophy change" — NARRATIVE / UNFALSIFIABLE

- Zero tree hits for the phrase over both repos; no observable, no
  falsifier. State as rhetoric, not claim.

## Falsifiers and open items

1. Compile gate for this lane (OBSERVED, 2026-10-04 23:07-23:14 PDT):
   `MIX_BUILD_ROOT=_build-laneM20 mix compile` — exit 0 (after a
   transient first-pass `CompileError` in `lib/ash_a2a/trace.ex` that
   a plain re-run did not reproduce).
   `MIX_BUILD_ROOT=_build-laneM20 mix compile --warnings-as-errors` —
   exit 1: 8 warnings, of which `AshA2A.Trace.export/3` and
   `AshA2A.Eval.Suite.load/1` are undefined because
   `lib/ash_a2a/trace.ex` and the Suite module are NOT in the tree
   while `lib/ash_a2a/trace/plug.ex:65` and eval files reference them
   (`trace/` mtimes 23:07-23:09 — mid-write by a concurrent lane on
   the shared checkout; this lane's only write is this report). Gate
   is RED for reasons outside this audit's scope; re-run when the
   trace/eval lane lands.
2. `preferredTransport` codec gap and dead `stringify/1` clause —
   carried open from the F6 receipt; unchanged by this audit.
3. Stale standing receipt (pinned `501a4fdb`, `dep:a2a 0.2.0`) — the
   187/134/0 mutation figures qualify a pre-removal subject; re-mint
   required before quoting them for HEAD.
4. baseline.json says 306 packs; `packs/` on disk = 304 — reconcile.
5. aaif-vanilla-pack gate firings unwitnessed (claim 13) — mint a run
   artifact for `gates/070_envelope_defense_policy.rq`.
6. X6 (TCK re-flag control) and G-Q have no tree artifacts — mint or
   drop from the moat narrative.
7. Credential stripping is single-level, not recursive (claim 6) —
   either recurse into nested metadata or restate the claim.

## See Also

- `docs/jira/v26.10.3-v1-protocol/MANUFACTURING_RECEIPT.md` (F6 receipt)
- `docs/jira/v26.10.3-v1-protocol/_RESOLUTIONS.md` (integration ledger)
- `docs/reference/a2a-v1-conformance.md` (TCK matrix + statement)
- `/Users/sac/ggen-marketplace/qualification/baseline.json` (packs)
