# _LANES_V3

Lane map V3 for milestone v26.9.28-kernel. It records what REMAINS after the factory and
replan branches merged (HEAD 62cd548, tree dirty). Source: 24 lane-status reports and 3 audits
(wiring, authority separation, identity/canonical/effect). All statuses are from read-only
inspection; no code was run for this document (UNVERIFIED by execution).

Last Updated: 2026-09-28. Supersedes _LANES_V2.md for scheduling; V2 stays the source for
lane definitions, contracts and RESOLUTIONS.md pins.

## Contents

- Status table
- Honest wiring truth
- Per-lane remaining work
- Wave plan and gates
- Vacuous and self-checking tests to strengthen
- Generated versus handwritten
- Precondition and X1-X4 physical needs
- See Also

## Status table

Status vocabulary: PARTIAL = some real production behavior exists; STUB = code exists but is
a placeholder or unwired island; MISSING = no deliverable at all. No lane is DONE.
Item counts are tallied from each lane report (A=ALIVE, U=UNTESTED, W=UNWIRED, S=STUB,
M=MISSING); they are approximate to one item.

| lane | status | A/U/W/S/M | remaining edits | wave |
|---|---|---|---|---|
| L01 identity, effect instance | PARTIAL | 1/2/2/2/8 | 14 | W1a |
| L02 24 digest sites | MISSING | 0/1/0/0/13 | 12 | W1b |
| L03 refusal codes | MISSING | 1/0/1/0/3 | 6 | W1a |
| L04 prepared journal, key custody | STUB | 1/4/1/1/4 | 13 | W2 |
| L05 kernel, effectors | STUB | 0/2/2/2/8 | 15 | W3 |
| L06 dispatch inversion | MISSING | 0/1/2/0/9 | 12 | W4 |
| L07 chicago repoint | MISSING | 0/1/1/0/7 | 14 | W4 |
| L08 test conversion | MISSING | 0/3/1/1/4 | 11 | W4 |
| L09 consequence classification | MISSING | 2/2/0/0/6 | 15 | W4 |
| L10 claims, fencing, unknown | STUB | 0/4/0/3/7 | 17 | W5 |
| L11 authority fence, mint | PARTIAL | 3/2/1/1/6 | 14 | W5 |
| L12 SecurityProfile, boot | MISSING | 0/2/3/0/9 | 20 | W6 |
| L13 SafeExec, CallbackRegistry | MISSING | 0/1/0/0/6 | 7 | W7 |
| L14 egress, endpoints | PARTIAL | 2/0/0/0/8 | 9 | W7 |
| L15 FileObject | MISSING | 0/1/0/0/9 | 10 | W7 |
| L16 continuation scope | PARTIAL | 2/1/0/0/7 | 9 | W7 |
| L17 envelope, budget | STUB | 1/1/0/1/12 | 12 | W7 |
| L18 receipt seal, wire | PARTIAL | 0/4/2/0/6 | 14 | W8 |
| L19 derived standing | MISSING | 0/2/1/0/7 | 12 | W8 |
| L20 verifier, mutation, rows | MISSING | 0/4/1/0/13 | 13 | W9 |
| X1 certificate, sa2a_wire | STUB | 0/1/1/4/5 | 11 | W2 / W6 |
| X2 authority service | STUB | 0/1/1/3/5 | 13 | W6 |
| X3 signer registry | MISSING | 0/0/0/2/6 | 9 | W3 |
| X4 actuator | STUB | 0/1/1/6/3 | 8 | W6 / W9 |

Totals: DONE 0, PARTIAL 5 (L01, L11, L14, L16, L18), STUB 7 (L04, L05, L10, L17, X1, X2,
X4), UNWIRED 0 as a lane status (the merged kernel is unwired at module level, see next
section), MISSING 12 (L02, L03, L06, L07, L08, L09, L12, L13, L15, L19, L20, X3).

## Honest wiring truth

The merged consequence kernel is a parallel island. `grep ConsequenceKernel lib/` finds only
its own definition (`lib/ash_a2a/consequence_kernel.ex`, execute/2 at line 2). There is no
`prepare`. No production module calls `EffectInstance`, `PreparedEffect`, `Effector`,
`Identity.Canonical` (outside the island), any `C2.*` module, `BudgetLedger`, or
`SecurityProfile` (which does not exist).

### Production path in force

`Agent -> CommandBus.run -> BrceAnchor.put -> Dispatcher.dispatch -> Ash.*`, with the gate
being `BrceAnchor.take/admit` (dispatcher.ex:243-260), not the kernel.

- `command_bus.ex:1430-1446`: `BrceAnchor.put` then `Dispatcher.dispatch`.
- `dispatcher.ex:135`: public `dispatch/3..6`; Ash effects at 640, 665, 730, 737.
- Legacy digests still use `:erlang.term_to_binary([:deterministic])`: `command.ex:117`,
  `actuation.ex:112,124`, `transport/principal.ex:121`, `c2/prepared_effect.ex:8-11`,
  `receipt/binding.ex:40,444,462`, about 40 lib files in total.

### Remaining bypass edges

- Agent observe calls Dispatcher directly: agent.ex:794
- Agent change/external via CommandBus, not kernel: agent.ex:804-813, command_bus.ex:1433
- Reactor, FLAME, Oban reach effects via CommandBus only: reactor/execute_command.ex:24,
  execution/flame.ex:28, delivery/oban.ex:144
- Other CommandBus.run callers: gall/process_autonomics.ex:346, gall/process_intervention.ex:139,
  semantic/episode.ex:1285, semantic/hook_reactor.ex:532
- OnCancel dynamic apply, no consequence gate: agent.ex:1189, 1248-1258; on_cancel.ex:25,30
- Push webhook Req.post: a2a_transport/push_delivery.ex:125
- OCEL forwarder raw Req.post, no SSRF admission: telemetry/ocel_forwarder.ex:239
- Receipt outbox writes to System.tmp_dir default: receipt_outbox.ex:120-138, 464-487
- kill switch DETS at caller path: kill_switch.ex:262-267
- raw System.cmd and Port.open sites: sa2a/graphlaw.ex:103, planning/hddl_solver.ex:100,
  runtime_identity.ex:115, standing_ref.ex:468, research/erc.ex:140,147, graph_law/runtime_b.ex:89
- chicago fixtures call Dispatcher or Ash.create: chicago/fixtures/federated_delegation.ex:250,
  courts/brce.ex:172-192

### C1 satisfied? NO

Discriminating evidence (not commit messages):

1. No production caller of `ConsequenceKernel.execute`; CommandBus still calls Dispatcher.
2. Production identity is BEAM term serialization (`command.ex:117`, `actuation.ex:124`), so
   the JCS identity in `Identity.Canonical` gates nothing on the live path.
3. `execute/2` calls `store.claim_request/claim_effect`; no ReceiptStore implements them
   (only two test doubles that always return :ok), so it would raise against Memory or EKV.
4. `EffectInstance.new` and `RequestIdentity/EffectIdentity.derive` disagree (untagged versus
   kind-tagged), so the same input yields different effect_id.
5. `priv/sa2a/c1/vectors/*.json` are JSON-decode-checked only
   (`c1_vector_manifest_test.exs`); no known-answer digests, no other-runtime verifier.
6. `CompleteMediation.admit_call_path` is membership in a caller-supplied list; its only test
   passes `[AshA2A.Dispatcher]`.
7. Generation fencing exists only in `c2/fencing_token.ex` (`>=`), called only inside c2.

The only C1 element that is ALIVE in production is the pre-existing `:strict`
`actuation_dedup` claim in CommandBus, keyed on the legacy digest, and it is not enforced
for stores lacking `claim_actuation/3`.

### C2 satisfied? NO

1. `lib/ash_a2a/c2` is in-process code in the same OTP app; no separate app, release, key
   custody, or signing code exists. `sa2a_wire`, `authority_service`, `signer_registry`,
   `actuator` directories do not exist.
2. `CertificateVerifier.verify/3` never calls `CryptoVerifier.verify`; it checks only that
   the algorithm atom is supported, so a certificate with garbage signatures is admitted.
3. `SignerSet` (module `AshA2A.C3.SignerSet` in a c2 path) counts unique signer labels, has no
   callers, and does not check authority-domain independence.
4. `AuthorityService.authorize/3` delegates to a caller-supplied module; nothing issues a
   `Certificate`, which is a plain struct any caller can build.
5. All 35 `test/ash_a2a/c2/court_NNN.exs` files assert one property (two `PreparedEffect`
   digests differ). None touches Certificate, verifier, SignerSet, Actuator, or ClaimStore.
6. The files lack the `_test.exs` suffix and `mix.exs` sets no `test_pattern`, so default
   `mix test` skips them (UNVERIFIED by run).
7. `Actuator.execute/5` ignores `store.complete/2` and has no unknown-outcome path;
   `MemoryClaimStore` is a global named Agent whose `complete/2` upserts unclaimed digests.

## Per-lane remaining work

File ownership is disjoint per lane within each wave. Files touched by several lanes are
listed in the relay table at the end of this section; the earlier wave owns the file, later
waves add hunks after the earlier commit lands. All refusal codes route through L03 rows;
no other lane edits `refusal_registry.ex` or `refusal_codes.ex`.

### L01 identity and effect instance (W1a)

- Edits: rewrite `identity/canonical.ex` (normalize, typed errors, no blanket rescue,
  atom/string key equality, refuse tuples, integral floats, NaN, depth bound); new
  `identity/canonical/{encodable,migration}.ex`; harden `effect_instance.ex` and make
  `consequence_kernel/{request,effect}_identity.ex` delegate to it; add
  `Actuation.identity_checked/2`; move `command.ex`, `execution_identity.ex`,
  `transport/principal.ex`, `c2/prepared_effect.ex` digests to Canonical; replace
  `identity.ex` inspect fallback; new `priv/identity/canonical_vectors.json`.
- Courts: SEC-M14-1..4 (RFC 8785 vectors, python3 independent recompute with named skip,
  refusal classes, key-normalization equality), SEC-M11-A..C, updated fingerprint and
  actuation identity tests, revert-mutation anti-vacuity.
- Defects: blanket rescue; two divergent id derivations; mixed bare-hex and `sha256:`.
- Depends on: G0; L03 soft; mac/3 ships `{:error,:unsupported}` until L04.

### L02 24 digest sites (W1b)

- Edits: convert planning.ex, semantic/{feedback,source,planning_ir,execution_package,
  unknown,allocator,bounded_production,ontology,envelope,meta_admission}, hook_reactor
  {intent,hook}, evidence/class, capability_index/changelog, architecture_envelope,
  architecture/standing_court, equilibrium/switchboard, saga_control, gall/{process_
  intervention,command_receipt,process_autonomics}, gall/closure/determinism. Leave
  `canonical_term_digest.ex` as differential oracle. `hilt/work_order.ex` has no digest
  site: record in HANDOFF.md.
- Courts: L02-C1..C6, `sec_m14_no_beam_serialization` (real File.read grep with a fixture
  that must be flagged), `sec_m14_l02_site_digest`; convert pinned vectors in
  determinism, canonical digest, receipt_s31, offline_replay tests.
- Defects: `envelope.ex:345` hashes `inspect/2` output; `command_receipt.ex:96` prefixes
  `sha256:` over term_to_binary; `process_autonomics.ex:106` private canonical_json.
- Depends on: L01 hard.

### L03 refusal codes (W1a)

- Edits: new `consequence_kernel/refusal_codes.ex` and `refusal_codes/authority.ex`
  (RESOLUTIONS s4 plus Addendum A, plus C1 stand-in codes); rewrite `refusal_registry.ex`
  to derive from RefusalCodes; replace tautological registry tests.
- Courts: SEC-L03-1..6 (classify totality, class equality, doc parity both directions,
  already-mapped list via real `classify/1`, Addendum A parity, uniqueness).
- Defects: C1 codes map to `:blocked_unknown`; C1 names diverge from s4 (alias list needed).
- Depends on: G0. Leaves `command_bus.ex:164-175` duplicates to L06.

### L04 prepared journal and key custody (W2)

- Edits: new `key_custody.ex` (pure, explicit keys), `prepared_record_codec.ex`,
  `prepared_effect_store.ex`; rewrite `prepared_effect.ex` to 21 fields with no public
  constructor and a `@type t`; route `receipt_outbox.ex` through KeyCustody, add
  `fetch_authentic/2`, drop `:receipt_binding_key` fallback; reconciler fail-closed;
  reconcile `c2/prepared_effect.ex` (delegate or delete).
- Courts: SEC-M09-1..5, SEC-M08-5, SEC-M08-2c, PE-1, PE-2, SEC-L03-2 for prepared codes.
- Defects: no `@type t` while `effector.ex:2` references it; MAC lacks path identity.
- Depends on: L01, L03.

### L05 kernel and effectors (W3)

- Edits: rewrite `consequence_kernel.ex` as a supervised GenServer with the 11-step order;
  new `consequence_kernel/token.ex`; extend `effector.ex` with token-taking apply and unify
  with `C2.Effector`; new `effector/{ash_action,on_cancel_hook,push_webhook,ocel_export}.ex`;
  new mix task `ash_a2a.effector_graph`; `test/support/effect_probe_effector.ex`; mix.exs
  alias hunk applied via L12 ownership; make c2 courts runnable.
- Courts: SEC-M01-1,2,3,6, observe mislabel, replay concurrency (real processes).
- Defects: `authority.revalidate/2` versus `/4` mismatch; claims never released on failure;
  `else` lacks arms; kernel test uses a bare map.
- Depends on: L01, L03, L04.

### L06 dispatch inversion (W4)

- Edits: `Dispatcher.resolve/4` pure, public `fetch_input/1`, `capability_opt_forbidden`,
  delete `dispatch/3..6`; effect code moves to `Effector.AshAction`; BrceAnchor
  put/take/clear/admit removal; `command_bus.ex` lines 1430-1446 and 164-175; `agent.ex:794`;
  `on_cancel.ex` module-only; `verify.ex` on_cancel check; architecture_verifier adapters
  no-raw-effect; harden and wire `c2/actuator.ex` or retire it.
- Courts: SEC-M02-1..5, SEC-M07-1..7, SEC-M19 on_cancel closed, static no-raw-effect.
- Depends on: L01, L03, L04, L05. Committed atomically with L08, L07, L09 before G4.

### L07 chicago repoint (W4)

- Edits: `chicago/collaborators.ex` actuator role to the kernel entry; courts/brce,
  courts/federated_delegation, fixtures/federated_delegation, fresh_consumer,
  receipt/offline_replay `@do_boundary`, observer/non_authority; allowlist
  `priv/architecture/chicago_fixture_effect_allowlist.exs`; mutation catalog kernel mutants;
  re-pin `chicago_court_manifest.json` last.
- Courts: L07-C1..C6 (definitions must be pinned in RESOLUTIONS first).
- Defects: `execute/2` arity versus `execute/1` in V2; path `test/chicago` versus
  `test/ash_a2a/chicago`. Double-actuation clause BLOCKED(L10).

### L08 test conversion (W4)

- Edits: rewrite `test/support/receipted_dispatch.ex` onto the L06 entry; convert about 29
  files with 65 `Dispatcher.dispatch` hits; convert `brce_gate7_test`, `rfc004_fence_test`,
  `rfc004_agent_scope_test`, duplicate action names test.
- Courts: SEC-M01 lib effect sweep, forged resolved_skill refusal, anchorless DO refusal,
  conversion completeness with allowlist reasons.
- Depends on: L05, L06.

### L09 consequence classification (W4)

- Edits: new `effector_contract.ex` and `effector_contract/{derive,probe,test}.ex`; `:pure`
  in `skill.ex` and `dsl.ex`; derive in `transformers/build_capability_index.ex`; carry digest
  in capability_index; strict default in `agent.ex` (lookup failure must not fail open to
  `:observe`); guard hunk in `effector/ash_action.ex`; verify_architecture rule.
- Courts: SEC-M03-1..5, 8; SEC-M03-6 BLOCKED(L18); SEC-M03-7 BLOCKED(L12).
- Defect: `consequence_class.ex` and `Skill.consequence` are two unbridged taxonomies.

### L10 claims, fencing, unknown outcome (W5)

- Edits: `receipt_store.ex` callbacks (begin_effect CAS, claim_request, claim_effect,
  release_effect, recover_claim, current_generation); `receipt_store/generation.ex`;
  memory, ekv, claim_lease implementations; effect claim structs; ReplayEvidence verifying
  subject, generation, epoch, signature; kernel uses `begin_effect` and persists
  UnknownOutcome; `actuation.ex`/`command_bus.ex` `identity_checked/2` migration; fix
  `c2/{fencing_token,memory_claim_store,claim_store,actuator}.ex` (equality fence, release).
- Courts: SEC-M10, RFC004-M12 x8, RFC004-UNKNOWN x5, SEC-M13 supersedes, ordering
  anti-vacuity. Rewrite London-style claim tests against the real Memory store.
- Depends on: L01, L03, L04, L05, L06.

### L11 authority fence and mint (W5)

- Edits: broker callbacks `issue_decision/verify_decision/resolve/epoch`; in_memory and ekv
  implementations; `Authority.DecisionTicket`; new `authority_fence.ex` (observe included);
  `authority/test_support.ex` `mint/3`; `@deprecated` on `Authority.new/3`; strip caller
  `admitted_by`; fail closed on unknown constraint keys; remove `command_bus.ex:1017` observe
  skip and `:1048` trust in caller `admitted_by`.
- Courts: SEC-M04-1..7, SEC-M05-1..3, SEC-M06-1..4; replace the 7-line
  `authority_revalidation_test.exs`.
- Depends on: L01, L03; kernel-path arms BLOCKED(L05/L10).

### L12 SecurityProfile and boot (W6)

- Edits: new `security_profile.ex`, `security_profile/receipt_keyring.ex`,
  `priv/security_profile/release.json` and pin task; `application.ex` boot edge; delete
  `{:legacy,_}` and env reads in `capability_release.ex`; constant `:strict` dedup and profile
  kill classes in `command_bus.ex`; `agent.ex` forbidden_opts before `@dispatch_opt_keys`;
  info.ex, health.ex; a production caller for `KillSwitch.trip/3`; mix.exs aliases and
  `sa2a_wire` path dep; rewrite existing `command_bus_kill_switch_test.exs` (C-13 in V2 is
  stale, the file exists).
- Courts: SEC-M16-1..7 (8 BLOCKED L04/L18), SEC-M24 x7.
- Depends on: L03, L10, L11, L04.

### L13 SafeExec and CallbackRegistry (W7)

- Edits: new `safe_exec.ex` (13-entry table, delegates to `GraphLaw.Subprocess.run/3`),
  `callback_registry.ex`; replace raw `System.cmd`/`Port.open`/`apply/3` sites listed above;
  M19 codes via L03.
- Courts: SEC-M19-1..9 (real subprocesses).
- Depends on: L03, L06, L12.

### L14 egress and endpoints (W7)

- Phase 0 (runnable now, no kernel dependency): route `telemetry/ocel_forwarder.ex:239`
  through WebhookPolicy with IP pin, `redirect: false`, header allowlist; allowlist keys in
  `llm_profiles.ex` `req_llm_opts!/1`; shared `network/egress.ex`.
- Phase 1: `endpoint_capability*.ex`, `endpoint_policy.ex`, `network/llm_endpoint.ex`,
  push registration via EndpointPolicy; effector hunks BLOCKED(L05).
- Courts: SEC-M20 A-H (10 files, real local Plug server, red-first capture).

### L15 FileObject (W7)

- Edits: new `file_object.ex` (resolve, verify_at_use, root registry, charset regex);
  `receipt_outbox.ex`, `kill_switch.ex`, `spg_conformance.ex`, `research/erc.ex`,
  `standing_ref.ex` and two mix tasks through roots; git argv BLOCKED(L13).
- Courts: SEC-M21-1..8 plus mutation court (real symlinks and tmp dirs).

### L16 continuation scope (W7)

- Edits: new `semantic/continuation_scope.ex`; `package_store.ex` keyed by scope with
  per-principal cap; `agent.ex` closing `command_id` derived from principal and fingerprint
  (`agent.ex:1030-1034` allows squatting), anonymous refusal, single
  `continuation_not_found`; refusal rows via L03.
- Courts: SEC-M17-1..5; SEC-M17-6 BLOCKED(L20); package_store_scope_bounds.

### L17 envelope and budget (W7)

- Edits: new `resource_envelope.ex`, `budget_ledger.ex` (+ memory, ekv), `effect_lineage.ex`,
  `apportion/2` with `priv/budget/apportion_vectors.json`; `execution_context.ex` fields;
  `bound_gate/3` in `pre_do_gate`; kernel reserve step; preflight consumes the envelope;
  retire or rename `c2/{budget_ledger,resource_envelope}.ex` (name collision).
- Courts: SEC-M22-1..7 (5,6 BLOCKED L05), adapter rule, differential apportion court.

### L18 receipt seal and wire (W8)

- Edits: new `wire/{codec,record,receipt,execution_snapshot,jcs}.ex`, `receipt_seal.ex`,
  `consequence_kernel/receipts.ex`, `ash_a2a.outbox.migrate` task; binding v2 with dual read;
  store commit authentication; outbox on wire codec with legacy read; remove stored
  `:standing` (`receipt.ex:120,135,239`, `command_bus.ex:1416`) after L19 pins
  `Receipt.standing/1`.
- Courts: define C-L18-1..7 in RESOLUTIONS first, then evidence forgery x6, commit
  authentication, binding JCS identity, wire roundtrip property (prerequisite to cutover).

### L19 derived standing (W8)

- Edits: new `standing/{axes,derive}.ex`; `Receipt.standing/1`; replace `mark_standing/2`
  (5 call sites); `semantic/peer/outcome.ex` seal; Ledger writer token; reroute stored
  standing readers; `conditional_commitment.ex` readiness rename; `runtime_receipt.ex:21`.
- Courts: SEC-M15-1..4, 6, 7 (7 BLOCKED L05/L18); replace tautological standing tests.

### L20 verifier, mutation, rows (W9)

- Edits: new `architecture_verifier/{effector_graph,network_egress}.ex`,
  `priv/sa2a/effector_allowlist.json`; consume `Conformance.dynamic_call_sites/1`;
  migrate 20 `Authority.new` sites in `chicago/` to `TestSupport.mint/3`; replace
  `binary_to_term` at `chicago/fixtures/receipt_binding_attestation.ex:229`; mutation
  entries M05, M10, M11, M13, M22, M24; extend mandatory corpus; `sec_row_table.json`
  derived; aggregate handwritten ledger; final manifest re-pin.
- Courts: SEC-M01-4,7, L20-GRAPH-1,2, L20-ROWS, SEC-M15-5, SEC-M17-6, SEC-X4-12,
  `mandatory_corpus.complete?`.

### X1 certificate and sa2a_wire

- X1a (W2): new mix project `sa2a_wire/` (strict RFC 8785 subset, `ActuationCertificate`,
  Suite table, pure `Verifier.verify/5` with quorum seam, vectors byte-equal to
  `priv/identity/canonical_vectors.json`); real contract schema replacing the placeholder
  `actuation-certificate.json`.
- X1b (W6): `authority_client.ex` (UDS or mTLS, no key), certificate step in the kernel,
  `test/support/authority_client_fake.ex` with a real Ed25519 key.
- Courts: X1-C1..C6. Defect: `CertificateVerifier` never verifies signatures.

### X2 authority service (W6)

- Edits: separate project `authority_service/` (issuer, key store read at boot, policy,
  mTLS listener, hash-chained audit); delete in-kernel `c2/authority_service.ex`; fix
  `crypto_verifier.ex` return shapes and suite ids.
- Courts: X2-C1..C6 including a real second OS process; wire `priv/sa2a/authority/courts`
  JSON into a loader test.

### X3 signer registry (W3)

- Edits: separate project `signer_registry/` (public-key registry with integrity seal, suite,
  k-of-n verifier over distinct authority domains, revocation bound to policy epoch);
  rename or delete `c2/signer_set.ex`.
- Courts: X3-C1..C8. Depends on X1a.

### X4 actuator (W6, W9)

- Edits: separate project `actuator/` (deps only sa2a_wire and signer_registry; build-time
  forbidden-deps court); 16-check fence in fixed order with typed refusals; durable `:ekv`
  claim store with unknown_outcome and monotonic generation; static effector map; evidence
  sealing; listener with size caps; Dockerfile and `k8s/actuator-*.yaml` (new files).
- Courts: SEC-X4-1..11, fence_16 vectors with per-check mutation; SEC-X4-12,13 BLOCKED
  (X2, L11, L20b).

### Relay order for shared files

| file | order |
|---|---|
| `consequence_kernel.ex` | L05 > L10 > L17 > X1b > L18 |
| `command_bus.ex` | L06 > L10 > L11 > L12 > L17 > L19 > L18 |
| `agent.ex` | L06 > L09 > L10 > L12 > L16 |
| `receipt_outbox.ex` | L04 > L10 > L15 > L18 |
| `refusal_registry.ex` | L03 only (all others supply rows to L03) |
| `identity/canonical.ex` | L01 only (L04 mac/3 via L01 hunk) |
| `mix.exs` | L12 owns (L05, X1 supply hunks) |
| `execution_package.ex` | L02 > L16 |
| `c2/*` | frozen until W6, then X1/X2/X3/X4 decide delete or absorb |

## Wave plan and gates

Each gate is a named run; a wave does not start until the previous gate is green on a clean
tree and the coordinator has committed per lane.

- W0: tree cleanup | G0: clean `git status` and `mix test.all --cover` green; BASELINE_RED.txt
  written
- W1a: L01, L03 | G1a: `mix test test/ash_a2a/sec_m14_* sec_m11_* refusal_closure_codes_test.exs`
- W1b: L02 | G1b: `sec_m14_no_beam_serialization` and `sec_m14_l02_site_digest` plus G1a
- W2: L04, X1a | G2: sec_m09_*, prepared_effect, key_custody tests; `(cd sa2a_wire && mix test)`
- W3: L05, X3 | G3: sec_m01_* (forgery, ambient, graph, observe, concurrency); `(cd
  signer_registry && mix test)`
- W4: L06, L08, L07, L09 | G4: sec_m02, sec_m07, sec_m03, sec_m19 on_cancel; `mix
  ash_a2a.chicago.pin_court_manifest --check`
- W5: L10, L11 | G5: sec_m10, rfc004_m12, rfc004_unknown_outcome, sec_m04/05/06
- W6: L12, X1b, X2, X4 | G6: sec_m16, sec_m24; x1 and x2 and actuator project tests
- W7: L13, L14, L15, L16, L17 | G7: sec_m19, sec_m20, sec_m21, rfc004_m17, sec_m22
- W8: L18, L19 | G8: wire roundtrip property, evidence forgery, sec_m15
- W9: L20, X4 integration | G9: L20-GRAPH, L20-ROWS, SEC-X4-12,13, `mix ash_a2a.chicago.mutate`,
  `mix verify.effector_graph`

L14 phase 0 has no kernel dependency and may run in W1 in parallel (owns only
`telemetry/ocel_forwarder.ex`, `llm_profiles.ex`, `network/egress.ex`).
Each gate also requires the revert-mutation for that wave's new courts to fail acceptance.

## Vacuous and self-checking tests to strengthen

- `test/ash_a2a/c2/court_001..035.exs`: one identical digest-inequality assertion; not matched by
  `_test.exs` pattern | X1/X4
- `c1_vectors/dispatcher_bypass_test.exs`: passes the forbidden module in the list it checks | L20
- `c1_vectors/effect_claim_independence_test.exs`: `function_exported?` only | L10
- `consequence_kernel/claim_test.exs`: London-style delegation tuple | L10
- `consequence_kernel/consequence_kernel_test.exs`: inline store always `:ok`, bare-map prepared |
  L05, L10
- `consequence_kernel/unknown_outcome_test.exs`: field copy only | L10
- `consequence_kernel/refusal_registry_test.exs`, `c1_vectors/refusal_totality_test.exs`: codes
  checked against themselves | L03
- `consequence_kernel/standing_test.exs`, `c1_vectors/unknown_standing_test.exs`: one error branch
  | L19
- `consequence_kernel/authority_revalidation_test.exs`: 7-line placeholder | L11
- `c1_vectors/portable_wire_test.exs`: `byte_size == 71` only | L18
- `consequence_kernel/wire_test.exs`: commutativity only | L18
- `c1_vector_manifest_test.exs`: JSON parse only | L01
- `sec_m14_canonical_identity_test.exs`: key order only, no known answer | L01
- `sec_m11_effect_instance_test.exs`: id inequality and prefix regex | L01
- `prepared_effect_test.exs`: `sha256:` prefix only | L04
- `c1_vectors/request_effect_separation_test.exs`: never calls `EffectInstance.new` | L01
- `priv/sa2a/authority/courts/*.json` (44): descriptors with no consumer | X2
- `priv/sa2a/c1/vectors/*.json` (26): no expected bytes or digests | L01

## Generated versus handwritten

Reused from V2, still applicable:

- Static kernel surface source is one consumer-local pack at `priv/ggen/sa2a_kernel/`
  authored by lane G; no marketplace pack exists for it. Generated files carry the
  `# GENERATED by ggen_igniter from priv/ggen/sa2a_kernel` header; output is committed so
  production has no NIF (`ggen_igniter` stays `only: :dev`).
- Verify ladder per V2: `mix ggen_igniter.verify|doctor|plan|sync|replay` against
  `--pack sa2a_kernel`; the replay receipt cites the ggen_igniter SHA.
- Handwritten residue per lane goes to `docs/jira/v26.9.28-kernel/handwritten/L<NN>.md`
  with an UNSUPPORTED(generator-capability) row; the directory does not exist yet.
- NEW PACK TEMPLATE REQUIRED (none built): `sa2a-identity-vectors`,
  `sa2a-canonical-digest-site`, `refusal-code-registry`, `sa2a-forbidden-opts`,
  `sa2a-closed-surface`, `sa2a-endpoint-egress`, `sa2a-file-roots`,
  `sa2a-authority-refusal`, `sa2a-sec-row-court`, `kernel-resource-envelope`,
  `sa2a-consequence-contract`, `sa2a-actuation-surface`.
- Handwritten regardless: control-flow inversion (L06), kernel ordering (L05, L10),
  per-site digest schema tags (L02), verifier logic (X1a, X3, X4).

Not applicable now: V2 statements that assumed lane G already generated the class map;
lane G has not run, so L03 and L01 vectors are handwritten first and regenerated by
byte-equality court later.

## Precondition and X1-X4 physical needs

Before wave 1:

1. `git status` clean (the tree currently has modified `lib/ash_a2a/c2/*`, `consequence_kernel/*`,
   `replan/*` and about 40 test files; commit or resolve them in the one canonical checkout).
2. `mix test.all --cover` green on that tree; write the red set to `BASELINE_RED.txt` if any
   failure predates V3 and label it pre-existing.
3. Confirm `test/ash_a2a/c2/court_*.exs` are picked up (rename to `_test.exs` or set
   `test_pattern`), so baseline includes them.
4. Add RESOLUTIONS addenda A-C and the C-L18 and L07-C court definitions.

Physical needs for X1-X4:

- X1a `sa2a_wire/`: mix project, no ash deps; path dep in root `mix.exs`
- X2 `authority_service/`: own mix project and OTP release; Ed25519 private key in a mounted 0600
  file in a 0700 dir outside the workspace, read at boot only; mTLS `:ssl` listener; separate OS
  user
- X3 `signer_registry/`: own mix project; public keys only, integrity-sealed; distinct authority
  domains
- X4 `actuator/`: own mix project and release; deps only sa2a_wire and signer_registry; own
  evidence-sealing key; durable `:ekv` store; new k8s manifests with default-deny NetworkPolicy,
  separate ServiceAccount and namespace
- Tests: X2 and X4 started as real OS processes for SEC-X4-12; per-project `_build-lane<N>` roots
- Key custody: kernel holds no authority key; control-plane key fence is physical, not a key-name
  blocklist

## See Also

- `_LANES_V2.md` (lane definitions, contracts, ggen decisions)
- `RESOLUTIONS.md` (pinned seams and refusal tables)
- `HANDOFF.md` (branch and merge state)
- `~/.claude/rules/same-checkout-fanout.md` (single-checkout lane protocol)
