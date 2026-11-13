# RFC-SA2A-005-cwe-court-matrix-v26.9.28

Machine-oriented court specification for `RFC-SA2A-005-security-profile-v26.9.28.md`.
Subject: `/Users/sac/ash_a2a` HEAD `8af12616314c12c58dfa6cd03c83c0c8ad657eb6` plus in-flight
uncommitted RFC-004 edits. Last Updated: 2026-09-28.

## Conventions

- **Court coverage** (the "Status" columns): EXISTS means a test exists whose
  removal-of-protection failure was verified by reading it; it does not mean the test was
  run, and it is not the entry criteria below or release-receipt qualification. PARTIAL
  means a test or scanner covers part of the attack. MISSING means none found by grep of
  `test/`. This axis differs from the profile's "Code state" (ABSENT, PRESENT_GUARDED,
  PRESENT_UNGUARDED, UNKNOWN). No test was run for this document, so no row is claimed
  to pass. Counts, previous draft to this revision: Table A EXISTS 3 to 6, PARTIAL 14 to 14,
  MISSING 8 to 5; Table D EXISTS 0 to 7, PARTIAL 14 to 10, MISSING 8 to 5.
- **Proposed refusal codes**: refusal codes in Tables B and E marked with `*` are PROPOSED
  names that do not exist in `lib/`; the mapping to existing codes is in Table G.
- **Outcome**: `REFUSE(<code>)` is a typed refusal before any effect. `CORRUPT0` is
  candidate-corruption with zero unauthorized consequence: the candidate plane is allowed to
  be wrong, and the assertion is on the consequence store and effector counter.
- **Collaborator**: real objects only (Chicago style, no mocks). A named skip is allowed when
  a real collaborator is absent on the machine, never a silent substitute.
- **R4**: RFC-004 section dependency (R4 section 10 authority, 11 protocol, 12 receipts,
  21 security boundary, 27 implementation convergence). RFC-004 has no lane map; the
  dependency is by section.
- **Anti-vacuity**: every court MUST fail when its guard is reverted (mutation) and MUST
  refuse a mutated input. A court without this evidence counts as missing.

## Table A: CWE courts, attack and status

| Court | CWE | Attack | Court coverage | R4 |
|---|---|---|---|---|
| SEC-CWE-862 | 862 | call every effect entry without mediation | PARTIAL | 11,27 |
| SEC-CWE-863 | 863 | non-model source authority, no broker | PARTIAL | 10,27 |
| SEC-CWE-284 | 284 | Dispatcher/Ash call outside CommandBus | PARTIAL | 11,21 |
| SEC-CWE-306 | 306 | unauthenticated call to change skill | EXISTS | 21 |
| SEC-CWE-639 | 639 | foreign task or fingerprint id | EXISTS | 21 |
| SEC-CWE-078 | 78,77 | shell metacharacters in every slot | PARTIAL | 21 |
| SEC-CWE-094 | 94 | data-selected module, function or eval | PARTIAL | 21 |
| SEC-CWE-089 | 89 | SQL text in every string input | MISSING | 21 |
| SEC-CWE-022 | 22 | dot-dot and absolute path in ids | MISSING | 12,21 |
| SEC-CWE-434 | 434 | executable bytes as artifact | MISSING | 21 |
| SEC-CWE-502 | 502 | crafted term bytes in journal | EXISTS | 12 |
| SEC-CWE-918 | 918 | private, rebinding, redirect URLs | PARTIAL | 21 |
| SEC-CWE-352 | 352 | ambient-credential cross-origin post | MISSING | 21 |
| SEC-CWE-787 | 787,416,125 | crafted wasm and HDDL input | PARTIAL | 21 |
| SEC-CWE-079 | 79 | markup in candidate text | MISSING | 21 |
| SEC-CWE-020 | 20 | malformed and oversize bodies | PARTIAL | 21 |
| SEC-CWE-200 | 200 | secrets in logs, errors, telemetry | PARTIAL | 21 |
| SEC-CWE-770 | 770 | exhaust plan, solver, task state | PARTIAL | 21 |
| SEC-CWE-294 | 294 | replay with new request id | EXISTS | 11 |
| SEC-CWE-367 | 367 | revoke between check and DO | PARTIAL | 11 |
| SEC-CWE-441 | 441 | peer A grant used by peer B | EXISTS | 10 |
| SEC-CWE-551 | 551 | representation variants of one input | PARTIAL | 11,27 |
| SEC-CWE-642 | 642 | forge standing, authority, status fields | PARTIAL | 12,21 |
| SEC-CWE-837 | 837 | same effect, distinct command ids | EXISTS | 11 |
| SEC-CWE-841 | 841 | reorder or skip protocol states | PARTIAL | 11 |

Note: CWE 476, 120, 121 and 122 share SEC-CWE-787; 121 and 122 have UNKNOWN current status.

## Table B: CWE courts, expected outcome and real collaborator

| Court | Expected outcome | Real collaborator |
|---|---|---|
| SEC-CWE-862 | REFUSE(brce_prepared_receipt_required) per entry | real Agent, CommandBus, EKV |
| SEC-CWE-863 | REFUSE(authority_not_issued*) | real CommandBus, no broker |
| SEC-CWE-284 | REFUSE(fence_absent*) | real Dispatcher, counting effector |
| SEC-CWE-306 | REFUSE(:unauthenticated, 401) | real Plug pipeline |
| SEC-CWE-639 | REFUSE(not_found), same as absent | real Runtime, two principals |
| SEC-CWE-078 | CORRUPT0, effector argv unchanged | real ExecCapability broker |
| SEC-CWE-094 | REFUSE(unknown_skill*), no atom made | real index, atom-count probe |
| SEC-CWE-089 | CORRUPT0, store rows unchanged | real typed store |
| SEC-CWE-022 | REFUSE(bad_handle*), no file outside | real FS in scratch dir |
| SEC-CWE-434 | REFUSE(not_admitted_kind*) | real FileObject store |
| SEC-CWE-502 | REFUSE(outbox_bad_tag) | real ReceiptOutbox, keyed |
| SEC-CWE-918 | REFUSE(endpoint_not_admitted*) | real local resolver and listener |
| SEC-CWE-352 | REFUSE(no_ambient_credential*) | real Plug, cookie header |
| SEC-CWE-787 | typed error, BEAM alive, kernel intact | real wasm, hddl_cli, os pid |
| SEC-CWE-079 | CORRUPT0, no raw-markup node emitted | real render tree |
| SEC-CWE-020 | REFUSE(parse_error or too_large) | real Plug, size sweep |
| SEC-CWE-200 | CORRUPT0, canary secret absent in sinks | real Logger, telemetry sink |
| SEC-CWE-770 | REFUSE(bounds) or timeout, kernel live | real solver, load generator |
| SEC-CWE-294 | replay of stored receipt, 1 effect | real store, counting effector |
| SEC-CWE-367 | REFUSE(authority_revoked) pre-DO | real broker, revoke race |
| SEC-CWE-441 | REFUSE(authority_mismatch) | real broker, two principals |
| SEC-CWE-551 | one effect for all variants | real Ash cast, counting effector |
| SEC-CWE-642 | REFUSE or field ignored | real Plug, forged metadata |
| SEC-CWE-837 | second attempt :deduplicated (effect_claimed*) | real EKV, counting effector |
| SEC-CWE-841 | REFUSE(bad_transition*) | real CommandBus, fault injection |

## Table C: CWE courts, existing coverage (path found by name, not run)

| Court | Existing test or court that covers it (read, not run) |
|---|---|
| SEC-CWE-862 | test/ash_a2a/rfc004_fence_test.exs; chicago/brce_gate7_test.exs |
| SEC-CWE-863 | authority_non_implications_test; unknown_llm_gate12_test LLM-010; no broker case |
| SEC-CWE-284 | lib/ash_a2a/chicago/courts/brce.ex; rfc004_fence_test.exs |
| SEC-CWE-306 | test/ash_a2a_plug_auth_test.exs; ash_a2a_authority_decision_failclosed_test |
| SEC-CWE-639 | test/ash_a2a/a2a_transport/ownership_test.exs:107 |
| SEC-CWE-078 | lib/ash_a2a/chicago/abstract_code.ex scanner (static only) |
| SEC-CWE-094 | lib/ash_a2a/semantic/conformance.ex:1873 :dynamic_apply scanner |
| SEC-CWE-502 | receipt_outbox_hardening_test TQ-04; rfc004_outbox_integrity_test (untracked) |
| SEC-CWE-918 | a2a_transport/webhook_policy_test.exs (delivery-time rebind, redirect: none) |
| SEC-CWE-020 | transport_court_test SEC-02; adversarial_input_test; semantic_compiler_bounds_test |
| SEC-CWE-200 | obs_hardening_test; ownership_test 'no credential echo'; redact doctests |
| SEC-CWE-770 | transport_court_test (server_busy, rate_limited); whole_plan_preflight |
| SEC-CWE-294 | test/ash_a2a/command_bus_test.exs; ash_a2a_actuation_identity_test.exs |
| SEC-CWE-367 | effect_kill_test 'revoked before DO'; adapter_crash_safety_test; no barrier race |
| SEC-CWE-441 | test/ash_a2a_authority_confused_deputy_test.exs |
| SEC-CWE-642 | ownership_test.exs:139; ash_a2a_plug_tenant_actor_test.exs |
| SEC-CWE-837 | actuation_identity_test:126,163 (Memory, EKV; :strict); :224 negative control |
| SEC-CWE-841 | command_bus_hardening_test.exs; crash_reconciliation_test.exs |
| SEC-CWE-787 | graph_law_wasmex_host_test (garbage Turtle, instance stays live) |
| SEC-CWE-551 | command_fingerprint_determinism_test; semantic_policy_phenotype_hardening_test |
| others | none found (MISSING rows in Table A) |

## Table D: release-court attack list

Every row is a release blocker. Each attack runs against the deployed subject and asserts
the outcome in Table E. The CWE column maps to Table A courts that share the fixture.
CWE 494 and 522 have no Table A court and are omitted (PROPOSED, not specified here).

| Court | Attack | CWE court | Court coverage |
|---|---|---|---|
| SEC-REL-01 | forge authority | 863, 284 | PARTIAL |
| SEC-REL-02 | mutate exact subject after admission | 441, 642 | PARTIAL |
| SEC-REL-03 | replay with new request id | 294, 837 | EXISTS |
| SEC-REL-04 | forge prepared receipt | 502, 642 | EXISTS |
| SEC-REL-05 | directly invoke effector | 862, 284 | PARTIAL |
| SEC-REL-06 | change provider | 918, 642 | MISSING |
| SEC-REL-07 | exploit stale grant | 367 | EXISTS |
| SEC-REL-08 | race revocation | 367 | PARTIAL |
| SEC-REL-09 | inject SQL | 89 | MISSING |
| SEC-REL-10 | inject shell syntax | 78, 77 | PARTIAL |
| SEC-REL-11 | traverse paths | 22 | MISSING |
| SEC-REL-12 | submit arbitrary URL | 918 | PARTIAL |
| SEC-REL-13 | inject malicious peer message | 862, 94 | PARTIAL |
| SEC-REL-14 | deserialize crafted payloads | 502 | EXISTS |
| SEC-REL-15 | upload executable content | 434 | MISSING |
| SEC-REL-16 | create duplicate effect | 837, 551 | EXISTS |
| SEC-REL-17 | exhaust plan resources | 770 | PARTIAL |
| SEC-REL-18 | induce unknown outcome then retry | 837, 841 | EXISTS |
| SEC-REL-19 | introduce undeclared capability | 862 | PARTIAL |
| SEC-REL-20 | poison memory | 642, 639 | PARTIAL |
| SEC-REL-21 | tamper with a receipt | 502, 642 | EXISTS |
| SEC-REL-22 | access credentials from candidate plane | 200 | MISSING |

## Table E: release-court expected outcome and collaborator

| Court | Expected outcome | Real collaborator |
|---|---|---|
| SEC-REL-01 | REFUSE(authority_not_issued*) | CommandBus, no broker, then broker |
| SEC-REL-02 | REFUSE(subject_mismatch*) | Ash create with changed input |
| SEC-REL-03 | replay, 1 effect total | counting effector, EKV |
| SEC-REL-04 | REFUSE(outbox_bad_tag; receipt_not_found*) | keyed outbox, forged id |
| SEC-REL-05 | REFUSE(fence_absent*) | effector reached without capability |
| SEC-REL-06 | REFUSE(provider_not_admitted*) | local provider stub as real server |
| SEC-REL-07 | REFUSE(authority_revoked) | broker, revoke then call |
| SEC-REL-08 | zero effects after revoke commit | broker, barrier at pre-DO gate |
| SEC-REL-09 | CORRUPT0, rows unchanged | typed store |
| SEC-REL-10 | CORRUPT0, no extra process | ExecCapability broker |
| SEC-REL-11 | REFUSE(bad_handle*) | FS in scratch dir |
| SEC-REL-12 | REFUSE(endpoint_not_admitted*) | local listener, rebind resolver |
| SEC-REL-13 | CORRUPT0, no grant minted | Semantic.Peer, real Agent |
| SEC-REL-14 | REFUSE, no atom or struct made | outbox, snapshot files |
| SEC-REL-15 | REFUSE(not_admitted_kind*) | FileObject store |
| SEC-REL-16 | second :deduplicated (effect_claimed*) | counting effector |
| SEC-REL-17 | REFUSE(bounds), kernel serves next | solver, load generator |
| SEC-REL-18 | retry returns stored outcome, 1 effect | crash between DO and commit |
| SEC-REL-19 | REFUSE(capability_not_released*) | strict release closure |
| SEC-REL-20 | CORRUPT0, no authority in store | PackageStore, two principals |
| SEC-REL-21 | REFUSE(outbox_bad_tag; receipt_tampered*) | receipt verifier, offline replay |
| SEC-REL-22 | canary absent from candidate view | scrubbed subprocess, env dump |

## Table F: existing coverage and RFC-004 dependency for release courts

| Court | Existing test or court (read, not run) | R4 |
|---|---|---|
| SEC-REL-03 | test/ash_a2a_actuation_identity_test.exs:126 | 11 |
| SEC-REL-04 | test/ash_a2a/rfc004_outbox_integrity_test.exs | 12 |
| SEC-REL-05 | test/ash_a2a/rfc004_fence_test.exs | 11,27 |
| SEC-REL-07 | test/ash_a2a/rfc004_authority_effect_kill_test.exs:58,77 | 10 |
| SEC-REL-08 | adapter_crash_safety_test (revoke before perform); no barrier race | 10,11 |
| SEC-REL-10 | chicago/abstract_code.ex (static scan only) | 21 |
| SEC-REL-12 | test/ash_a2a/a2a_transport/webhook_policy_test.exs | 21 |
| SEC-REL-13 | test/ash_a2a/chicago/unknown_llm_gate12_test.exs | 21 |
| SEC-REL-14 | rfc004_outbox_integrity_test.exs | 12 |
| SEC-REL-16 | ash_a2a_actuation_identity_test.exs:163,206 (:224 negative control) | 11 |
| SEC-REL-17 | transport_court_test; whole_plan_preflight court | 21 |
| SEC-REL-19 | capability_release_test (strict only); default path untested | 27 |
| SEC-REL-20 | test/ash_a2a_agent_semantic_replan_test.exs | 21 |
| SEC-REL-21 | lib/ash_a2a/receipt/offline_replay.ex | 12 |
| SEC-REL-01 | authority_confused_deputy_test; authority_non_implications_test; LLM-010 | 10,11 |
| SEC-REL-02 | command_bus_test (:command_conflict on changed input) | 11 |
| SEC-REL-06,09 | none found | 10,11 |
| SEC-REL-18 | crash_boundaries_test; command_bus_hardening_test (R9, R1) | 11 |
| SEC-REL-11,15,22 | none found | 21,27 |

## Court entry criteria

EXISTS in Tables A and D is weaker than this list: it records that a test whose
removal-of-protection failure was verified by reading it is present. A court qualifies for a
security release receipt only when it (1) runs on an exact subject SHA, (2) uses real collaborators,
(3) asserts on final state or a typed refusal, (4) fails when its guard is reverted, and
(5) emits a receipt consumed by the security release receipt in RFC-005 section 13. No
row meets criteria (1), (4) and (5) today: no mutation-revert result and no receipt exists for
any row, so every court counts as missing for release purposes (RFC-005 section 13).

## Table G: proposed refusal codes and existing codes

| Proposed code (`*`) | Existing code in `lib/` (in-flight) |
|---|---|
| fence_absent | brce_prepared_receipt_required |
| authority_not_issued | authority_required; model_authority_refused |
| subject_mismatch (for 441) | authority_mismatch |
| receipt_tampered, receipt_not_found | outbox_bad_tag |
| effect_claimed | :deduplicated outcome |
| bad_handle, endpoint_not_admitted, not_admitted_kind | none |
| provider_not_admitted, capability_not_released | none |
| bad_transition, no_ambient_credential, unknown_skill | none |

## Audit record

Matrix-side changes from the adversarial audit (22 problems, see profile section 17):
Table A MISSING to PARTIAL: 863, 787, 551. PARTIAL to EXISTS: 502, 294, 837. Table D MISSING
to PARTIAL: REL-01, REL-02. PARTIAL to EXISTS: REL-03, 04, 07, 14, 16, 21. MISSING to
EXISTS: REL-18. 367 and REL-08 stay PARTIAL, scoped to revoke-before-DO; the barrier race
is MISSING. 837 and REL-16 are scoped to Memory and EKV stores under `:strict` (profile G8
caveat). No row was downgraded: the audit found the drafted PARTIAL and EXISTS rows real,
and found coverage the draft missed. Fixed: webhook_policy_test located (918, REL-12),
:93 and :275 citations, :224 as negative control, proposed codes (Table G), CWE 494 and 522
removed from Table D.

## See Also

- `docs/rfc/RFC-SA2A-005-security-profile-v26.9.28.md`
- `docs/rfc/RFC-SA2A-004-v26.9.28.md`
- `docs/rfc/RFC-SA2A-003-v26.9.28.md`
