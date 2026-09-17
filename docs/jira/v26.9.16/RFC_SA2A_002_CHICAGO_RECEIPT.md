# RFC-SA2A-002 Chicago Conformance Court — Manufacturing Receipt

**Generated:** 2026-09-16 · **Standing:** PARTIAL_ALIVE (crown run reports **NONCONFORMANT** at `:strict`; see §6)

This receipt covers the local session that built `AshA2A.Chicago`, the
falsification-based conformance court for RFC-SA2A-002 v26.9.16
(`docs/rfc/RFC-SA2A-002-v26.9.16.md`), from its foundation commit through the
final closure and documentation commits on `main`. It follows the shape of
`docs/jira/v26.9.14/RELEASE_RECEIPT.md`. Nothing here was pushed — see §7.

## 1. Identity

| Field | Value |
|---|---|
| `repo` | `/Users/sac/ash_a2a` (`github.com/seanchatmangpt/ash_a2a`) |
| `branch` | `main` (worked on directly, no feature branch for this receipt) |
| `base_sha` | `a4a2bea346dd768682b465a0360b2a7b0edd928a` — `merge: feat/sa2a-conformance-court-v26.9.16` (2026-09-16 11:05:18 -0700), the commit `main` was at when the RFC-SA2A-002 Chicago foundation branch forked |
| `final_sha` (before this receipt commit) | `c5531249f9fd7c0f1770b681b1c4af6c3f36b4b6` — `docs: add real Chicago benchmark report (B1/B5/B9, 10 iterations)` (2026-09-16 23:40:57 -0700) |
| `commits_in_range` | 82 (`git rev-list --count a4a2bea..c553124`) |
| `merged_branches` | 28 (1 foundation + 15 wave-1 + 9 wave-2 + 3 closure — see §2) |
| `pr` | none — all work committed directly to local `main`, never pushed |

## 2. Merged branches (chronological, oldest first)

All 28 merge commits below are real ancestors of `c553124` on local `main`,
confirmed via `git log --oneline --merges c553124 --grep="sa2a-002"` plus
manual resolution of six `merge: undefined` commit subjects against their
real bodies (`git show -s --format=%B <sha>`, which names the branch even
where the one-line subject does not).

### Foundation (1)

| SHA | Branch | Adds |
|---|---|---|
| `1241a55b40711c426efb88f222db5481bf0c38fc` | `feat/sa2a-002-chicago-foundation-v26.9.16` | `AshA2A.Chicago` core: `Court` behaviour, `Falsifier` (S11), `Result` verdict algebra (S12), `Context`, `Subject` (S5), independent OCEL 2.0 `Observer`, `Query`, `Runner` (S104), `StandingReceipt` (S115) |

### Wave 1 (15)

| SHA | Branch | Adds |
|---|---|---|
| `9936e3f1465027a37f968b8cca86032dd5c9106d` | `feat/sa2a-002-ocel-observer-v26.9.16` | SA2A-OCEL-OBSERVER process-observer qualification court |
| `8f71dd0fd39da88542c648a0068933e8d5222b05` | `feat/sa2a-002-ocel-validator-v26.9.16` | independent OCEL 2.0 JSON validator + SA2A-OCEL court (21 falsifiers) |
| `8a1fad843888f572a7033881a286806c6bdb3201` | `feat/sa2a-002-identity-gate1-v26.9.16` | Gate 1 CHI-ID court, S126 runtime-identity repair |
| `2e2131e4df9c2368bb232575a57f65890b077353` | `feat/sa2a-002-fresh-consumer-gate11-v26.9.16` | Gate 11 CHI-FRESH court, `AshA2A.Chicago.FreshConsumer` |
| `f8d350f538c0f64c12c1f1c166e23779f4885a5b` | `feat/sa2a-002-hooks-cascade-v26.9.16` | knowledge-hook / reactive-cascade courts over a real bounded `HookReactor` |
| `940b4b61e9f935bf5854a813ba70ef87e7153112` | `feat/sa2a-002-logic-sparql-v26.9.16` | SA2A-LOGIC + SA2A-SPARQL courts, bounded logic-closure boundary |
| `46e522f7cfa915484e960f822508eaa4ad82f5df` | `feat/sa2a-002-shex-shacl-admission-gate2-v26.9.16` | Gate 2 executable-world, ShEx + SHACL courts |
| `1aea48eddfd51769ae410cb6644390200104a270` | `feat/sa2a-002-brce-gate7-v26.9.16` | Gate 7 CHI-BRCE court, sole-DO dispatcher fence `AshA2A.BrceAnchor` |
| `d027f4a44e1c4c9e81ac76de0b4c74d63c54208e` | `feat/sa2a-002-envelope-negotiation-transport-v26.9.16` | SA2A-ENV / SA2A-NEG / SA2A-TRANSPORT courts |
| `95dc5f3477c0a7c36f81eba050c4cf904f731ab6` | `feat/sa2a-002-authority-courts-v26.9.16` | SA2A-AUTH + SA2A-AUTH-GRANT authority courts |
| `699cae36b8689586251b8b72cb1b887ee6f1de2c` | `feat/sa2a-002-postcondition-gate8-v26.9.16` | Gate 8 CHI-POST independent postcondition court |
| `533dd14b24e0fa3d66bdba044fbc7c5e04695927` | `feat/sa2a-002-chaos-reconciliation-v26.9.16` | SA2A-CHAOS crash/reconciliation/idempotency court, B10 benchmark |
| `cf930b5759556aa964e75d48a975dae576013c6b` | `feat/sa2a-002-real-collaborators-gate3-v26.9.16` | Gate 3 real-collaborators court, AST zero-mock scan |
| `3ec84b4d5db27c63f1d17919e94e5883da3f982e` | `feat/sa2a-002-bench-harness-v26.9.16` | `AshA2A.Chicago.Courts.Benchmarks`, `mix ash_a2a.chicago.bench` |
| `0c13dc2706ef5606ebe5d0ae71a9c685a5f18eda` | `feat/sa2a-002-mutation-harness-v26.9.16` | `AshA2A.Chicago.Mutation.Catalog`, `mix ash_a2a.chicago.mutate`, SA2A-MUTATION court |

### Wave 2 (9)

| SHA | Branch (recovered from commit body; subject line reads `merge: undefined`) | Adds |
|---|---|---|
| `523e7ebcbe1bee8dd4828ecb77ce9c09825c1f31` | `feat/sa2a-002-unknown-llm-gate12-v26.9.16` | Gate 12 CHI-KNOWN, SA2A-UNKNOWN, SA2A-LLM, SA2A-MX courts (35 falsifiers) |
| `143a8914b2007e1b79a8fb11e5b36bf6ec83637b` | `feat/sa2a-002-canonical-identity-projection-v26.9.16` | SA2A-CANON, SA2A-NS, SA2A-PROJECTION, SA2A-CANONMUT courts |
| `70110db6d040863998aec2a712cf00e0f96897a9` | `feat/sa2a-002-root-manifest-meta-admission-v26.9.16` | SA2A-META, SA2A-ROOT courts, `AshA2A.Chicago.CourtManifest` |
| `6128d3289e8d7a3f24d8031447297a73527f5c5a` | `feat/sa2a-002-cross-runtime-portability-v26.9.16` | SA2A-XRUNTIME court, B7 benchmark |
| `bfeb1df8a8d1b41a812a86752bed576c2a7dfed9` | `feat/sa2a-002-autonomy-bounds-gate6-v26.9.16` | Gate 6 CHI-AUTO, SA2A-BOUNDS courts, B4 benchmark |
| `c87ec6d0fc44885c318651d2b74f1ae1878c24b7` | `feat/sa2a-002-receipt-binding-attestation-gate9-v26.9.16` | Gate 9 CHI-RECEIPT (30 falsifiers) + SA2A-ATTEST (14 falsifiers) courts |
| `01a7021dce793ec35ce05a3dc4f369558694df9b` | `feat/sa2a-002-replay-gate10-v26.9.16` | Gate 10 CHI-REPLAY court (9 falsifiers), `AshA2A.Receipt.EvidenceChain`, `AshA2A.Receipt.OfflineReplay` |
| `2a7e21ef40f870cf2b4c271db56723d7456cd672` | `feat/sa2a-002-plan-gates-4-5-v26.9.16` | Gate 4 CHI-PLAN-AUTH/SA2A-PLAN, Gate 5 CHI-PREFLIGHT courts |
| `75b95e45312fbb020fdc6ec43d6eefbb59c85a26` | `feat/sa2a-002-crown-assembly-v26.9.16` | `AshA2A.Chicago.Crown` — S31 gate coverage, S98 mandatory-corpus coverage, S145 compliance matrix, S114 package completeness, Appendix C |

### Closure (3)

| SHA | Branch | Closes |
|---|---|---|
| `bdbb2bdfbc7ca924e46466ec0fbae73be808eb31` | `feat/sa2a-002-close-auth-017-v26.9.16` | SA2A-AUTH-017 capability substitution (§4.1) |
| `5bb46ef687a4cdabefa88132d635a55a1028d4b6` | `feat/sa2a-002-close-selftest-mutation-v26.9.16` | CHI-SELFTEST-REPLAY-001 self-test vacuity (§4.11); verified SA2A-MUTATION catalog (§5.2) |
| `2e8683f877600b2ee6c0efa270822b3bb916fd3b` | `feat/sa2a-002-close-chaos-liveness-v26.9.16` | SA2A-CHAOS-019/020 claim-lease liveness (§4.10) |

Two documentation-only commits follow the last closure branch, both direct
commits to `main` (not merges): `9ef801e8b5b857796e0ca1979bee7f8a5df749af`
(CHANGELOG + `docs/explanation/chicago-conformance-court.md`) and
`c5531249f9fd7c0f1770b681b1c4af6c3f36b4b6` (real B1/B5/B9 benchmark report,
10 iterations) — this is `final_sha`.

## 3. Court, gate and falsifier counts (final state, `c553124`)

| Field | Value | Source |
|---|---|---|
| `discoverable_courts` | 42 | `CHANGELOG.md` `[Unreleased]` entry (commit `9ef801e`), written against the final merged state |
| `gates_required` / `gates_attempted` / `gates_passed` | 12 / 12 / 12 | crown run, `--profile strict --crown`, gate table (§6) |
| `falsifiers_total` | 545 | crown run `standing_receipt.json` / `crown.json` |
| `falsifiers_killed` | 399 | crown run |
| `falsifiers_survived` | 6 (all `SA2A-ENGINE-*`, `BLOCKED_ON_PRAXIS` — §5.1) | crown run |
| `falsifiers_blocked` | 2 (`SA2A-TRANSPORT-004`/`005`, environment-dependent — §5.3) | crown run; commit `e940b88` names these two ids as the "blocked/unresolved" pair reproduced identically on unmodified `HEAD` in its own before/after run |
| `falsifiers_unknown` | 0 | crown run |
| `positive_controls_passed` / `failed` | 122 / 0 | crown run |
| `measured` | 16 | crown run |
| `S98 mandatory RFC-SA2A-001 corpus` | 14 members, each resolved against a real currently-declared falsifier id via `Crown.mandatory_corpus_coverage/2` | `priv/sa2a/chicago_mandatory_corpus.json`, CHANGELOG |
| `SA2A-MUTATION catalog` | 14/14 killed, 0 survived, 0 blocked | commit `7cba4aa` real re-run after every named killer court landed on `main` |

## 4. Real defects found and fixed during this work

Every entry below is a real falsifier that SURVIVED (or a real control that
FAILED) against the actual running system before the named fix, and was
re-run KILLED/PASSED after it, per each commit's own before/after evidence.
None are described from memory — each is quoted or closely paraphrased from
the commit body that fixed it.

1. **SA2A-AUTH-017 — capability substitution across agents.**
   `AshA2A.Agent.build_command/4` authorized a dispatch using the
   caller-supplied wire skill selector (`"actuate"`) instead of the
   canonical, resource-qualified capability id
   (`AshA2A.CapabilityIndex.Compiler.capability_id/2`). A standing grant for
   one resource's skill (`Probe.actuate`) authorized the same-named skill on
   any other resource (`Vault.actuate`) — a confused-deputy vulnerability.
   Found `OPEN` at `0c3d05c` (authority-courts), fixed in `e940b88`
   (`feat/sa2a-002-close-auth-017-v26.9.16`, merged as `bdbb2bd`):
   `Agent.build_command/4` now resolves the canonical capability id via
   `AshA2A.Info.skill/2` before building the command. Before: `SA2A-DO
   NONCONFORMANT: SA2A-AUTH-017 survived`. After: `SA2A-DO PARTIAL_ALIVE:
   21/21 corroborated passes`.

2. **SA2A-TRANSPORT-004 / SA2A-AUTH-014 — JSON-RPC identity/metadata
   takeover.** An authenticated, ungranted caller set
   `params.metadata["a2a.auth"] = {"identity": <granted principal>}` on a
   real JSON-RPC request; `A2A.Plug` merges `params.metadata` over the
   verified plug metadata, and `AshA2A.Agent` accepted the string-keyed
   shape — `CommandBus` admitted and actuated on the impersonated identity.
   Found and fixed independently on two branches: `2b92652`
   (`SA2A-TRANSPORT-004`, merged as `d027f4a`) and `0c3d05c`
   (`SA2A-AUTH-014`/`015`, merged as `95dc5f3`). Fix in both:
   `AshA2A.Agent.verified_auth_identity/1` accepts only the atom-keyed shape
   `A2A.Plug.Auth` itself stores.

3. **SA2A-AUTH-GRANT-008 — EKV broker did not fail closed.** A stopped EKV
   instance raised an uncaught `ArgumentError` (`:persistent_term` readers
   erased) inside `Ekv.granted?/3`, crashing the `A2A.Agent` process instead
   of cleanly refusing the authorization check. Found and fixed in `0c3d05c`
   (merged as `95dc5f3`): the lookup now rescues to `false` (`:unavailable`
   reason), matching `grant_expires_at/3`. Before: `unknown` verdict (crash,
   not a clean refusal). After: `killed`, and `AshA2A.Chicago.Courts.GrantLifecycle`
   ("SA2A-AUTH-GRANT") added a falsifier asserting the EKV broker fails
   closed on a stopped instance and reauthorizes once restored.

4. **SPARQL Update canonical-write bypasses (SA2A-SPARQL-011/012/013/014/015/018).**
   Six distinct laundering vectors against `FalsifierSuite.check_update/2`
   (S18.4, Strict): codepoint-escaped `INSERT DATA` keyword and `DEFAULT`
   operand, `INSERT DATA`/`INSERT` templates mixing a staging `GRAPH` block
   with bare triples, a `WITH <staging>` clause exempting a later
   operation's bare template, and a triple-quoted-literal scrubber desync.
   Found and fixed in `743be72` (merged as `940b4b6`): SPARQL codepoint
   escapes are decoded first, long-string scrubber state is tracked,
   IRIREF-token-only IRI recognition is used, and each operation's
   structural template body is analyzed per-operation, with unbalanced
   requests refused. Before: `011`-`015` `FALSIFIER_SURVIVED`
   (OCEL-corroborated), `018` admitted (`:ok`) by a direct pre-fix call.
   After: all `FALSIFIER_KILLED`.

5. **Dispatcher BRCE bypass (CHI-BRCE-001/002).**
   `AshA2A.Dispatcher.dispatch/5` actuated `:change` and `:external_do`
   skills with no admission, claim, or prepared receipt anchor — an
   independent `Ash.read!` saw the row committed, and `dispatch.actuate` had
   no preceding `brce.prepare`. Standing before fix: `SA2A-DO
   NONCONFORMANT`. Found and fixed in `43c31c4` (merged as `1aea48e`):
   `AshA2A.BrceAnchor` — `CommandBus` hands the durably prepared `:pending`
   receipt to exactly one dispatch, the dispatcher takes it first
   (single-use) and refuses every non-`:observe` skill without an anchor
   bound to the same capability and consequence class, before the Ash
   action runs (code `:brce_prepared_receipt_required`). Before: `001,002
   FALSIFIER_SURVIVED`. After: `001-011 FALSIFIER_KILLED`,
   `012-015 POSITIVE_CONTROL_PASSED`, gate 7 `PASSED`.

6. **Non-independent postcondition observation (Gate 8).**
   With the observation hook removed from `CommandBus` (the closest
   executable pre-fix state of the system), a lying or divergent actuator
   could commit a `:completed` receipt on its own word — falsifiers
   `001/002/004 SURVIVED`, `005` `POSITIVE_CONTROL_FAILED`. Found and fixed
   in `bf47459` (merged as `699cae3`, Gate 8 CHI-POST court): postcondition
   verification is observed independently of the actuator's own report.
   After the fix: all killed/passed.

7. **Duplicate OCEL event ids (SA2A-OCEL-021).**
   `N` telemetry-to-OCEL mappings declared against one telemetry event
   produced `N` OCEL events sharing the same id (`"e-<seq>"`) — the
   independent validator reported `invalid(1: duplicate_event_id)`,
   standing `NONCONFORMANT`. Found and fixed in `11200a7` (merged as
   `8f71dd0`): `Observer.build_log/2` suffixes the ordinal for `N > 1`
   mappings (`"e-<seq>.<n>"`); single-mapping event ids are unchanged. A
   second branch (`9936e3f`, ocel-observer) independently fixed the same
   defect with a different mechanism (`mapped_record/5` per-mapping
   `next_seq`); on merge (`8f71dd0`) the two were reconciled and the
   ocel-observer mechanism was kept, `observer.ex` left byte-identical to
   `main`. After: `SA2A-OCEL-021 falsifier_killed`, all ids unique.

8. **Outbox reconciliation miscounting (SA2A-CHAOS-012, RECEIPT_FAILURE).**
   `ReceiptOutbox.reconcile_entry/3` treated any receipt already present in
   the primary store as `already_present`. When a concurrent drain moved a
   `:pending` anchor into the primary store while the executor was still
   inside DO, and the executor's own final commit then failed (finalized
   receipt outboxed), the next drain deleted the finalized receipt — the
   observed outcome was erased and the command stayed
   `prepared_unknown_outcome` forever. Found and fixed in `35ff47c` (merged
   as `533dd14`): a finalized entry with the same receipt id now supersedes
   a stored `:pending` anchor (`supersedes?/2`); a stale pending entry never
   downgrades a finalized one. Before: `FALSIFIER_SURVIVED`,
   OCEL-corroborated. After: `FALSIFIER_KILLED`.

9. **Refusal-classification completeness (S42).** Commit `9536998`
   (`fix(refusal): classify every refusal code in lib/`) closed the S42
   completeness requirement that every refusal code emitted anywhere in
   `lib/` be classified via a module's `__sa2a_refusal_codes__/0`, verified
   by `semantic_refusal_test.exs`'s totality scan. This scan is re-run and
   re-passed as a standing verification step in every subsequent Chicago
   merge in §2 (each merge body states it passes or names the one new code
   it classified).

10. **SA2A-CHAOS-019/020 — bounded claim-lease liveness gap.**
    `ReceiptStore.claim/2` durably records `receipt: nil` before any receipt
    anchor exists. A crash between that claim and
    `CommandBus.prepare_receipt_anchor/4` left no live executor able to ever
    set `receipt`, so every resubmission of that command id hit
    `{:error, :in_flight}` forever — a liveness bug (RFC-SA2A-002 §70/§71
    govern at-most-once dispatch, not eventual resubmission). Found and
    fixed in `468852d` (merged as `2e8683f`,
    `feat/sa2a-002-close-chaos-liveness-v26.9.16`): new
    `AshA2A.ReceiptStore.ClaimLease` (configurable `claim_lease_ms`, default
    300_000ms) judges a claim abandoned only when both the lease has
    elapsed AND `AshA2A.ReceiptOutbox` holds no anchor for that command id —
    a claim that reached receipt preparation is never reclaimed regardless
    of age.

11. **CHI-SELFTEST-REPLAY-001 — self-test replay vacuity.**
    `AshA2A.Test.ChicagoSelfTest.Court` (CHI-SELFTEST) never drove a
    replay, so the §97 `Mutation.Catalog` `"replay_calls_actuator"` mutation
    (`CommandBus.claim_receipt/3`'s `{:replay, receipt}` branch rewritten to
    re-actuate) could not fail it — a vacuous guard. Found and fixed in
    `7cba4aa` (merged as `5bb46ef`,
    `feat/sa2a-002-close-selftest-mutation-v26.9.16`): new
    `AshA2A.Test.ChicagoSelfTest.ReplayCourt` with falsifier
    `CHI-SELFTEST-REPLAY-001` resubmits an already-committed command through
    the real `CommandBus` and asserts, via the independent OCEL observer,
    that only a `brce.claim` decision is observed on replay and never a
    second actuation.

## 5. Remaining open / BLOCKED items

### 5.1 — Six BLOCKED_ON_PRAXIS GraphLaw engine defects (open, not ash_a2a's to fix)

Pinned in `18a9082` (`feat(chicago): SA2A-ENGINE court pins vendored
GraphLaw defects; praxis HEAD refresh BLOCKED`) and reconfirmed by the final
crown run (verbatim in §6). These are defects in the vendored
`praxis-graphlaw` WASM engine itself, not in `ash_a2a`'s own code — a 2026-09-16
`praxis` HEAD refresh attempt (commit `31f149d`) was itself `BLOCKED`, so the
vendored artifact was kept pinned rather than silently upgraded past a build
that reproduces the same defects:

- `SA2A-ENGINE-001`/`002` — `GL-DEFECT-001`: `run_hooks` never fires a hook
  on a matching base-graph or incoming-event predicate.
- `SA2A-ENGINE-003` — `GL-DEFECT-002`: `run_hooks` admits (`verdicts: []`)
  even when the referenced RDF extension refuses both inputs.
- `SA2A-ENGINE-004` — `GL-DEFECT-003`: `DATALOG` dialect admits a
  non-range-restricted rule that `N3_DENIAL` independently refuses (dialect
  disagreement).
- `SA2A-ENGINE-005`/`006` — `GL-DEFECT-004`: `validate_all` traps
  (`graphlaw_call_trapped: "all fuel consumed by WebAssembly"`,
  fuel=500,000,000) instead of a clean `REFUSED`/exit, on both a
  non-function-free rule document and an otherwise-admissible one.

Status: `BLOCKED` on the vendored engine, not `ash_a2a`. Falsifiers
`SA2A-ENGINE-001`–`006` are expected to (and do) `SURVIVE` every run until
the vendored engine is fixed upstream; this is why the crown standing below
reads `NONCONFORMANT` rather than `CONFORMANT` at `:strict`.

### 5.2 — SA2A-MUTATION catalog

No survivors. Commit `7cba4aa` (§4.11) re-ran the full 14-entry catalog
against the final state of `main` (every named killer court present): **14
killed, 0 survived, 0 blocked**, all `ocel_corroborated? true`. This is a
closed item, stated here because the task explicitly asked whether any
catalog entries remain open — none do.

### 5.3 — SA2A-TRANSPORT-004/005 blocked/unresolved entries

Named explicitly in commit `e940b88`'s own before/after full-suite run
(`MIX_ENV=test mix ash_a2a.chicago --profile do`, the 448-falsifier suite at
that point in history) as reproduced identically on unmodified `HEAD` via
`git stash` — i.e., not introduced by that commit's own change. These two
falsifiers require a real bound HTTP/JSON-RPC listener (`A2A.Plug` via a
real Bandit listener); this receipt does not independently re-verify
whether that transport resource was available in the final crown run
environment, and treats the crown run's own `falsifiers_blocked=2` (§3, §6)
as most likely — but not independently re-confirmed here — corresponding to
these same two ids, since no other blocked-count source is named anywhere
in the 82-commit range's own bodies.

### 5.4 — Crown-run / full-suite-verify flags

See §6 and §8 verbatim. No additional open items beyond §5.1–§5.3 are named
in the crown run or the full-suite-verify output.

## 6. Crown standing claim (verbatim)

Command run (repo clean before and after, no commit needed/made):

```
cd /Users/sac/ash_a2a && MIX_ENV=test mix ash_a2a.chicago --profile strict --crown --evidence-dir /private/tmp/claude-501/-Users-sac-ash-a2a/ec3dd2e8-fa19-4efe-90a3-eca0b048d05b/scratchpad/crown-final
```

Exit code: 0 (task exits 0 regardless of standing; `--require-conformant`
was not passed)

```
=== Standing claim (verbatim, from standing_receipt.json and crown.json) ===
"SA2A-STRICT NONCONFORMANT: SA2A-ENGINE-001, SA2A-ENGINE-002, SA2A-ENGINE-003, SA2A-ENGINE-004, SA2A-ENGINE-005, SA2A-ENGINE-006 survived"
run standing: NONCONFORMANT
crown standing: NONCONFORMANT (crown never promotes past the run's own standing -- base already NONCONFORMANT so the crown's own strict-mandatory-corpus/compliance-matrix downgrade logic never triggers; both stay NONCONFORMANT via the base run's verdict)

=== Gate table (12/12 COVERED/PASSED) ===
gate 1  ExactIdentityFenced              courts=[CHI-ID, SA2A-ROOT]                                PASSED
gate 2  ExecutableWorldAdmitted          courts=[CHI-ADM, SA2A-ENV, SA2A-META, SA2A-NEG, SA2A-SHACL, SA2A-SHEX]  PASSED
gate 3  RealLoadBearingCollaborators     courts=[CHI-REAL]                                          PASSED
gate 4  PlanningCandidateOnly            courts=[CHI-PLAN-AUTH]                                     PASSED
gate 5  WholeBoundedPlanPreflighted      courts=[CHI-PREFLIGHT]                                     PASSED
gate 6  AutonomousExecutionInsideEnvelope courts=[CHI-AUTO, SA2A-BOUNDS, SA2A-CASCADE]               PASSED
gate 7  SoleDoBoundary                   courts=[CHI-BRCE, SA2A-HOOK]                               PASSED
gate 8  IndependentPostconditionObservation courts=[CHI-POST]                                       PASSED
gate 9  CompleteReceiptIdentityBinding   courts=[CHI-RECEIPT]                                       PASSED
gate 10 OfflineReplaySucceeds            courts=[CHI-REPLAY]                                        PASSED
gate 11 FreshConsumerProofSucceeds       courts=[CHI-FRESH]                                         PASSED
gate 12 ZeroRuntimeInferenceOnKnown      courts=[CHI-KNOWN]                                         PASSED
gates_required=12 gates_attempted=12 gates_passed=12 gates_failed=0 gates_open=0 gates_missing=0

=== Falsifier counts (results.results, standing_receipt.json) ===
falsifiers_total=545  falsifiers_killed=399  falsifiers_survived=6  blocked=2  unknown=0
uncorroborated=0 unsupported=0 build_broken=0 not_applicable=0
positive_controls_passed=122 positive_controls_failed=0  measured=16

=== Survived falsifiers, verbatim (all 6, court SA2A-ENGINE -- the known BLOCKED_ON_PRAXIS graphlaw/praxis engine defects) ===
SA2A-ENGINE-001  defect=GL-DEFECT-001  case=hook_in_base_matching_event   -- run_hooks returns verdicts:[] / status ADMITTED even though the RDF-ex event asserts the hooked predicate (hook never fires on a matching base-graph event)
SA2A-ENGINE-002  defect=GL-DEFECT-001  case=hook_in_event_matching_event  -- same defect, hooked predicate asserted by the incoming event itself
SA2A-ENGINE-003  defect=GL-DEFECT-002  -- run_hooks admits (verdicts:[]) even when RDF-ex refuses both inputs
SA2A-ENGINE-004  defect=GL-DEFECT-003  -- validate_all: N3_DENIAL dialect reports REFUSED (1 denial violation) while DATALOG dialect independently reports ADMITTED for a rule document classified rule_not_range_restricted (dialects disagree; non-range-restricted Datalog still admitted)
SA2A-ENGINE-005  defect=GL-DEFECT-004  -- validate_all traps (graphlaw_call_trapped: "all fuel consumed by WebAssembly", fuel=500000000) on a rule document classified rule_not_function_free, instead of a clean REFUSED/exit
SA2A-ENGINE-006  defect=GL-DEFECT-004  -- same fuel-exhaustion trap, this time on a rule document classified admissible (i.e. an admissible document still exhausts fuel and traps rather than validating)
```

`falsifiers_blocked=2` in the counts above is not itemized by id in the
crown output handed to this receipt; §5.3 records the best-evidenced,
not-independently-reconfirmed candidate (`SA2A-TRANSPORT-004`/`005`).

## 7. Push status

**Nothing has been pushed to origin.** `origin/main` is at
`e25ed6e3252291fd9816747a1b904303cc35c315`; local `main` is **107 commits
ahead, 0 commits behind** `origin/main` (`git rev-list --left-right --count
origin/main...HEAD` → `0  107`), covering both this RFC-SA2A-002 work and
prior unpushed local work. No `git push` was run as part of this receipt or
any commit it documents.

## 8. Full-suite-verify (literal, verbatim)

```
cd /Users/sac/ash_a2a && pwd && git status --short && git log -1 --oneline
-> /Users/sac/ash_a2a
-> (empty)
-> 2e8683f merge: feat/sa2a-002-close-chaos-liveness-v26.9.16

$ mix format --check-formatted
EXIT:0
(no output — clean)

$ mix compile --warnings-as-errors
EXIT:0
(no output — clean, zero warnings)

$ mix test --max-cases 6
Finished in 498.7 seconds (18.3s async, 480.4s sync)
58 doctests, 19 properties, 1910 tests, 0 failures, 8 invalid, 1 skipped (14 excluded)
[os_mon] memory supervisor port (memsup): Erlang has closed
[os_mon] cpu supervisor port (cpu_sup): Erlang has closed
EXIT:2
```

Diagnosis of the non-clean exit (2) and the 8 invalid tests: matches the
session's stated baseline exactly, not a regression. Two `setup_all`
callbacks fail on the same root cause (grepped and inspected directly, not
inferred):

```
0) AshA2A.ScheduledSweepQualificationTest: failure on setup_all callback, all tests have been invalidated
   ** (DBConnection.ConnectionError) [Elixir.AshA2A.Test.Repo] connection not available and request was dropped from queue after 5972ms.
   at test/ash_a2a/scheduled_sweep_qualification_test.exs:153 apply_oban_migration!/0 -> Ecto.Migrator.lock_for_migrations/4

0) AshA2A.ObanDeliveryQualificationTest: failure on setup_all callback, all tests have been invalidated
   ** (DBConnection.ConnectionError) [Elixir.AshA2A.Test.Repo] connection not available and request was dropped from queue after 4000ms.
   at test/ash_a2a/oban_delivery_qualification_test.exs:301 apply_oban_migration!/0 -> Ecto.Migrator.lock_for_migrations/4
```

Preceding log lines show Postgrex connection attempts failing outright
("tcp recv (idle): closed"). No local Postgres is running, exactly as this
session's pre-declared baseline states. These two `setup_all` failures
account for the 8 invalidated tests. ExUnit's process exit code (2) reflects
the presence of invalid tests even though `failures=0` — this is exit-status
semantics, not evidence of a code regression.

This `full-suite-verify` run was taken at `2e8683f` (before the two
documentation-only commits `9ef801e` and `c553124`, which touch only
`CHANGELOG.md` and two `docs/` files and do not change compiled code or test
behavior). It is not independently re-run at `final_sha` in this receipt;
the two intervening commits carry no code diff that would plausibly change
this result.

## 9. Verification ladder — commands and exit codes (this receipt's own session)

| Command | Exit | Result |
|---|---|---|
| `cd /Users/sac/ash_a2a && pwd && git status --short && git log -1 --oneline` | 0 | clean, `c553124` |
| `MIX_ENV=test mix ash_a2a.chicago --profile strict --crown --evidence-dir <scratch>/crown-final` | 0 | crown standing `NONCONFORMANT`, gates 12/12 PASSED (§6) — task exits 0 regardless of standing since `--require-conformant` was not passed |
| `mix format --check-formatted` (full-suite-verify, at `2e8683f`) | 0 | clean |
| `mix compile --warnings-as-errors` (full-suite-verify, at `2e8683f`) | 0 | clean, zero warnings |
| `mix test --max-cases 6` (full-suite-verify, at `2e8683f`) | 2 | 0 failures; 8 invalid (no local Postgres, pre-existing baseline, not a regression — see §8) |

No command in this ladder was run against `final_sha` itself for compile/format/test
(only the crown run was); see the note at the end of §8 for why that gap is
judged low-risk rather than closed.

## 10. Standing

**PARTIAL_ALIVE**, using the vocabulary ALIVE/PARTIAL/BLOCKED/UNSUPPORTED/REFUSED —
**never CONFORMANT**, because the crown run itself reported `NONCONFORMANT`
at `:strict` (§6), not because this receipt is withholding a passing claim.

- **ALIVE**: all 28 branches in §2 real-merged onto `main`; 42 discoverable
  courts; all 12 RFC-SA2A-002 gates COVERED/PASSED at the court level; 11
  real defects (§4) found by real falsifiers against the real running
  system and fixed forward, each with a real before/after verdict flip; the
  SA2A-MUTATION catalog fully closed (14/14 killed, §5.2); `mix format` and
  `mix compile --warnings-as-errors` clean.
- **BLOCKED**: 6 `SA2A-ENGINE-*` falsifiers survive against a vendored
  `praxis-graphlaw` engine defect this repository does not own the fix for
  (§5.1) — this is the entire reason the crown standing is `NONCONFORMANT`
  rather than `CONFORMANT`.
- **PARTIAL / UNVERIFIED**: 2 falsifiers reported `blocked` by the final
  crown run, best-evidenced but not independently re-confirmed here as
  `SA2A-TRANSPORT-004`/`005` (§5.3); `full-suite-verify` (§8) was captured
  at `2e8683f`, two documentation-only commits before `final_sha`, and was
  not independently re-run at `final_sha` in this receipt-writing session.
- **REFUSED**: nothing was pushed to `origin` (§7), and no merge to a
  release branch or PR was opened — this was direct work on local `main`
  only, per this task's own constraint.

## See Also

- `docs/rfc/RFC-SA2A-002-v26.9.16.md` — the full specification this court implements
- `docs/explanation/chicago-conformance-court.md` — the court's own explanation doc
- `lib/ash_a2a/chicago.ex`, `lib/ash_a2a/chicago/crown.ex` — implementation entry points
- `priv/sa2a/chicago_mandatory_corpus.json` — the S98 mandatory corpus
- `CHANGELOG.md` — the `[Unreleased]` Chicago court entry
- `docs/explanation/chicago-benchmark-report.md` — the B1/B5/B9 benchmark report (commit `c553124`)
- `docs/jira/v26.9.14/RELEASE_RECEIPT.md` — the prior release receipt this document's shape follows

Claude-Session: https://claude.ai/code/session_017Dd9AnjCaRgumnhptViGXM
