# _LANES

Lane map for the ConsequenceKernel closure (mechanisms M01-M24, 24 verified plans,
skeptic corrections applied). Base: HEAD `8af12616314c12c58dfa6cd03c83c0c8ad657eb6`,
tree dirty with RFC-004 lanes A-F. Version marker: v26.9.28-kernel. Last Updated: 2026-09-28.
Evidence labels: OBSERVED = read from the 24 verified plans/verdicts at that SHA; DERIVED = this map.

## Contents

- Ground rules
- Wave 0 precondition
- Dependency graph
- Lane table
- Hot-file relay
- Mechanism to lane map
- Skeptic corrections carried into lane specs
- Build roots and verify ladder
- Orphans
- See Also

## Ground rules

1. One canonical checkout (`/Users/sac/ash_a2a`), normal branches, no worktrees, no copies.
2. Lanes are disjoint by file: a file has exactly one owner per wave. A file touched by more
   than one mechanism is owned by one lane per wave and handed on in the Hot-file relay
   table (strictly wave-ordered, never concurrent).
3. Relay hunks are applied by the wave's owner from a spec in `RESOLUTIONS.md`, not by the
   mechanism lane. Anchor edits by function name, never by line number (tree is mid-edit).
4. Agents never run git state commands or `deps.get`; coordinator owns commits (one per lane).
5. Every court is red-first on the unfixed subject: the lane records the failing output before
   the fix. Courts naming modules that do not exist yet stay BLOCKED(depends on lane) and are
   listed under that lane's `blocked courts`, never counted as green.
6. Chicago style: real collaborators, state assertions, zero `Mock/patch/monkeypatch`. Test
   doubles only as real fakes with a stated reason (see `testing-chicago-style.md`).
7. Identical contract block in every dispatch prompt: module names `AshA2A.ConsequenceKernel`,
   `AshA2A.PreparedEffect`, `AshA2A.PreparedEffectStore`, `AshA2A.Effector` (+ `.AshAction`,
   `.OnCancelHook`, `.PushWebhook`, `.OcelExport`), `AshA2A.EffectInstance`,
   `AshA2A.Identity.Canonical` (`normalize/1`, `digest/1` -> `"sha256:<64hex>"`),
   `AshA2A.SecurityProfile`, digest shape `sha256:<hex>`, refusal codes only from L03.

## Wave 0 precondition (hard)

No lane starts until the RFC-004 lanes A-F are committed by the coordinator. Dirty files at
snapshot (OBSERVED git status): `lib/ash_a2a/{agent,authority,brce_anchor,command_bus,dispatcher,
receipt_outbox,spg_conformance}.ex`, `authority/grant.ex`, `gall/closure/*`, `gall/fields.ex`,
`gall_closure/lease_guard.ex`, `semantic/{episode,refusal}.ex`, `chicago/fixtures/replay.ex`,
plus tests `brce_gate7`, `determinism`, `actuation_identity`, `agent_command_bus`,
`agent_semantic_replan`, `freedom_gym_hddl_plan`, `lease_guard`, `receipt_crash_window_fixture`,
untracked `rfc004_*`, `fields_test`, `docs/rfc/RFC-SA2A-004-v26.9.28.md`,
`priv/spg_conformance/v26.9.27/CORPUS_DIGEST.sha256`. The `rfc004_*` tests encode the legacy
`BrceAnchor.put + Dispatcher.dispatch` sequence and are converted by L08.

## Dependency graph

```text
P0 (RFC-004 A-F committed)
 |
W1  L01 canonical+EffectInstance ---+--- L02 mechanical digests      L03 refusal registry
 |                                  |                                 (needed by all)
W2  L04 PreparedEffect + PreparedEffectStore + journal integrity  <-- L01
 |
W3  L05 ConsequenceKernel.execute + Effector modules + effector_graph task  <-- L01,L03,L04
 |
W4  L06 dispatch-behind-kernel/removals (core lib)  <-- L05
    L07 chicago plane migration                     <-- L05,L06(API names)
    L08 test conversion (direct Dispatcher callers) <-- L05,L06
    L09 effector contract / consequence class (M03) <-- L05
 |
W5  L10 claims + fencing + authority (command_bus/agent/store relay)  <-- L04,L05,L06
    L11 authority broker/decision/fence modules                       <-- L03,L05
 |
W6  L12 SecurityProfile + release closure + kill/dedup/policy opts    <-- L10,L11
 |
W7  L13 closed callbacks + SafeExec (M19)       <-- L12
    L14 EndpointCapability + Network.Egress (M20) <-- L12,L05
    L15 FileObject (M21)                          <-- L12
    L16 ContinuationScope / PackageStore (M17)    <-- L12,L10
    L17 ResourceEnvelope + BudgetLedger (M22)     <-- L12,L10
 |
W8  L18 receipts: seal/binding/keyring + wire codec (M23,M18,M15 readers) <-- L12,L15,L17
    L19 standing derive (M15)                                             <-- L10,L18 interface
 |
W9  L20 cross-cutting courts + static effector dependency-graph verifier <-- all
```

Critical path: L01 -> L04 -> L05 -> L06 -> L10 -> L12 -> L18 -> L20. Parallel inside a wave is
safe because owned files are disjoint; relay files never appear in two same-wave lanes.

## Lane table

Notation: `lib/` prefix is `lib/ash_a2a/`; `test/` files are under `test/`. NEW = created by the lane.
Courts are `SEC-Mnn-k` from the verified plans; corrected forms per the skeptic verdicts.

### L01 (wave 1) canonical identity + EffectInstance

- Mechanisms: M14 core, M11 identity half.
- Owns: NEW `identity/canonical.ex`, NEW `identity/canonical/encodable.ex`, NEW
  `identity/canonical/migration.ex`, NEW `priv/identity/canonical_vectors.json`, `identity.ex`,
  `command.ex`, `actuation.ex`, NEW `effect_instance.ex`, `execution_identity.ex`,
  `transport/principal.ex`.
- Tests: NEW `sec_m14_canonical_identity_test`, `sec_m14_no_beam_serialization_in_identity_test`,
  `sec_m14_canonical_vectors_test`, `sec_m11_effect_instance_test`, `sec_m11_static_graph_test`,
  `sec_m11_mutation_test`; edit `ash_a2a_command_fingerprint_determinism_test.exs`,
  `ash_a2a_actuation_identity_test.exs`.
- Rules: Command.fingerprint phase 1 = Canonical.digest over current fields (keep agent_id until
  effect_instance_id is on Command); `Actuation.identity/2` returns `{:ok,_}|{:error,code}`; new
  `Command.new_checked/2`; opts idempotency keys are evidence only, never identity.
- Blocked courts: SEC-M11-1..6 green needs L10 (command_bus/store); SEC-M11-8 needs the mutation
  entry in `priv/sa2a/chicago_mandatory_corpus.json` (L20).

### L02 (wave 1) mechanical digest conversions

- Mechanism: M14 fan-out. Owns (one commit, disjoint): `planning.ex` (also the M19 planner apply
  hunk), `semantic/{feedback,source,planning_ir,execution_package,unknown,allocator,
  bounded_production,ontology,meta_admission,envelope,canonical_term_digest}.ex`,
  `semantic/hook_reactor/{intent,hook}.ex`, `evidence/class.ex`, `capability_index/changelog.ex`,
  `architecture_envelope.ex`, `architecture/standing_court.ex`, `equilibrium/switchboard.ex`,
  `saga_control.ex`, `gall/process_intervention.ex`, `gall/command_receipt.ex`,
  `gall/closure/determinism.ex`, `gall/process_autonomics.ex`, `hilt/work_order.ex`.
- Depends on the lane-E gall commit (P0). Keep `Determinism.canonical/1` as pass-through.
- Tests: `test/ash_a2a/gall/closure/determinism_test.exs`, `semantic_canonical_*_test.exs`,
  `ash_a2a_receipt_s31_fields_test.exs`, `chicago/offline_replay_test.exs` vector updates.

### L03 (wave 1) refusal registry

- Sole owner of `semantic/refusal.ex` for the whole closure. One pass adds every new code from
  M01-M24 (list below), appended after the in-flight `outbox_*` entries; no duplicate keys.
- Do NOT remap: `capability_release_closure_missing` (already `:refused_provenance`),
  `budget_exhausted` (exists), `outbox_bad_tag/untagged_entry/key_unavailable` (exist).
- Add (classes per plans): prepared_effect_{forged,not_found,seal_invalid,digest_mismatch,consumed,
  stale_epoch}, effector_edge_forbidden, consequence_class_unknown, consequence_unclassified,
  kernel_bypass, kernel_only_effector, capability_opt_forbidden, capability_release_digest_mismatch,
  capability_ambiguous, capability_release_closure_{digest_mismatch,tampered}, capability_digest_mismatch,
  release_override_refused, effector_contract_violation, consequence_action_type_mismatch,
  observe_mutated_subject, observation_receipt_missing, authority_{revoked,expired,constraint_mismatch,
  revalidation_unavailable,epoch_advanced,not_granted,broker_unconfigured,unknown_decision,decision_missing,
  decision_mismatch,forged,...}, principal_actor_mismatch, deputy_input_mismatch, ambient_authority_refused,
  authorization_bypass_refused, cancel_principal_mismatch, effector_command_forbidden, effect-instance
  codes, effect_in_flight, effect_claim_missing, replay_effect_divergence, stale_generation,
  fence_store_unsupported, unknown_outcome_unresolved, canonical_* codes, prepared_journal_*,
  prepared_state_unauthenticated, prepared_record_{identity_mismatch,stale_epoch}, outbox_legacy_format,
  schema_*, callback_not_registered, exec_*, path_*, file_effect_undeclared_capability, endpoint_*,
  refused_llm_endpoint_override, policy_opt_forbidden, security_profile_missing, kill_class_unbound,
  legacy_dedup_refused, legacy_release_refused, budget/cascade/parallelism/external_request/deadline/
  envelope codes, continuation_not_found, continuation_scope_unbound, receipt_{seal_required,
  not_kernel_issued,subject_mismatch,unsealed,key_not_configured}, standing_* codes,
  postcondition_verifier_not_release_pinned, dynamic_dispatch_forbidden.
- Also owns `__sa2a_refusal_codes__` totality test additions: NEW `test/ash_a2a/refusal_closure_codes_test.exs`
  (asserts `Refusal.classify/1` non-fallback for every listed code).

### L04 (wave 2) PreparedEffect + PreparedEffectStore + journal integrity

- Mechanisms: M08a, M09 (and the store half of M01/M02 contracts).
- Owns: NEW `prepared_effect.ex`, NEW `prepared_effect_store.ex`, NEW `prepared_record_codec.ex`,
  `receipt_outbox.ex` (M09 hunks: verified `anchored?/1`, `fetch_authentic/2`, identity-in-MAC, JCS-MAC
  domain separation, no-fallback key), `receipt_outbox/reconciler.ex`, `semantic/conformance.ex`
  (probe at anchored?, kernel module-list, module names only).
- Rules: authenticated by HMAC over `domain_sep || path_identity || bytes`; keep ETF under MAC
  until authenticated (decode only after tag+identity verify); no `Receipt` JSON codec here (L18).
  `anchored_command?` fails closed for reclaim; `command_bus:899` outcome classification treats
  unverifiable as NOT anchored (opposite rule, stated explicitly).
- Tests: NEW `sec_m09_{forged_anchor,path_swap,tamper_matrix,key_separation_rotation,
  reclaim_and_migrate}_test`, `sec_m08_forged_preparation_test` (5 and corrected 2 only);
  edit `receipt_outbox_hardening_test`, `receipt_outbox_reconciler_test`,
  `rfc004_outbox_integrity_test`.
- Blocked courts: SEC-M09-1, SEC-M09-4 stale-epoch arm, SEC-M09-5 rotation arm (need
  SecurityProfile, L12); SEC-M08-1,3,4,6,7 (need L05/L06).

### L05 (wave 3) ConsequenceKernel

- Mechanism: M01 stage A (no other-mechanism fetches), key custody.
- Owns: NEW `consequence_kernel.ex`, NEW `consequence_kernel/token.ex`, NEW `effector.ex`, NEW
  `effector/{ash_action,on_cancel_hook,push_webhook,ocel_export}.ex`, NEW
  `lib/mix/tasks/ash_a2a.effector_graph.ex`, NEW `test/support/effect_probe_effector.ex`.
- Rules: HMAC key lives ONLY in the kernel GenServer state; `PreparedEffect.verify!/1` is a
  `GenServer.call` (no `:persistent_term`); `execute/1` calls `Effector.apply/1` last, once, under a
  per-effect lock; minimal classifier (create/update/destroy >= :change, generic :action -> :unknown)
  until L09; keeps `ReceiptOutbox.anchored?` semantics inside the kernel; kernel shim preserves
  telemetry `[:ash_a2a,:dispatch,:brce_gate]` and the `:ash_a2a_ocel_command_bus_dispatch` flag.
  `mix.exs` alias `verify.effector_graph` is applied by L12 (relay).
- Effector inventory (all classed): `Ash.read`, `Ash.stream!` (run_read_stream), create/update/destroy/
  run_action, `apply(Oban, :insert,...)`, `apply(store,...)` (receipt_outbox, kernel-internal),
  FLAME, durable_server, presence/group, extended_card, planning apply (allowlist-classed by L20).
- Tests: NEW `sec_m01_{effector_forgery,ambient_anchor,effector_graph,observe_mislabel,
  replay_concurrency}_test` (SEC-M01-1,2,3,6; corrected forms: arities 3..6 refuted, graph court
  states "literal alias/remote-call edges only").
- Blocked courts: SEC-M01-5 (M06 classifier -> L09), SEC-M01-4 and -7 (L20).

### L06 (wave 4) dispatch behind the kernel, removals

- Mechanisms: M01 stage A removals, M02 stage A/B, M07 phase A, M08b, M19 on_cancel, M03 dispatcher guard.
- Owns (wave 4): `dispatcher.ex`, `brce_anchor.ex`, `agent.ex` (observe route, on_cancel, capability
  ids, cancel principal gate, comment fixes), `command_bus.ex` (kernel prepare+execute in place of
  `dispatch_with_ocel_correlation`, `bind_principal_actor/2`, `bind_message_input/2`,
  `bounded_dispatch` scrub of Ash transfer keys on BOTH paths, forbidden-opts refusal list incl.
  `:capability_release_closure/:capability_release_mode/:resolved_skill/:skill/:capability_id`),
  `reactor/execute_command.ex`, `execution/flame.ex`, `delivery/oban.ex`, `delivery/oban_authority.ex`,
  `architecture_verifier.ex`, `architecture_verifier/adapters.ex`, `lib/ash_a2a/context_resolver.ex`
  (only if actor derivation requires it).
- Rules: `Dispatcher.dispatch/3..6` all removed (assert arities 3..6, and BrceAnchor `put/1`, `take/0`,
  `clear/0`); `BrceAnchor.capability_bound?/2` name arm deleted; `Dispatcher.resolve/4` pure;
  `authorize?: true` in build opts; keep `:observe` needing no anchor.
- Tests: NEW `sec/m02_capability_spoof_test` (courts 1,2,3 corrected, 5 regression pin), `sec/m02_architecture_scan_test`
  (AST, mutation twin), `sec_m07_{principal_actor_binding,nil_actor_deputy,ambient_dictionary,input_swap,
  authorize_bypass,cancel_principal,oban_principal_swap}_test` + NEW `test/support/effector_probe_fixture.ex`;
  `sec_m19_on_cancel_closed_test`.
- Blocked courts: SEC-M02-4/7 (L05+L10), SEC-M07-8/9 (anchor digests, phase B).

### L07 (wave 4) chicago plane migration

- Owns all `lib/ash_a2a/chicago/**` (relay to L20 at wave 9), `lib/mix/tasks/ash_a2a.chicago.mutate.ex`.
- Work: re-point `collaborators.ex` (:actuator role, the `dispatch/6` string checks -> `execute/1`),
  `courts/brce.ex`, `courts/federated_delegation.ex`, `fixtures/federated_delegation.ex`,
  `fresh_consumer.ex` @do_boundary, `observer/non_authority.ex`; move the seven `Ash.create` fixtures
  (`postcondition:84, federated_delegation:216, authority:41, brce:201/213, chaos_reconciliation:88,
  autonomy_bounds:73`) to `test/support` (or explicit allowlist); `receipt/offline_replay.ex` @do_boundary
  edit is in L06's set? No: `receipt/offline_replay.ex` is owned here (single file, disjoint).
- Keeps `actuation_dedup: :off` falsifier for the offline replay chain by forging the double-actuation
  chain through the ledger instead of an opts downgrade (verdict M11 correction 3).
- Test: `test/ash_a2a/chicago/real_collaborators_test.exs` assertion -> `["ConsequenceKernel.execute/1"]`.

### L08 (wave 4) test conversion of direct-Dispatcher callers

- Owns the 29 test files referencing `Dispatcher.dispatch` (enumerate via `grep -rln` at start),
  including `rfc004_fence_test.exs`, `rfc004_agent_scope_test.exs`, `rfc004_authority_effect_kill_test.exs`,
  `chicago/brce_gate7_test.exs`, `ash_a2a_architecture_verifier_test.exs`, `ash_a2a_dispatcher_*`,
  `ash_a2a_cancel_inflight_test`, `ash_a2a_task_failed_state_test`, `ash_a2a_telemetry_ocel_*`,
  `ash_a2a_zai_concurrency_ocel_test`, `ash_a2a_plug_tenant_actor_test`, and
  `test/support/{fixture,multi_turn_fixture,jsonrpc_handler_fixture,tenant_actor_auth_fixture,
  receipted_dispatch}.ex`; NEW `sec_m01_lib_effect_sweep_test` skeleton with per-site allowlist.
- Rewrites scenario intent against the kernel; delete `put/take/admit` describe blocks.
- Excludes test files owned by another lane (`receipt_crash_window_fixture.ex` -> L10).

### L09 (wave 4) effector contract / consequence class

- Mechanism: M03 (phase A independent of kernel; strictness default true until L12).
- Owns: `skill.ex`, `dsl.ex`, `capability_index/compiler.ex`, `capability_index.ex` (implementation
  digest for M24), `transformers/build_capability_index.ex`, `effector/ash_action.ex` (relay from L05:
  class-vs-action-type guard), NEW `effector_contract.ex`, NEW `effector_contract/{derive,probe,test}.ex`,
  `lib/mix/tasks/ash_a2a.install.ex`, `lib/mix/tasks/ash_a2a.verify_architecture.ex`,
  NEW `test/support/sec_m03_fixtures.ex`.
- Rules: `derive/2` runs in the transformer; opaque preparation/manual/after_action -> `:unknown`;
  `:pure` additive; reuse `consequence_class_unknown` at runtime (DslError tag only at compile time).
- Tests: NEW `sec_m03_{read_side_effect,generic_observe_attestation,generic_observe_optin,
  class_action_type_mismatch,effector_contract,architecture_edge}_test`; must-update:
  `ash_a2a_agent_command_bus_test.exs:14`, `rfc004_agent_scope_test.exs:51` (L08 converts dispatch use;
  L09 owns only their observe-generic opt-in hunks, applied after L08 as declared relay).
- Blocked: SEC-M03-6 (observation receipts, L18), SEC-M03-7(d) (needs SecurityProfile, L12).

### L10 (wave 5) claims, fencing, authority wiring

- Mechanisms: M10, M11 (store/command_bus half), M12, M13, M05/M06 command_bus+agent hunks.
- Owns (wave 5): `command_bus.ex`, `agent.ex` (effect_instance_id threading, no authoritative Authority
  into Command), `receipt_store.ex`, `receipt_store/{memory,ekv,actuation_claim_lease,claim_lease}.ex`,
  NEW `receipt_store/generation.ex`, NEW `effect_claim.ex`, NEW `request_claim.ex`, NEW `replay_evidence.ex`,
  NEW `effect_outcome.ex`, `receipt.ex` (effect_instance_id in intended_effect, `execution_generation`,
  `finalize_checked/2`), `reconciliation.ex`, `receipt_outbox.ex` (M13 `supersedes?` clause,
  `recover_claim/3`), `test/support/receipt_crash_window_fixture.ex`.
- Rules: keep RFC-004 order REQUEST_CLAIMED > EFFECT_CLAIMED; request claim is a non-authoritative index;
  `begin_effect/4` placed at the existing execute_anchored site, after `pre_do_gate`; `:executing` not
  reclaimable; unresolved-unknown = `terminal_status == :unknown_outcome and metadata.outcome != :reconciled`;
  store commit takes explicit `actor:` opt, never read from the receipt; delete `:declared/:off` dedup
  for change/external_do; broker/opts/`admitted_by`/`standing_grant?` removal hunks in command_bus
  from L11's spec.
- Tests: NEW `sec_m10_*`, `rfc004_m12_*` (8), `rfc004_unknown_outcome_*` (5), `command_bus_hardening_test`
  edits (unknown replay -> typed refusal), `ash_a2a_actuation_identity_test` re-edit (relay from L01).
- Blocked: SEC-M10-6/7 kernel parts, SEC-M13 kernel-prepare gate, SEC-M12-8 clause on effector callers (L20).

### L11 (wave 5) authority broker, decision, fence

- Mechanisms: M04, M05, M06, M07 authority side.
- Owns: `authority.ex`, `authority/{grant,broker,decision,security_preflight}.ex`,
  `authority/broker/{in_memory,ekv}.ex`, NEW `authority_fence.ex`, NEW `authority/test_support.ex`
  (`mint/3`), `test/support/authority_grant_case.ex`, `ash_a2a_authority_*_test.exs`.
- Reuse existing `Authority.Decision` and `SecurityPreflight`; no second Decision type; ticket named
  `Authority.DecisionTicket` if needed. Broker new callbacks are `@optional_callbacks` with fail-closed
  fallback during migration. Unknown constraint keys fail closed except an evidence-only allowlist
  (e.g. `:external_idempotency_token`). `Authority.new/3` callers (~20 in chicago) migrate to
  `TestSupport.mint/3` in L20 sweep; L11 provides the API.
- Tests: NEW `sec_m04_*` (7), `sec_m05_authority_binding_test`, `sec_m05_mutation_test`,
  `sec_m05_architecture_authority_mint_test` (allowlist chicago/** only if flagged non-production),
  `sec_m06_*` (fence, epoch, edge_absent, refusal_mapping). Court preconditions: delete
  `:authority_broker` env with `async: false`.
- Stage A (now): kill `:none` -> ok, strict opts ignore, `rebound?` unseen -> mismatch, constraints stored at
  issue. Stage B (kernel-bound): SEC-M04-3,4(prepare/execute), SEC-M05-5,6,7,11, SEC-M06-1(injected after gate),2,7,10.

### L12 (wave 6) SecurityProfile + release closure + policy opts

- Mechanisms: M16, M24, plus the profile plumbing every other lane defers to.
- Owns: NEW `security_profile.ex`, NEW `security_profile/receipt_keyring.ex`, `application.ex` (boot
  `SecurityProfile.load!/0` + `SecurityPreflight.check!/0` as NEW boot edge), `mix.exs`, `config/*.exs`,
  `capability_release.ex` (delete `:legacy`, opts closure; `Closure.verify/1`, `binding_digest/1`, digest-pin
  in `select/2`), `info.ex`, `health.ex`, `kill_switch.ex` (path handed to L15), `command_bus.ex` (wave-6
  hunks: constant `:strict` dedup, profile kill classes, no `opts[:kill_switch]`, release binding),
  `agent.ex` (auth requirement from profile; `strict_observe_generic_actions` default true),
  `dispatcher.ex` (release guard via profile), NEW `test/support/security_profile_fixture.ex`,
  NEW `test/support/release_profile_fixture.ex`, `test/test_helper.exs`, `test/capability_release_test.exs`,
  `test/command_bus_kill_switch_test.exs`, `test/ash_a2a/kill_switch_durability_test.exs`,
  `test/ash_a2a/health/health_test.exs`, `rfc004_authority_effect_kill_test.exs` (relay from L08).
- Rules: `for_test/1` compiled only under `Mix.env == :test`; profile pinned in `:persistent_term`
  (tests `async: false`); `forbidden_opts` runs in Agent BEFORE `@dispatch_opt_keys` consumption;
  `Grant.policy/1` keeps a pure resolver for the chicago gate kind `authority_policy`.
- Tests: NEW `sec_m16_*` (7), `sec_m24_{default_strict,opts_override,tampered_closure,compile_injection,
  profile_artifact_tamper,card_equals_executable,mutation_court}_test`.
- Blocked: SEC-M16-8 (needs prepared digests, L04/L18), chicago hunks `plan_gates.ex:405`,
  `collaborators.ex:227/246`, `root_manifest_meta.ex:248` (L20 sweep).

### L13 (wave 7) closed callbacks + SafeExec (M19)

- Owns: NEW `callback_registry.ex`, NEW `safe_exec.ex` (capabilities: `:git_standing_ref,:git_head,
  :ps_comm,:ps_rss,:git_vendor,:graphlaw_node,:hddl_cli,:kill,:graphlaw_engine_probe,:wasm_pack,:wasmtime`),
  `a2a_transport/extended_card.ex`, `durability/durable_server.ex`, `topology/{presence,group}.ex`,
  `sa2a/graphlaw.ex`, `runtime_identity.ex`, `runtime_identity/execution.ex`, `planning/hddl_solver.ex`,
  `graph_law/{subprocess,runtime_b,wasmtime_runtime}.ex`, `graphlaw/{vendor,manifest}.ex`,
  `semantic/root_manifest/engine_probe.ex`, `telemetry/metrics.ex`, `semantic/machine_experience.ex`,
  `delivery/oban.ex` and `execution/flame.ex` (relay from L06), `receipt_outbox.ex` apply(store,...) hunk
  (relay item: goes to L15 as owner this wave; L13 supplies spec).
- Spark on_cancel behaviour check goes inside `AshA2A.Verify` (`lib/ash_a2a.ex`), owned here; no
  `verifiers/` dir; on_cancel is module-only, MFA/extra_args removed (already routed by L06).
- Tests: NEW `sec_m19_*` (extended_card, env_provider, graphlaw_pinned, git_argv, ps_pid, topology,
  atom_mint as regression guard) ; `sec_m19_no_dynamic_dispatch_court_test` (per-file allowlist).
- Phase A independent (SafeExec, validators, digest pin, provider removal); Phase B after L12
  (profile-resolved providers).

### L14 (wave 7) EndpointCapability + Network.Egress (M20)

- Owns: NEW `endpoint_capability.ex`, NEW `endpoint_capability_store.ex`, NEW `endpoint_policy.ex`,
  NEW `network/egress.ex`, NEW `network/llm_endpoint.ex`, `a2a_transport/{webhook_policy,push_config_rpc,
  push_config_store,push_delivery,plug,transport,task_events}.ex`, `telemetry/ocel_forwarder.ex`,
  `llm_profiles.ex`, `planning/semantic_synthesis.ex` (also the M18 `String.to_atom` hunk),
  `semantic/compiler.ex`, `effector/{push_webhook,ocel_export}.ex` (relay from L05),
  test files `ash_a2a_telemetry_ocel_forwarder*_test`, `ash_a2a_ocel_default_path_sink_test`,
  `a2a_transport/{webhook_policy,push_notification,ownership}_test`.
- Phase 0 (no deps): shared admit helper, `redirect: false`, pinned IP, header allowlist in OCEL post;
  `LLMProfiles.req_llm_opts!/1` key allowlist; drop `:req_llm_opts` merge. Phase 1 after L05/L12.
- Egress is verified by a kernel-minted seal (HMAC of prepared_digest), not a module-name check.
  OCEL ingest is `:external_do` only.
- Tests: NEW `security/m20_*` (10 courts; SEC-M20-8,10 BLOCKED on L10/L11/L12).

### L15 (wave 7) FileObject (M21)

- Owns: NEW `file_object.ex`, `receipt_outbox.ex` (wave 7 hunk: root, filename regex, list, no symlink),
  `standing_ref.ex` (also M19 git argv via SafeExec), `research/erc.ex` (also M19 git),
  `kill_switch.ex` (path), `receipt_store.ex`? no (L10). `spg_conformance.ex` (digest + `.corpus` roots + M11
  idempotency-key -> effect_instance_id; regenerate `CORPUS_DIGEST.sha256` via the projector),
  `lib/mix/tasks/ash_a2a.sa2a_conformance.ex`, `lib/mix/tasks/ash_a2a.standing_ref.ex`.
- Phase 1 without kernel/profile: FileObject.resolve/2, verify_at_use, static root registry,
  charset regex. Phase 2: kernel-only mint + `resource_envelope {root_id, object_id, op}`.
- Tests: NEW `sec/m21_*` (8; baseline witnesses against the unfixed effector first).

### L16 (wave 7) ContinuationScope / PackageStore (M17)

- Owns: NEW `semantic/continuation_scope.ex` (K = {principal_id, exact_subject, fingerprint}; task_id
  NOT in K), `semantic/package_store.ex`, `semantic/execution_package.ex`, `agent.ex` (wave-7 continuation
  hunks: derive closing command_id from principal + fingerprint, single `:continuation_not_found`, refuse
  anonymous in `dispatch_semantic` before compile), tests `semantic/package_store_bounds_test`,
  `ash_a2a_agent_semantic_replan_test`, `rfc004_agent_scope_test` (M17 assertions after L08).
- New tests: `rfc004_m17_continuation_namespace_test`, `semantic/package_store_scope_bounds_test`,
  `rfc004_m17_architecture_gate_test` (soft dependency on L20).

### L17 (wave 7) ResourceEnvelope + BudgetLedger (M22)

- Owns: NEW `resource_envelope.ex` (reuse `Semantic.Allocator.Budget` and `Semantic.Bounds`; do not
  invent a parallel algebra), NEW `budget_ledger.ex`, NEW `budget_ledger/{memory,ekv}.ex`, NEW `effect_lineage.ex`
  (carrier via `execution_context.ex`), `execution_context.ex`, `gall/closure/pipeline.ex`,
  `command_bus.ex` (wave-7 additive `bound_gate/3` in `pre_do_gate`; do not delete
  `preflight_plan_step`), `planning/preflight.ex`, NEW `test/support/sec_m22_effector_fixtures.ex`.
- Rules: reserve after revalidate + kill switch, refusal releases claim/anchor; observe counts against
  window only; `Command.metadata` keys `lineage/depth/max_*` refused (`envelope_override_refused`); the new
  adapter rule scopes to user effector modules only (reactor/flame adapters legitimately call `CommandBus.run`).
- Tests: NEW `sec_m22_*` (7); SEC-M22-5,6 BLOCKED on L05 `external_request`.

### L18 (wave 8) receipts: seal, binding, wire codec

- Mechanisms: M23, M18, M15 receipt-side readers.
- Owns: NEW `receipt_seal.ex`, NEW `consequence_kernel/receipts.ex`, `receipt/binding.ex` (JCS + HMAC,
  `@version 2`, dual-read v1), `receipt.ex` (kernel-only transitions, remove `:standing`), `postcondition.ex`
  (release-pinned verifier; pre-DO refusal hook in admission), `receipt/{replay,offline_replay,
  evidence_chain}.ex`, `execution_snapshot.ex` (decode boundary, M14 digest), NEW `wire/{codec,record,
  receipt,execution_snapshot,jcs}.ex`, NEW `lib/mix/tasks/ash_a2a.outbox.migrate.ex`, `receipt_store/{memory,ekv}.ex`
  (commit authentication, wave-8 hunk), `receipt_outbox.ex` (wave-8: seal key unification, JCS body),
  `command_bus.ex` (wave-8: commit verify, `mark_standing` removal, `receipt_opts` cleanup), `gall/command_receipt.ex`
  (relay from L02: standing derived), `semantic_projection.ex`, `reconciliation.ex` (relay from L10: kernel
  token + `terminal_status: :reconciled`), `authority.ex` `grant_token_id` (already L11; not touched).
- Prerequisite gate: enumerate every `Receipt` defstruct field type and property-test the Wire.Receipt round-trip
  before the cutover (crash-window anchors must stay decodable).
- Tests: NEW `rfc004_evidence_forgery_*` (6), `receipt_store/rfc004_commit_authentication_test`,
  `receipt/binding_jcs_identity_test`, `sec_m18_*` (outbox_hostile_bytes discriminates on hostile ETF with valid MAC),
  update all ETF-byte tests.
- Blocked: SEC-M23-2,3 until L12 profile + release-pinned verifier; SEC-M23-7 allowlist owned with L20.

### L19 (wave 8) standing derive (M15)

- Owns: NEW `standing/{derive,axes}.ex`, `semantic/standing.ex` (Ledger token), `semantic/peer.ex`, NEW
  `semantic/peer/outcome.ex` (keep map, add seal; readers updated same lane), `semantic/{admission,ir_admission_seal}.ex`,
  `planning/goal_facts.ex`, `conditional_commitment.ex` (readiness rename + JCS digest, M14 hunk here),
  `runtime_receipt.ex`, `semantic/{plan_projection,agent_card,falsifier_suite}.ex`, `planning/preflight.ex`
  fence rename (relay from L17), `spg_...` none. Per-artifact `standing:` fence renames go last.
- Rules: Derive is pure over projected axes; axis projectors ship PARTIAL over existing sources
  (`Receipt.terminal_status`, `Authority.admits?`, `Binding.check`, `DurabilityProbe`); `Receipt.standing/1` is a
  function not a field; legacy stored key ignored-and-recomputed with format_version bump (with L18).
- Tests: NEW `sec_m15_*` (7); SEC-M15-6 IR-forgery half is regression only; SEC-M15-7 BLOCKED on L05/L18.

### L20 (wave 9) per-row courts + static effector dependency-graph verifier

- Owns: `architecture_verifier.ex` and `architecture_verifier/adapters.ex` (relay from L06), NEW
  `architecture_verifier/network_egress.ex`, all `lib/ash_a2a/chicago/**` (relay from L07: `Authority.new`
  migration to `TestSupport.mint/3`, `Fx.read_back!` consumers in `courts/receipt_binding.ex`, `plan_gates`,
  `root_manifest_meta`, `replay.ex`, `receipt_binding_attestation.ex`, `chaos_reconciliation.ex` decode),
  `lib/ash_a2a/semantic/conformance.ex` (`:dynamic_apply` detector reuse), `priv/sa2a/chicago_mandatory_corpus.json`
  (mutation entries M05,M10,M11,M13,M22,M24), `lib/mix/tasks/ash_a2a.verify_architecture.ex` (relay from L09).
- Cross-cutting courts: SEC-M01-4 (ingress x denial matrix + positive controls), SEC-M01-7 (per-site allowlist
  for every `Ash.*`, `Req.post`, `apply(`, `System.cmd`, `Port.open`, `Code.eval*`, `String.to_atom`, `File.*`,
  `:dets.open_file`), SEC-M03-8, SEC-M04-6, SEC-M05-12, SEC-M08-8, SEC-M10-6, SEC-M15-5, SEC-M16-7,
  SEC-M18-6, SEC-M19-7, SEC-M20-7, SEC-M21-6, SEC-M22 adapter, SEC-M23-7.
- Static effector dependency-graph verifier: `mix xref graph --sink` over every `AshA2A.Effector.*` +
  raw-effector sinks (`Ash.create/update/destroy/run_action/read/stream!`, `Req`, `ReqLLM`, `:httpc`,
  `:gen_tcp.connect`) asserting sources == `[AshA2A.ConsequenceKernel]` (plus `Network.Egress` /
  `LLMEndpoint` / `SafeExec` / `FileObject` as declared sinks), AST-resolved (alias/import/apply literals);
  `Module.concat`/dynamic apply covered only by the runtime seal check (SEC-M01-1). Anti-vacuity: mutated scratch
  source dir made with `git archive` into a plain scratch dir (no worktree) must fail the verifier.
- Row-by-row acceptance table: one row per SEC-Mnn-k with status ALIVE/PARTIAL/BLOCKED, red-first
  output, and mutation twin; produces the manufacturing receipt.

## Hot-file relay (serial, wave order)

| file | owners in order |
|---|---|
| `lib/ash_a2a/command_bus.ex` | L06 (W4) -> L10 (W5) -> L12 (W6) -> L17 (W7) -> L18 (W8) |
| `lib/ash_a2a/agent.ex` | L06 (W4) -> L10 (W5) -> L12 (W6) -> L16 (W7) |
| `lib/ash_a2a/dispatcher.ex` | L06 (W4) -> L12 (W6, release guard) |
| `lib/ash_a2a/receipt_outbox.ex` | L04 (W2) -> L10 (W5) -> L15 (W7) -> L18 (W8) |
| `lib/ash_a2a/receipt.ex` | L10 (W5) -> L18 (W8) |
| `lib/ash_a2a/reconciliation.ex` | L10 (W5) -> L18 (W8) |
| `lib/ash_a2a/receipt_store/{memory,ekv}.ex` | L10 (W5) -> L18 (W8) |
| `lib/ash_a2a/receipt/{replay,offline_replay}.ex` | L18 (`offline_replay.ex` also L07 @do_boundary at W4: L07 first) |
| `lib/ash_a2a/effector/ash_action.ex` | L05 (W3) -> L09 (W4) |
| `lib/ash_a2a/effector/{push_webhook,ocel_export}.ex` | L05 (W3) -> L14 (W7) |
| `lib/ash_a2a/delivery/oban.ex`, `execution/flame.ex` | L06 (W4) -> L13 (W7) |
| `lib/ash_a2a/kill_switch.ex` | L12 (W6) -> L15 (W7) |
| `lib/ash_a2a/capability_release.ex`, `info.ex`, `health.ex` | L12 only |
| `lib/ash_a2a/authority.ex`, `authority/*` | L11 only |
| `lib/ash_a2a/semantic/refusal.ex` | L03 only |
| `lib/ash_a2a/architecture_verifier{,/adapters}.ex` | L06 (W4) -> L20 (W9) |
| `lib/ash_a2a/chicago/**` | L07 (W4) -> L20 (W9) |
| `lib/ash_a2a/planning/preflight.ex` | L17 (W7) -> L19 (W8) |
| `lib/ash_a2a/planning/semantic_synthesis.ex`, `semantic/compiler.ex` | L14 only |
| `lib/ash_a2a/spg_conformance.ex`, its corpus digest | L15 only |
| `lib/ash_a2a/conditional_commitment.ex`, `gall/command_receipt.ex` | L19 / L02 -> L18 (see rows above) |
| `mix.exs`, `config/*`, `application.ex` | L12 only (alias `verify.effector_graph` and kernel children in L12) |
| test `ash_a2a_actuation_identity_test.exs` | L01 (W1) -> L10 (W5) -> L12 (W6) |
| test `rfc004_agent_scope_test.exs` | L08 (W4) -> L09 -> L16 (W7) |
| `priv/sa2a/chicago_mandatory_corpus.json` | L20 only |

## Mechanism to lane map

| mech | lanes (in wave order) |
|---|---|
| M01 | L05, L06, L07, L08, L20 |
| M02 | L06, L05 (resolver), L12 (release digest) |
| M03 | L09 (+L05 classifier stub, L18 observation receipts) |
| M04, M05, M06 | L11, L10 (command_bus/agent hunks) |
| M07 | L06 (phase A), L11, L10; phase B anchor digests L05/L06 after L04 |
| M08 | L04 (a), L06 (b) |
| M09 | L04 (+L18 key unification) |
| M10, M12, M13 | L10 |
| M11 | L01, L10, L15 (spg idempotency) |
| M14 | L01, L02, L11, L12, L18, L19, L15 |
| M15 | L18 (readers), L19 |
| M16 | L12 |
| M17 | L16 |
| M18 | L18 (+L14 for `semantic_synthesis` atom fix, L20 for chicago decode) |
| M19 | L13 (+L02 planning, L06 on_cancel, L15 git in standing_ref/erc) |
| M20 | L14 |
| M21 | L15 |
| M22 | L17 |
| M23 | L18 |
| M24 | L12 (+L09 implementation digest) |

## Skeptic corrections carried into lane specs

- Anchor by function name; line numbers stale (command_bus +279, agent +141, receipt_outbox +90).
- Court vacuity: courts that only fail by `UndefinedFunctionError` need a ledger-rows/effect-counter
  assertion and a pre-fix witness (SEC-M08-1,3,4,6; SEC-M21-6,7; SEC-M24-3,5).
- Fixed-forward vacuous courts: M01-2 (arity 3..6), M02-5 (regression pin), M08-9 (rewrite to valid outbox entry +
  forged anchor input B), M10-1/3/7, M11-1/5/6, M12-1 (A passes fence before reclaim), M13-2 (delegating
  fault-injection store failing all unknown commits), M16-8 (needs L04/L18), M17-4, M18-1/4/7, M19-9,
  M20-1/2/9, M22-2, M23-4 (must set key/strict flag).
- Effector inventory additions: `Ash.stream!`, `Ash.bulk_*`, Oban, FLAME, durable_server, presence/group,
  extended_card, `receipt_outbox apply(store,...)`, chicago fixtures `Ash.create`.
- In-VM key custody: GenServer state, no `:persistent_term` (M01 verdict 5); in-VM adversary
  otherwise downgraded to "accidental-bypass only" and stated.
- `SecurityProfile`, `ConsequenceKernel`, `PreparedEffect` did not exist at HEAD: lanes ship the
  phase that does not depend on them first (stage A/phase 0/phase 1) and list the rest as BLOCKED.
- `SecurityPreflight` and `Authority.Decision` already exist (reuse). `admitted_by` and
  `opts[:authority_broker]` are two broker-substitution channels (both closed by L10/L11).

## Build roots and verify ladder

Per-lane build isolation: `MIX_BUILD_ROOT=_build-lane<N>`; deps shared read-only; never `deps.get`.

| lane | build root | lane | build root |
|---|---|---|---|
| L01 | `_build-lane01` | L11 | `_build-lane11` |
| L02 | `_build-lane02` | L12 | `_build-lane12` |
| L03 | `_build-lane03` | L13 | `_build-lane13` |
| L04 | `_build-lane04` | L14 | `_build-lane14` |
| L05 | `_build-lane05` | L15 | `_build-lane15` |
| L06 | `_build-lane06` | L16 | `_build-lane16` |
| L07 | `_build-lane07` | L17 | `_build-lane17` |
| L08 | `_build-lane08` | L18 | `_build-lane18` |
| L09 | `_build-lane09` | L19 | `_build-lane19` |
| L10 | `_build-lane10` | L20 | `_build-lane20` |

Verify ladder (cheapest high-information first; each step's real output pasted in the receipt):

1. Pre-fix witness: run each court on the unfixed subject; record the failing output.
2. `mix format --check-formatted` on owned files.
3. `mix compile --warnings-as-errors` under the lane build root.
4. Lane tests (owned test files only), then the lane's court files.
5. Mock ban: `grep -rn "unittest.mock\|Mox\|Mock(\|MagicMock\|patch(\|monkeypatch"` over lane test dirs (expect 0;
   Elixir equivalents `Mox|:meck|mock(` also 0) plus the named-fake statement for any double.
6. `mix ash_a2a.verify_architecture` and `mix ash_a2a.effector_graph`.
7. `mix credo --strict` (and dialyzer where configured).
8. Coordinator, lane-ordered (L01..L20) on the merged tree: full `mix test` serialized (`async: false` profile
   tests), then mutation courts (`mix ash_a2a.chicago.mutate`), then the L20 row table.
9. Re-verify identical check after any repair; "Loaded/installed" is O until the real command shows it.

Status vocabulary per lane: ALIVE / PARTIAL / BLOCKED(depends lane) / REFUSED / UNVERIFIED. Pre-existing
failures (dirty RFC-004 tree) must be separated from failures introduced by a lane in every report.

## Orphans (files no lane owns, or ownership undecided)

- `lib/ash_a2a/receipt/offline_replay.ex` Port.open at :1173 (SafeExec routing) - assign to L13 as
  relay behind L07/L18 or allowlist with justification.
- `lib/ash_a2a/graph_law/wasm.ex` (phash2 cache key) and `semantic/refusal.ex:827` phash2 - allowlist as cache keys.
- `lib/ash_a2a/topology/*`, `delivery/*`, `execution/*` apply sites not routed by any kernel effector: needs an
  explicit class (effector / observe-pure / allowlisted) decision per site (L20 allowlist source).
- `lib/ash_a2a/semantic/machine_experience.ex` `safe_apply`, `telemetry/metrics.ex` apply: assigned to L13 but
  classification decision pending (likely observe-pure allowlist).
- `lib/mix/tasks/ash_a2a.install.ex` String.to_atom (codegen plane): excluded by rule; needs literal validation
  (no owner).
- `lib/ash_a2a/agent.ex:101` `Code.eval_quoted` (compile-time macro): allowlisted, no owner.
- `lib/ash_a2a/chicago/fresh_consumer.ex:996`, `chicago/mutation.ex:425`, `chicago/release/composition_lock.ex:119,161`
  (`String.to_atom`, `Code.eval_file`): L07/L20 allowlist.
- `docs/architecture` and verifier text mentioning `Dispatcher.dispatch/5,6`: doc updates, no owner
  (append to L06 as docs-only).
- `priv/spg_conformance/v26.9.27/CORPUS_DIGEST.sha256`: regenerate only via the projector after
  L15 changes `spg_conformance.ex` (untracked in the tree now; owned by the in-flight lane until P0).
- Effect policy items unowned: SecurityProfile field schema for network/file roots (contract needed by
  L14/L15), `Command` fields `plan_identity`/`authority_grant_id` (M14 phase 2, M03 owner absent).
- Credential storage for webhook tokens (`credential_ref`, M20): UNSUPPORTED until an owner is named.
- `test/ash_a2a/rfc004_outbox_integrity_test.exs` and `rfc004_authority_effect_kill_test.exs` are untracked
  in-flight files: owner is the RFC-004 lane until P0, then L04 / L08 / L12 as in the tables.

## See Also

- `docs/rfc/RFC-SA2A-004-v26.9.28.md` (sec 4, 5, 9, 12, 21, 28)
- `docs/rfc/RFC-SA2A-003` implementation-derived protocol (bypass list B1-B11)
- `~/.claude/rules/same-checkout-fanout.md`, `~/.claude/rules/fanout-first.md`
- `~/.claude/rules/testing-chicago-style.md`
