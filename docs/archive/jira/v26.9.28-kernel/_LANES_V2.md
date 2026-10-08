# _LANES_V2

Executable lane map V2 for the C1 kernel (L01-L20), RFC-SA2A-006 X1-X4, and the fleet
composition adapters (G, A1-A4). Subject: `ash_a2a@9cda21c`. Supersedes the wave and ownership
tables of `_LANES.md` (kept as history, not edited). Written 2026-09-28 from 24 read-only lane
plans plus 12 fleet-repo verifications. Nothing here was executed: every command is DERIVED
and every "OBSERVED" tag refers to a read at `9cda21c`.

Totals: 29 lanes, 10 waves (W1a, W1b, W2-W9 in ash_a2a; W10 cross-repo), 8 cross-repo edits.

## Quick reference

- Path shorthand: `LIB/` = `lib/ash_a2a/`, `T/` = `test/ash_a2a/`, `NEW` = file absent at HEAD.
- Every lane also owns `docs/jira/v26.9.28-kernel/handwritten/<lane>.md` (its own residue
  ledger fragment; aggregated into `HANDWRITTEN.md` by L20 in W9). No shared ledger file.
- Build root per lane: `MIX_BUILD_ROOT=_build-lane<id>` (`/_build-*/` is already ignored,
  OBSERVED `.gitignore:6`). Never `deps.get` from a lane; `deps/` is shared read-only.
- Agents never run git state commands. The coordinator commits per lane, in lane order.
- One canonical checkout per repository, normal branches, no worktrees, no shadow copies.
  Mutation twins use `git archive HEAD | tar -x -C <plain scratch dir>`.
- Test-DB lease: only one process runs DB-touching `mix test` at a time. Lanes compile and run
  pure tests on their own build root; the coordinator runs gates serialized (see Wave gates).
- New court tests live in `T/` as `sec_m<NN>_*.exs` or under `T/sec/`; the lane plans'
  `test/security/` directory is replaced by `T/sec/` (it does not exist at HEAD).
- Status vocabulary: OBSERVED, DERIVED, UNVERIFIED, BLOCKED(lane), NEW PACK TEMPLATE REQUIRED.

## Preconditions (Wave 0 gate G0)

All must hold before any lane is dispatched. None is satisfied as of this writing.

1. Tree clean. OBSERVED dirty: 15 modified files (`LIB/chicago/{abstract_code,collaborators,
   fresh_consumer,mutation}.ex`, `LIB/chicago/mutation/catalog.ex`,
   `LIB/chicago/courts/crash_reconciliation.ex`, `LIB/chicago/fixtures/{chaos_reconciliation,
   mutation_harness}.ex`, `LIB/receipt/{evidence_chain,offline_replay}.ex`,
   `LIB/semantic/conformance.ex`, 3 tests, `test/support/chicago_selftest.ex`) and untracked
   `LIB/beam_file.ex`. The fixer commits them (fix forward, no reset) after reading
   `beam_file.ex`: if it loads NIFs or ports it is recorded against RFC-006 s23.
2. CI green at the exact commit that closes item 1 (`gh run list --commit <sha>`); UNVERIFIED now.
3. The perf workflow is finished (it uses the test DB and edits workflow/config/test files)
   and `/workflows` shows no other run on this repo.
4. RFC-004 lanes A-F are committed: OBSERVED `fd6f55d` is in the log. The `_LANES.md` Wave-0
   dirty list (`command_bus`, `authority`, `agent`, ...) is stale: those files are clean.
5. Baseline red set recorded. The pre-existing red set is UNVERIFIED (never measured).
   Step: one full `MIX_BUILD_ROOT=_build-lane00 mix test` on the clean tree, failures written
   to `docs/jira/v26.9.28-kernel/BASELINE_RED.txt` and committed. Every gate below means
   "failures are a subset of BASELINE_RED, except tests a lane converts on purpose".
6. Known by-design reds (turn red when the owning lane lands, converted in that lane):
   ETF-byte tests (`receipt_outbox_hardening`, `rfc004_outbox_integrity`,
   `receipt_store_ekv*`, `store_hardening`) at L04/L18; `determinism_test.exs:13,17` and
   `semantic_ontology_canonical_digest_test` at L02; legacy put+dispatch tests at L06/L08.
7. Toolchain: `:jcs ~> 0.2` present in `deps/` (mix.exs:376); `.tool-versions` pins erlang
   27.2.4. Lane G additionally needs `cargo` and `libclang` (ggen_igniter Rustler NIF).
8. Fleet repos are fetched by the operator with normal `git fetch`/fast-forward, not by a lane:
   `~/beam4pm` (local `e3d4f462` is stale vs remote `e7d64a01`); `~/ash_r2rml` is consumed at
   `d4971a4` (origin/main), never at the working checkout `e03adfe`.
9. The coordinator adds `docs/jira/v26.9.28-kernel/RESOLUTIONS.md` addenda A-C (below) before
   W1a. Otherwise L03 cannot register the X/A-lane codes.

## Addenda pinned in RESOLUTIONS.md before W1a

### Addendum A: reserved refusal codes (registered by L03 in W1a)

Classes are assigned by L03 from the s4 vocabulary. Names are DERIVED from RFC-006 and the
lane plans; RFC-006 s13-s16 text was not re-read end to end, so names are UNVERIFIED.

```text
certificate_{missing,malformed,signature_invalid,alg_unsupported,expired,subject_mismatch,
  digest_mismatch,policy_epoch_stale,generation_stale,replayed}   authority_service_unavailable
x3_{quorum_insufficient,signer_revoked,signer_expired,signature_invalid,signer_duplicate,
  domain_not_independent,epoch_stale,algorithm_unsupported,algorithm_not_admitted}
budget_children_exceed_parent  cost_exceeds_budget  allocation_advisory_refused
vkg_authority_not_none  vkg_standing_not_admissible  vkg_digest_invalid  vkg_catalog_unbound
planner_timeout  planner_output_oversize  planner_input_oversize  planner_identity_missing
graphlaw_wasi_unsupported  graphlaw_wasi_artifact_untrusted  suite_unsupported
```

### Addendum B: pinned contracts

- Effect record contract: `evidence_id`, `subject_digest`, `source_bindings`, authority ceiling
  `NONE` (A1). Evidence never confers authority; a PreparedEffect digest that references it
  must be signed by X2.
- `Actuation.identity/2` keeps returning a struct in W1a; `identity_checked/2` is added. L10
  migrates callers in W5 (see conflict C-03).
- ConsequenceKernel API preserves the `prepare / checkpoint / seal` plus `idempotency_key`
  shape so `Xaas.Actuation` becomes a thin adapter (W10).
- Kernel exposes an in-DB effect class (sealed in the caller's transaction) and an external
  class (Actuator only).
- Signature suites: `ed25519` mandatory; `mldsa65` optional and gated. OTP 27.2.4 (pinned)
  lacks `:crypto` ML-DSA (OBSERVED crypto 5.5.2); OTP >= 28.3 has it. Unsupported suite =
  typed `suite_unsupported`, never a fallback. Bumping `.tool-versions` is an operator
  decision outside this map.
- RFC-006 s23 carve-out: OTP-shipped `:crypto` verify is permitted in the kernel; third-party
  NIFs and ports are not. `wasmex` (mix.exs:400) stays as a recorded exception until retired.

### Addendum C: canonical digest form

`AshA2A.Identity.Canonical` (JCS, `sha256:<64hex>`) is the only digest scheme crossing a trust
boundary. VKG digests (`ash_r2rml`) are treated as opaque O. `SourceIdentity.sha256`
(`term_to_binary`) never crosses the boundary.

## Waves and hard gates

| Wave | Lanes | Needs gate |
|------|-------|-----------|
| W1a | L01, L03 | G0 |
| W1b | L02 | G1a |
| W2 | L04, G, X1a | G1b |
| W3 | L05, X3 | G2 |
| W4 | L06, L07, L08, L09 | G3 |
| W5 | L10, L11 | G4 |
| W6 | L12, X1b, X2, X4 | G5 |
| W7 | L13, L14, L15, L16, L17 | G6 |
| W8 | L18, L19, A1, A2, A3, A4 | G7 |
| W9 | L20 | G8 |
| W10 | cross-repo adoption | G9 |

Within a wave, lanes own disjoint files. Where two lanes edit one file it is a relay file
(next section) and the coordinator lands hunks in the stated order, anchored by function
name, never by line number.

### Gate procedure (coordinator, serialized, holds the test-DB lease)

```bash
cd /Users/sac/ash_a2a && pwd && git status --porcelain | wc -l   # expect 0 before the gate
export MIX_BUILD_ROOT=_build-gate
mix compile --warnings-as-errors
mix format --check-formatted
mix test <gate set>                       # then the full suite: failures subset of BASELINE_RED
mix ash_a2a.verify_architecture           # from G4 on
mix ash_a2a.chicago                       # from G4 on
grep -rnE "Mox|:meck|Mock\(|patch\(|monkeypatch" test lib/ash_a2a/chicago   # expect 0 matches
```

Red-first rule: each court's failing output on the unfixed subject is captured before the fix.
A court whose dependency lane is absent is listed BLOCKED(lane) and is never counted green.

### Gate sets

- G1a: `sec_m14_canonical_identity`, `sec_m14_no_beam_serialization_in_identity`,
  `sec_m14_canonical_vectors`, `sec_m11_*`, `refusal_closure_codes`, `semantic_refusal`,
  `command_fingerprint_determinism`, `actuation_identity`, `execution_identity` tests.
- G1b: `sec_m14_no_beam_serialization`, `sec_m14_l02_site_digest`, `gall/closure/determinism`,
  `semantic_canonical_*`, `semantic_ontology_canonical_digest`, `receipt_s31_fields`,
  `chicago/offline_replay`.
- G2: `prepared_effect`, `prepared_record_codec`, `sec_m08_forged_preparation`, `sec_m09_*`,
  `rfc004_outbox_integrity`, `receipt_outbox_*`; lane G: `mix ggen_igniter.verify --pack
  sa2a_kernel`, `doctor --strict`, `plan` all unchanged, `replay --verify-only`,
  `git diff --exit-code lib/ash_a2a/kernel/generated`; X1a: `(cd sa2a_wire && mix test)`.
- G3: `sec_m01_*` (5 files), `effector_graph` task test; X3: `(cd signer_registry && mix test)`.
- G4: `sec/m02_*`, `sec_m07_*`, `sec_m19_on_cancel_closed`, `sec_m03_*`, the 29 converted
  suites of L08, `chicago/l07_*`, `chicago/real_collaborators`, `chicago/brce_gate7`,
  `rfc004_fence`, `architecture_verifier*`; `mix ash_a2a.chicago` after court re-pin.
- G5: `sec_m10_*`, `rfc004_m12_*`, `rfc004_unknown_outcome_*`, `sec_m04_*`, `sec_m05_*`,
  `sec_m06_*` (Stage A subset), `authority_*`, `command_bus_hardening`.
- G6: `sec_m16_*`, `sec_m24_*`, `capability_release`, `kill_switch_durability`, `health`,
  `x1_*`; `(cd authority_service && mix test)`; `(cd actuator && mix test)`.
- G7: `sec_m19_*` (registry, env, argv, pid, topology, atom, static), `sec_m20_*` phase 0 and 1,
  `sec_m21_*`, `rfc004_m17_*`, `package_store_scope_bounds`, `sec_m22_*`.
- G8: `sec_m18_*`, `rfc004_evidence_forgery_*`, `sec_m15_*`, `receipt/binding_jcs_identity`,
  `wire/receipt_roundtrip_property` (prerequisite gate for the wire cutover), commit
  authentication, A1-A4 suites.
- G9: all L20 courts, full chicago, `mix ash_a2a.effector_graph`, `sec_row_table`,
  `mandatory_corpus.complete?`, SEC-X4-12 with X2 and X4 releases started as OS processes,
  full suite equals baseline minus fixed, manufacturing receipt validated by
  `python3 ~/.claude/dfcm/validate_receipt.py <receipt.json>`.

## Relay files (the only files with more than one writer)

Order is strict. A later lane starts from the earlier lane's commit.

| File | Relay order |
|------|-------------|
| `LIB/command_bus.ex` | L06(W4) > L10(W5) > L12(W6) > L17(W7) > L18(W8) |
| `LIB/agent.ex` | L06(W4) > L10(W5) > L12(W6) > L16(W7) |
| `LIB/dispatcher.ex` | L06(W4) > L12(W6) |
| `LIB/consequence_kernel.ex` | L05(W3) > L10(W5) > X1b(W6) > L17(W7) > L18(W8) |
| `LIB/receipt_outbox.ex` | L04(W2) > L10(W5) > L15(W7) > L18(W8) |
| `LIB/receipt.ex`, `reconciliation.ex` | L10(W5) > L18(W8) |
| `LIB/receipt_store/{memory,ekv}.ex` | L10(W5) > L18(W8) |
| `LIB/kill_switch.ex` | L12(W6) > L15(W7) |
| `LIB/semantic/conformance.ex` | L04(W2) > L20(W9) |
| `LIB/semantic/execution_package.ex` | L02(W1b) > L16(W7) |
| `LIB/planning.ex` | L02(W1b) > A3(W8) |
| `LIB/planning/preflight.ex` | L17(W7) > L19(W8) |
| `LIB/gall/command_receipt.ex` | L02(W1b) > L18(W8) |
| `LIB/conditional_commitment.ex` | L19(W8) > L18(W8, after L19 commit) |
| `LIB/delivery/oban.ex`, `execution/flame.ex` | L06(W4) > L13(W7) |
| `LIB/verify.ex` | L06(W4) > L13(W7) |
| `LIB/architecture_verifier{,/adapters}.ex` | L06(W4) > L20(W9) |
| `LIB/chicago/**`, `receipt/offline_replay.ex` | L07(W4) > L18(W8, offline_replay) > L20(W9) |
| `LIB/effector/ash_action.ex` | L05(W3) > L09(W4) |
| `LIB/effector/{push_webhook,ocel_export}.ex` | L05(W3) > L14(W7) |
| `LIB/effector/on_cancel_hook.ex` | L05(W3) > L13(W7) |
| `LIB/consequence_kernel/refusal_codes.ex` | L03(W1a) > G(W2, becomes GENERATED) |
| `lib/mix/tasks/ash_a2a.verify_architecture.ex` | L09(W4) > L20(W9) |
| `lib/mix/tasks/ash_a2a.effector_graph.ex` | L05(W3) > L20(W9) |
| `lib/mix/tasks/ash_a2a.chicago.mutate.ex` | L07(W4) > L20(W9) |
| `priv/sa2a/chicago_court_manifest.json` | L07(W4 re-pin) > L20(W9 re-pin) |
| `mix.exs`, `mix.lock` | L12(W6) plus G(W2, lock only) plus L12 hunks from L05, X1 |

Files owned by exactly one lane and never relayed: `LIB/semantic/refusal.ex` (L03, and L03
does not edit it, see C-02), `priv/sa2a/chicago_mandatory_corpus.json` (L20),
`application.ex`, `config/*` (L12), `LIB/authority.ex` and `LIB/authority/**` (L11).

## Conflict register (resolutions applied)

- C-01 `command_bus.ex`, `agent.ex`, `consequence_kernel.ex`: strict relay tables above; hunks
  anchored by function name. L11's broker-removal hunks in `command_bus.ex` are specs applied
  by L10 in W5.
- C-02 `refusal.ex`: `_LANES.md` says L03 appends to `@mapping`; RESOLUTIONS s4 says never.
  Resolved for RESOLUTIONS: L03 ships provider module `RefusalCodes` (and
  `RefusalCodes.Authority` for Addendum A). `@mapping` wins on conflict (refusal.ex:787,817),
  so a shadowing code silently keeps the old class; court SEC-L03-2 pins class equality.
- C-03 `Actuation.identity/2` shape change breaks `command_bus.ex` (L10, W5): L01 keeps
  `identity/2` struct-returning and adds `identity_checked/2`; L10 migrates callers.
- C-04 L01 and L02 shared W1 but L02 needs `Identity.Canonical`: split into W1a and W1b.
- C-05 `command_bus.ex:164-175` duplicates provider codes: deletion moved from L03 to L06.
- C-06 `KeyCustody` had no owning lane: L04 owns `LIB/key_custody.ex` as a pure module with
  explicit key arguments; supervised wiring is L12/L18. Interim `integrity_key/0` env read
  stays until then.
- C-07 `dispatcher.ex` class guard listed by RESOLUTIONS but L09 does not own the file: guard
  lives only in `effector/ash_action.ex` (L09). No dispatcher hunk for M03.
- C-08 `ash_a2a.effector_graph.ex` planned NEW by both L05 and L20: L05 owns the task
  (literal-edge verifier); L20 owns `architecture_verifier/effector_graph.ex` (xref layer) and
  extends the task in W9. Alias `verify.effector_graph` stays in L12's `mix.exs`.
- C-09 Certificate verifier location: X1 planned it in `lib/` while X4 must not depend on
  `:ash_a2a`. Resolved: shared pure library `sa2a_wire/` (X1), path dep of the kernel, X2, X3,
  X4. Kernel keeps only `authority_client.ex`.
- C-10 Unowned files assigned: `chicago_court_manifest.json` (L07/L20),
  `architecture_verifier/chicago_rollup.ex` (L20), `ash_a2a_command_bus_duplicate_action_names`
  test (L08), `LIB/semantic_projection.ex` (L18), `chicago/standing_receipt.ex` and
  `chicago/bench/b1_admission.ex` (L20), `command_bus.ex:1416` standing stamp (L18).
- C-11 `graphlaw/manifest.ex` uses `b3sum`, absent from SafeExec's list: L13's closed table
  is 13 entries: the 11 planned plus `:b3sum` and `:cmca_worker` (needed by A4).
- C-12 `rfc004_authority_effect_kill_test.exs`: L08 has zero `Dispatcher.dispatch` hits in it;
  ownership moves to L12 (relay from L08 dropped).
- C-13 `test/command_bus_kill_switch_test.exs` named by the map does not exist: L12 creates it
  as the SEC-M16 kill-class court home.
- C-14 Lane text path errors corrected: `verify.ex` (not `lib/ash_a2a.ex`) for on_cancel;
  `test/ash_a2a_receipt_s31_fields_test.exs` (root of `test/`); chicago fixtures are
  `LIB/chicago/fixtures/{plan_gates,root_manifest_meta,receipt_binding_attestation,replay}.ex`,
  not `courts/`; `test/ash_a2a_agent_command_bus_test.exs` is at `test/` root.
- C-15 `hilt/work_order.ex` may contain no digest site (only `inspect` in raise text): L02
  reads first and drops it from ownership if none.
- C-16 In-flight RFC-004 tests (`rfc004_spg_independence`, `rfc004_outbox_integrity`,
  `rfc004_authority_effect_kill`) are not edited by L15; L15 adds new files under `T/sec/`.
- C-17 Generator collision: G takes over `refusal_codes.ex` and vectors only by relay after
  L03/L01 land, with a byte-equality court; `.ggen_igniter/manifest.json` has a single writer
  (G) and `--on-stale refuse` only.
- C-18 `consequence_kernel.ex` execute-step slots (claims L10, cert X1b, budget L17, receipt
  seal L18) are listed as a relay so no lane rewrites another's step.
- C-19 A2 must not extend `graph_law/runtime.ex` (bound to five bindgen exports, no owner):
  A2 forks a new behaviour instead, and touches none of L13's `graph_law/*` files.
- C-20 A3 delegates the spawn to L13's SafeExec `:hddl_cli`; A3 owns only the wrapper and
  `native/hddl_cli`, so `planning/hddl_solver.ex` stays L13-only.

## Generator protocol

Source of truth for static kernel surface is one consumer-local pack, authored by lane G:
`priv/ggen/sa2a_kernel/{pack.toml,ontology.ttl,gates/*.rq,verify/*.unbound.rq,
verify/cardinality.json,templates/*.eex}` (precedent layout: `priv/ggen/ash_a2a/`, OBSERVED).
There is no `priv/ggen/kernel` in ggen_igniter (FALSE claim, see F29) and no marketplace pack
emits kernel Elixir (F27, F28). Every lane before G hand-writes its static surface and records an
`UNSUPPORTED(generator-capability)` row in its own `handwritten/<lane>.md`. Lanes after G consume
generated output where a template exists.

Commands (dev only, `cwd /Users/sac/ash_a2a`, lane G only, DERIVED not run):

```bash
export MIX_ENV=dev MIX_BUILD_ROOT=_build-laneG
mix ggen_igniter.verify --pack sa2a_kernel --json
mix ggen_igniter.doctor --pack sa2a_kernel --strict
mix ggen_igniter.plan   --pack sa2a_kernel --json          # every item plan_unchanged? == true
mix ggen_igniter.sync   --pack sa2a_kernel --for-each modules --engine oxigraph --on-stale refuse
mix ggen_igniter.replay .ggen_igniter/receipts/<date>.jsonl --verify-only --json
git diff --exit-code lib/ash_a2a/kernel/generated
```

Rules: generated files start with `# GENERATED by ggen_igniter from priv/ggen/sa2a_kernel`;
templates use `--engine oxigraph` row shapes (`<IRI>` and typed literals) and strip term syntax;
no `sh_before/sh_after` and no `--allow-sh`; gates ship `verify/cardinality.json` because plain
gates fail open on one row; generated output is committed so prod has no NIF (ggen_igniter stays
`only: :dev`, mix.exs:242). The replay receipt must also cite the ggen_igniter SHA
(`R_missing_identity` otherwise). NEW PACK TEMPLATES REQUIRED (none exist): constructor-only
struct, refusal-code table, product-state derivation, security-profile constants, vector loader,
envelope defaults, certificate schema.

## Lane specifications

### L01 identity and effect instance (W1a)

- Owns: `LIB/identity/canonical.ex` NEW, `identity/canonical/{encodable,migration}.ex` NEW,
  `LIB/effect_instance.ex` NEW, `priv/identity/canonical_vectors.json` NEW, `LIB/identity.ex`,
  `command.ex`, `actuation.ex`, `execution_identity.ex`, `transport/principal.ex`, tests
  `sec_m14_*` (3), `sec_m11_*` (3), edits to `command_fingerprint_determinism` and
  `actuation_identity` tests.
- Split: generated (later, by G): vectors, schema-tag constants. Handwritten: normalize/encode,
  Encodable protocol, migration, EffectInstance, all hunks. Vectors are seeded by hand from
  RFC 8785 cases now (NEW PACK TEMPLATE REQUIRED: `sa2a-identity-vectors`).
- Fleet reuse: `:jcs` dep only (no fleet JCS exists, OBSERVED grep); independent recompute with
  python3 stdlib in the vectors court (named skip when absent). `mac/3` ships UNSUPPORTED until
  KeyCustody (L04/L18).
- Courts: SEC-M14-1..4, SEC-M11-A..C. Fingerprint output changes to `sha256:<hex>`; readers
  outside L01 are relayed to L10/L18/L20, and `identity/2` stays struct-returning (C-03).
- Deps: G0. Soft: L03 (plain atoms until it lands). Build: `_build-lane01`. Repo: ash_a2a.

### L02 digest site conversion (W1b)

- Owns 24 sites: `LIB/planning.ex`, `semantic/{feedback,source,planning_ir,execution_package,
  unknown,allocator,bounded_production,ontology,meta_admission,envelope,canonical_term_digest}.ex`,
  `semantic/hook_reactor/{intent,hook}.ex`, `evidence/class.ex`, `capability_index/changelog.ex`,
  `architecture_envelope.ex`, `architecture/standing_court.ex`, `equilibrium/switchboard.ex`,
  `saga_control.ex`, `gall/{process_intervention,command_receipt,process_autonomics}.ex`,
  `gall/closure/determinism.ex`, `hilt/work_order.ex` (C-15); tests `gall/closure/determinism`,
  `semantic_canonical_*`, `semantic_ontology_canonical_digest`, `receipt_s31_fields`,
  `chicago/offline_replay` (vector update lands after the dirty tree is committed);
  NEW `sec_m14_no_beam_serialization`, `sec_m14_l02_site_digest`.
- Split: handwritten (per-site schema tag and fields); a codemod pack
  `sa2a-canonical-digest-site` is NEW PACK TEMPLATE REQUIRED but not built here.
- Fleet reuse: `semantic/canonical_term_digest.ex` as differential oracle.
- Courts: L02-C1..C6. Behavior changes to record: tuples and integral floats refused, atom and
  string keys equal, stored bare-hex digests refused or migrated.
- Deps: L01 hard, L03 for typed codes. Build: `_build-lane02`. Repo: ash_a2a.

### L03 refusal registry (W1a)

- Owns: `LIB/consequence_kernel/refusal_codes.ex` NEW (~120 s4 codes plus Addendum A),
  `LIB/consequence_kernel/refusal_codes/authority.ex` NEW, `T/refusal_closure_codes_test.exs` NEW.
  Does not edit `semantic/refusal.ex` (C-02) or `command_bus.ex` (C-05).
- Split: handwritten bootstrap now; G regenerates from an RDF `RefusalCode` class in W2
  (NEW PACK TEMPLATE REQUIRED: `refusal-code-registry`, plus a JSON projection for X2/X4).
- Fleet reuse: `portable-consequence-protocol-pack` vocabulary; igniter-task-pack
  `030_refusals.rq` as gate shape.
- Courts: SEC-L03-1..6, including doc parity against the RESOLUTIONS s4 table on disk and a
  real `classify/1` call for codes claimed "already mapped" (UNVERIFIED which are).
- Deps: G0. Build: `_build-lane03`. Repo: ash_a2a.

### L04 PreparedEffect, store, journal integrity (W2)

- Owns: `LIB/prepared_effect.ex`, `prepared_effect_store.ex`, `prepared_record_codec.ex`,
  `key_custody.ex` (C-06) all NEW; `LIB/receipt_outbox.ex`, `receipt_outbox/reconciler.ex`,
  `semantic/conformance.ex` (probe and module names only; preserve the dirty BeamFile hunks);
  tests `sec_m09_*` (5), `sec_m08_forged_preparation`, `prepared_effect`,
  `prepared_record_codec`, edits to `receipt_outbox_hardening`, `receipt_outbox_reconciler`,
  `rfc004_outbox_integrity`.
- Split: struct and field table generated later by G (NEW PACK TEMPLATE REQUIRED:
  constructor-only struct); codec, store, hunks handwritten. Domain-separated MAC with path
  identity; no `term_to_binary` in the prepared journal.
- Fleet reuse: `portable-consequence-protocol-pack` vectors for digest and framing;
  `:jcs`; `ReceiptOutbox` atomic-write pattern.
- Courts: SEC-M09-1..5, SEC-M08-5, SEC-M08-2c, PE-1, PE-2. BLOCKED(L05/L06/L12): SEC-M08-1,3,4,
  6,7; stale-epoch and rotation arms. Tests set keys via `Application.put_env` in-test.
- Deps: L01, L03. Build: `_build-lane04`. Repo: ash_a2a.

### L05 ConsequenceKernel and effectors (W3)

- Owns NEW: `LIB/consequence_kernel.ex`, `consequence_kernel/token.ex`, `effector.ex`,
  `effector/{ash_action,on_cancel_hook,push_webhook,ocel_export}.ex`,
  `lib/mix/tasks/ash_a2a.effector_graph.ex`, `test/support/effect_probe_effector.ex`,
  `T/sec_m01_{effector_forgery,ambient_anchor,effector_graph,observe_mislabel,
  replay_concurrency}_test.exs`.
- Split: effector skeletons and inventory table generated later by G; kernel GenServer,
  11-step execute order, HMAC token custody, effector bodies handwritten. W3 is copy-not-delete:
  Dispatcher still holds the Ash calls until L06.
- Fleet reuse: `brce_anchor.ex` telemetry shim; Ash code from `dispatcher.ex run_skill`;
  `portable-consequence-protocol-pack` vectors as an external wire court (needs an executable
  wrapper, optional).
- Courts: SEC-M01-1,2 (partial),3,6, replay-concurrency. BLOCKED: SEC-M01-4,7 (L20),
  SEC-M01-5 (L09).
- Deps: L01, L03, L04. Build: `_build-lane05`. Repo: ash_a2a.

### L06 dispatch inversion (W4)

- Owns: `LIB/dispatcher.ex`, `brce_anchor.ex`, `agent.ex` (W4 hunks), `command_bus.ex` (W4),
  `reactor/execute_command.ex`, `execution/flame.ex`, `delivery/oban.ex`,
  `delivery/oban_authority.ex`, `architecture_verifier.ex`, `architecture_verifier/adapters.ex`,
  `context_resolver.ex` (only if needed), `verify.ex` (on_cancel routing, C-14), plus the
  `command_bus.ex:164-175` duplicate-code deletion (C-05); NEW `T/sec/m02_*` (2), `T/sec_m07_*`
  (6), `T/sec_m19_on_cancel_closed`, `test/support/effector_probe_fixture.ex`.
- Split: forbidden-opts list and removed-arity table become a generated constant later
  (NEW PACK TEMPLATE REQUIRED: `sa2a-forbidden-opts`); control-flow inversion handwritten.
- Fleet reuse: existing `counting_actuator_fixture`, `authority_probe_fixture`,
  `crashing_dispatch_fixture`; architecture_verifier AST helpers.
- Courts: SEC-M02-1..5, SEC-M07-1..7, SEC-M19 on_cancel. Removes `Dispatcher.dispatch/3..6`
  and `BrceAnchor.put/take/clear`; the suite is red until L07/L08 land, so the coordinator commits
  L06, L08, L07, L09 as one atomic sequence before running G4.
- Deps: L01, L03, L04, L05. Build: `_build-lane06`. Repo: ash_a2a.

### L07 chicago boundary (W4)

- Owns: `LIB/chicago/**` (W4 hunks), `receipt/offline_replay.ex` (`@do_boundary` only),
  `lib/mix/tasks/ash_a2a.chicago.mutate.ex`, `priv/sa2a/chicago_court_manifest.json` (re-pin
  via `mix ash_a2a.chicago.pin_court_manifest`), `T/chicago/real_collaborators_test.exs`;
  NEW `T/chicago/l07_kernel_boundary_test.exs`, `T/chicago/l07_no_raw_effect_fixtures_test.exs`,
  `priv/architecture/chicago_fixture_effect_allowlist.exs`.
- Split: allowlist could be generated from an RDF sink list (NEW PACK TEMPLATE REQUIRED:
  `elixir-effect-allowlist`); role repoints and forging helper handwritten. The seven raw
  `Ash.create` fixtures stay in `lib/` behind a digest-pinned allowlist (operator open
  question 10 not answered; moving them to `test/support` would break `mix ash_a2a.chicago`
  outside `MIX_ENV=test`, mix.exs:209-210).
- Fleet reuse: `gate-vacuity-court-pack` and `semantic-gate-witness-court-pack` as design
  models (python templates, not code). `Authority.new` migration is L20, not L07.
- Courts: L07-C1..C6. BLOCKED(L10): the effect-instance-keyed double-actuation clause.
- Deps: L05, L06; P0 tree committed. Build: `_build-lane07`. Repo: ash_a2a.

### L08 test conversion (W4)

- Owns: the 29 files that call `Dispatcher.dispatch` (20 tests, 9 support incl.
  `test/support/{fixture,receipted_dispatch,multi_turn_fixture,jsonrpc_handler_fixture,
  tenant_actor_auth_fixture,auth_plug_fixture,failing_task_fixture,sse_stream_fixture,
  crashing_dispatch_fixture}.ex`), `T/chicago/brce_gate7_test.exs`, `T/rfc004_fence_test.exs`,
  dispatch-use hunks of `rfc004_agent_scope_test.exs`, plus
  `ash_a2a_command_bus_duplicate_action_names_test.exs` (C-10); NEW
  `T/sec_m01_lib_effect_sweep_test.exs`.
- Split: fully handwritten; sweep skeleton could come from `chicago-fault-injection-pack`
  (NEW PACK TEMPLATE REQUIRED, optional). Single swap point: `receipted_dispatch.ex`.
- Courts: SEC-M01 lib sweep, forged resolved_skill, anchorless DO, conversion completeness.
  Dispatcher-unit tests may keep a direct call only if allowlisted with a reason.
- Deps: L05, L06. Build: `_build-lane08`. Repo: ash_a2a.

### L09 consequence classification (W4)

- Owns: `LIB/skill.ex`, `dsl.ex`, `capability_index/compiler.ex`, `capability_index.ex`,
  `transformers/build_capability_index.ex`, `effector/ash_action.ex` (guard hunk),
  `lib/mix/tasks/ash_a2a.{install,verify_architecture}.ex`; NEW `LIB/effector_contract.ex`,
  `effector_contract/{derive,probe,test}.ex`, `test/support/sec_m03_fixtures.ex`,
  `T/sec_m03_*` (6); observe-generic opt-in hunks in `rfc004_agent_scope_test.exs` and
  `test/ash_a2a_agent_command_bus_test.exs`.
- Split: derive matrix and refusal rows generated later (NEW PACK TEMPLATE REQUIRED:
  `sa2a-consequence-contract`); derive/probe handwritten. Additive `:pure` class only.
- Courts: SEC-M03-1..5,8. BLOCKED: SEC-M03-6 (L18), SEC-M03-7 (L12).
- Deps: L01, L03, L05, L08. Build: `_build-lane09`. Repo: ash_a2a.

### L10 claims, fencing, unknown outcome (W5)

- Owns: `LIB/command_bus.ex` (W5), `agent.ex` (W5), `receipt_store.ex`,
  `receipt_store/{memory,ekv,actuation_claim_lease,claim_lease}.ex`, `receipt.ex`,
  `reconciliation.ex`, `receipt_outbox.ex` (supersedes? and recover_claim), `consequence_kernel.ex`
  (claim slots and L11 fence call), `test/support/receipt_crash_window_fixture.ex`; NEW
  `receipt_store/generation.ex`, `LIB/{effect_claim,request_claim,replay_evidence,
  effect_outcome}.ex`, `T/sec_m10_*`, `T/rfc004_m12_*` (8), `T/rfc004_unknown_outcome_*` (5);
  edits to `command_bus_hardening` and `actuation_identity` tests.
- Split: claim structs generated later (NEW PACK TEMPLATE REQUIRED: `ash-a2a-claim-structs`);
  begin_effect CAS, fencing, dedup removal handwritten. Migrates `identity/2` callers (C-03).
- Fleet reuse: existing claim_lease modules; generation design is fresh (erlmcp has none, F35).
- Courts: SEC-M10, RFC004-M12, RFC004-UNKNOWN, SEC-M13-supersedes, ordering anti-vacuity.
- Deps: L01, L03, L04, L05, L06; L11 spec. Build: `_build-lane10`. Repo: ash_a2a.

### L11 authority fence (W5)

- Owns: `LIB/authority.ex`, `authority/{grant,broker,decision,security_preflight}.ex`,
  `authority/broker/{in_memory,ekv}.ex`, `test/support/authority_grant_case.ex`, authority and
  broker tests; NEW `LIB/authority_fence.ex`, `authority/test_support.ex` (`mint/3`),
  `T/sec_m04_*` (7), `T/sec_m05_*` (3), `T/sec_m06_*` (4). `Authority.new` stays public with a
  deprecation until L20 migrates ~29 chicago call sites. No second Decision type.
- Split: `authority_*` refusal rows come from L03; broker callbacks, fence, mint handwritten
  (NEW PACK TEMPLATE REQUIRED: `sa2a-authority-refusal`).
- Fleet reuse: `portable-consequence-protocol-pack` vectors; autofde-lab `AuthorityBroker`
  tests as falsifier vectors only (forged and unregistered grant, zero mutation).
- Courts: SEC-M04, SEC-M05, SEC-M06 Stage A. BLOCKED(L05/L10): kernel-path arms.
- Deps: L01, L03. Build: `_build-lane11`. Repo: ash_a2a.

### L12 SecurityProfile and boot (W6)

- Owns: `LIB/security_profile.ex`, `security_profile/receipt_keyring.ex` NEW,
  `priv/security_profile/{release.json,release.sha256}` NEW, `lib/mix/tasks/ash_a2a.security_
  profile.pin.ex` NEW, `application.ex`, `mix.exs`, `mix.lock` (hunks), `config/{config,test}.exs`,
  `.tool-versions` (unchanged unless the operator decides), `LIB/capability_release.ex`,
  `info.ex`, `health.ex`, `kill_switch.ex`, `command_bus.ex`, `agent.ex`, `dispatcher.ex` (W6
  hunks), `test/test_helper.exs`, `test/support/{security_profile,release_profile}_fixture.ex`,
  `T/sec_m16_*`, `T/sec_m24_*`, `T/kill_switch_durability`, `health/health_test`,
  `capability_release_test`, `rfc004_authority_effect_kill`, `command_bus_kill_switch_test`
  NEW (C-13).
- mix.exs hunks: alias `verify.effector_graph` (L05), path dep `sa2a_wire` (X1), no other deps.
- Split: forbidden-opts list, struct fields, boot-refusal table, `release.json` and vectors are
  generated later by G (NEW PACK TEMPLATE REQUIRED: `security-profile`); load logic handwritten.
  `ResourceEnvelope` is a plain-map placeholder until L17.
- Fleet reuse: `SecurityPreflight` (single strictness source), existing Closure and DETS
  kill switch.
- Courts: SEC-M16-1..7, SEC-M24 (7). BLOCKED(L04/L18): SEC-M16-8. Profile tests are `async: false`.
- Deps: L03, L10, L11. Build: `_build-lane12`. Repo: ash_a2a.

### L13 exec and dispatch closure (W7)

- Owns NEW: `LIB/safe_exec.ex` (13-entry closed table, C-11), `callback_registry.ex`,
  `T/sec_m19_*` (8). Owns edits: `LIB/a2a_transport/extended_card.ex`,
  `durability/durable_server.ex`, `topology/{presence,group}.ex`, `sa2a/graphlaw.ex`,
  `runtime_identity.ex`, `runtime_identity/execution.ex`, `planning/hddl_solver.ex`,
  `graph_law/{subprocess,runtime_b,wasmtime_runtime}.ex`, `graphlaw/{vendor,manifest}.ex`,
  `semantic/root_manifest/engine_probe.ex`, `telemetry/metrics.ex`,
  `semantic/machine_experience.ex`, `delivery/oban.ex`, `execution/flame.ex`, `verify.ex`.
- Spec-only hunks handed to owners: `receipt_outbox.ex` and `standing_ref.ex`, `research/erc.ex`
  (L15), `planning.ex` (L02/A3). `receipt/offline_replay.ex` `Port.open` is an allowlisted
  orphan (L20), never edited here.
- Split: capability and kind tables generated later (NEW PACK TEMPLATE REQUIRED:
  `sa2a-closed-surface`); validators and call-site edits handwritten. `SafeExec.run` reuses
  `GraphLaw.Subprocess.run/3` (keep its signature stable).
- Courts: SEC-M19-1..9. Real subprocesses, no mocks. Env providers are removed, so local
  `GRAPHLAW_*` env use needs a config-pin migration note.
- Deps: L03, L06, L12. Build: `_build-lane13`. Repo: ash_a2a.

### L14 egress and endpoints (W7)

- Owns: `LIB/a2a_transport/{webhook_policy,push_config_rpc,push_config_store,push_delivery,
  plug,transport,task_events}.ex`, `telemetry/ocel_forwarder.ex`, `llm_profiles.ex`,
  `planning/semantic_synthesis.ex`, `semantic/compiler.ex`, `effector/{push_webhook,
  ocel_export}.ex` (hunks); NEW `LIB/endpoint_capability.ex`, `endpoint_capability_store.ex`,
  `endpoint_policy.ex`, `network/{egress,llm_endpoint}.ex`, `T/sec/m20_*` (10),
  `test/support/sec_m20_egress_fixtures.ex`.
- Phase 0 (no kernel dependency): close the OBSERVED hole at `ocel_forwarder.ex:239` (raw
  `Req.post`, no `WebhookPolicy`); pin IP, `redirect: false`, header allowlist, allowlisted
  `req_llm_opts`. Phase 1 needs L05 and L12.
- Split: refusal codes from L03; egress and capability handwritten (NEW PACK TEMPLATE
  REQUIRED: `sa2a-endpoint-egress`).
- Courts: SEC-M20 A-H. BLOCKED(L04/L05): seal court; BLOCKED(L20): raw-HTTP static court.
- Deps: L03, L05, L12. Build: `_build-lane14`. Repo: ash_a2a.

### L15 file roots (W7)

- Owns: NEW `LIB/file_object.ex`, `T/sec/m21_*` (8); edits `LIB/receipt_outbox.ex`,
  `standing_ref.ex`, `research/erc.ex`, `kill_switch.ex`, `spg_conformance.ex`,
  `lib/mix/tasks/ash_a2a.{sa2a_conformance,standing_ref}.ex`,
  `priv/spg_conformance/v26.9.27/CORPUS_DIGEST.sha256` (regenerate only if it changes).
- Phase 1 is independent of the kernel; phase 2 (kernel seal) BLOCKED(L05/L12). Git hunks in
  `standing_ref`, `erc`, and the mix task are BLOCKED(L13). M11 idempotency key
  BLOCKED(L01 EffectInstance) except the interim form.
- Split: root registry, refusal rows, vectors generated later (NEW PACK TEMPLATE REQUIRED:
  `sa2a-file-roots`); resolve/verify_at_use handwritten. No fleet code to reuse (OBSERVED grep).
- Courts: SEC-M21-1..8, mutation court. `beam_file.ex` intent is reconciled by allowlist.
- Deps: L03, L10, L12, L13. Build: `_build-lane15`. Repo: ash_a2a.

### L16 continuation scope (W7)

- Owns: NEW `LIB/semantic/continuation_scope.ex`, `T/rfc004_m17_continuation_namespace_test.exs`,
  `T/semantic/package_store_scope_bounds_test.exs`, `T/rfc004_m17_architecture_gate_test.exs`
  (soft on L20); edits `LIB/semantic/{package_store,execution_package}.ex`, `agent.ex` (W7
  continuation hunks, last in the relay), `rfc004_agent_scope_test`, `ash_a2a_agent_semantic_
  replan_test`, `T/semantic/package_store_bounds_test.exs`. `application.ex:117` child spec
  stays compatible (L12-owned).
- Split: fully handwritten; refusal `continuation_not_found` is an L03 row.
- Courts: SEC-M17-1..6 (SEC-M17-6 BLOCKED(L20)). External code collapses to one
  `:continuation_not_found`, so the old `continuation_*_not_found` assertions change.
- Deps: L01, L08, L09, L10, L12. Build: `_build-lane16`. Repo: ash_a2a.

### L17 budget and lineage (W7)

- Owns NEW: `LIB/resource_envelope.ex`, `budget_ledger.ex`, `budget_ledger/{memory,ekv}.ex`,
  `effect_lineage.ex`, `test/support/sec_m22_effector_fixtures.ex`, `T/sec_m22_*` (7). Edits:
  `LIB/execution_context.ex`, `gall/closure/pipeline.ex`, `command_bus.ex` (`bound_gate/3` only,
  additive, inside `pre_do_gate`), `consequence_kernel.ex` (reserve step), `planning/preflight.ex`.
- Built ON `Semantic.Allocator.Budget` and `Semantic.Bounds`; adds `apportion/2` (largest
  remainder, integer only, tie to the lexicographically larger key, explicit remainder sink)
  ported from gymact `_apportion_integer` (F18), and the ledger owns the hard
  `sum(children) <= parent` check because CMCA conservation is not enforced (F14).
- Vectors: `priv/budget/apportion_vectors.json` NEW, generated read-only by python3 from
  gymact `cda32cd` (no gymact edit, F19); the differential court runs Elixir against it.
- Split: envelope defaults and refusal rows generated later (NEW PACK TEMPLATE REQUIRED:
  `kernel-resource-envelope`); CAS, lease, settle handwritten.
- Courts: SEC-M22-1..7 plus adapter rule; BLOCKED(L05): M22-5,6; L20: corpus entry.
- Deps: L10, L12. Build: `_build-lane17`. Repo: ash_a2a.

### L18 receipt seal and wire (W8)

- Owns: `LIB/receipt/{binding,replay,offline_replay,evidence_chain}.ex`, `receipt.ex`,
  `postcondition.ex`, `execution_snapshot.ex`, `receipt_store/{memory,ekv}.ex`,
  `receipt_outbox.ex`, `command_bus.ex` (W8), `reconciliation.ex`, `gall/command_receipt.ex`,
  `semantic_projection.ex`, `consequence_kernel.ex` (seal step); NEW `LIB/receipt_seal.ex`,
  `consequence_kernel/receipts.ex`, `LIB/wire/{codec,record,receipt,execution_snapshot,jcs}.ex`,
  `lib/mix/tasks/ash_a2a.outbox.migrate.ex`, tests `rfc004_evidence_forgery_*` (6),
  `receipt_store/rfc004_commit_authentication`, `receipt/binding_jcs_identity`,
  `wire/receipt_roundtrip_property`, `sec_m18_*`.
- Merge on top of the committed dirty hunks in `evidence_chain.ex` and `offline_replay.ex`.
  `Wire.Jcs` reuses `Jcs.encode` (capability_release.ex:356; which module `Jcs` aliases is
  UNVERIFIED). Prerequisite gate: the Receipt round-trip property court passes before cutover.
- Split: wire field tables and vectors generated later (NEW PACK TEMPLATE REQUIRED:
  `wire-codec-ex`); seal, binding v2 dual-read, migrate task handwritten.
- Courts: C-L18-1..7. Deps: L10, L12, L15, L17, L05, L07, L02; interface L19.
  Build: `_build-lane18`. Repo: ash_a2a.

### L19 standing derivation (W8)

- Owns NEW: `LIB/standing/{derive,axes}.ex`, `semantic/peer/outcome.ex`, `T/sec_m15_*` (7).
  Edits: `LIB/semantic/{standing,peer,admission,ir_admission_seal,plan_projection,agent_card,
  falsifier_suite}.ex`, `planning/goal_facts.ex`, `conditional_commitment.ex`,
  `runtime_receipt.ex`, `planning/preflight.ex` (fence rename, after L17).
- Field removal from `receipt.ex` is L18's; L19 supplies `Standing.Derive` and the
  `Receipt.standing/1` interface pinned before W8 starts. Durability axis calls
  `Chicago.Collaborators.DurabilityProbe.run/2` without editing it.
- Split: axis list and truth table generated later (NEW PACK TEMPLATE REQUIRED:
  `sa2a-standing-axes`); logic handwritten.
- Courts: SEC-M15-1..4,6,7 (7 BLOCKED(L05/L18) arm listed, not green); SEC-M15-5 is L20's.
- Deps: L10, L12, L15, L17. Build: `_build-lane19`. Repo: ash_a2a.

### L20 cross-cutting courts and migration (W9)

- L20a (verifier, no chicago dependency): NEW `LIB/architecture_verifier/{effector_graph,
  network_egress}.ex`, `priv/sa2a/effector_allowlist.json`, `T/sec_l20_effector_graph*`,
  `T/architecture_verifier/network_egress_test.exs`; edits `architecture_verifier{,/adapters}.ex`,
  `chicago_rollup.ex`, `semantic/conformance.ex` (public accessor for `:dynamic_apply`
  detector), `ash_a2a.verify_architecture.ex`, `ash_a2a.effector_graph.ex` (xref layer).
- L20b (chicago and rows): `LIB/chicago/**` incl. the ~29 `Authority.new` sites to
  `TestSupport.mint/3`, `Fx.read_back!` to the L18 codec, mutation entries M05, M10, M11, M13,
  M22, M24 in `chicago/mutation{,/catalog}.ex`, `priv/sa2a/chicago_mandatory_corpus.json`,
  `priv/sa2a/sec_row_table.json` NEW, `T/sec_l20_{cross_cutting_rows,row_table}_test.exs`,
  `T/sec_m01_{ingress_denial_matrix,site_allowlist}_test.exs`, SEC-X4-12 court, aggregation of
  `handwritten/*.md` into `HANDWRITTEN.md`.
- Split: row table and corpus members generated (NEW PACK TEMPLATE REQUIRED:
  `sa2a-sec-row-court`); verifier resolution and allowlist justifications handwritten.
  `xref` cannot see dynamic dispatch: verdict for that class is `NOT_COVERED`, row PARTIAL.
- Courts: SEC-M01-4,7, L20-GRAPH-1,2, per-mechanism rows, L20-ROWS. Every row is ALIVE,
  PARTIAL, or BLOCKED(lane), derived from run output, never stored.
- Deps: L01-L19, X1-X4, A1-A4. Build: `_build-lane20`. Repo: ash_a2a.

### G generator lane (W2)

- Owns: `priv/ggen/sa2a_kernel/**` NEW, `lib/ash_a2a/kernel/generated/**` NEW,
  `.ggen_igniter/**` (single writer), `mix.lock` (ggen_igniter 26.9.8 to 26.9.28, dev only, F30),
  takeover of `consequence_kernel/refusal_codes.ex` and `priv/identity/canonical_vectors.json`
  by relay with a byte-equality court, `docs/jira/v26.9.28-kernel/handwritten/G.md`.
- Splits: see Generator protocol. Handwritten residue stays out of `kernel/generated/`
  (durable prepare, classification, ledger arithmetic, Canonical encoder), each with an
  `UNSUPPORTED(generator-capability)` ontology row and a ledger line.
- Fleet reuse: `state-transition-pack` `fsm.ex.tmpl` only if forked with a namespace and path
  override (hard-coded `StFsm`, `src/st_fsm/fsm.ex`); `cs2-semantic-work` consumer templates are
  not constructor-only and are not reused for kernel structs; `gate-vacuity-court-pack` for the
  anti-vacuity shape.
- Courts: generated files carry the marker; `plan` all unchanged; `replay --verify-only` cites the
  ggen_igniter SHA; mutating a template changes output.
- Deps: L01, L03. Build: `_build-laneG`. Repo: ash_a2a (upstream to marketplace is W10).

### X1 actuation certificate (X1a W2, X1b W6)

- X1a owns `sa2a_wire/**` NEW (mix project, no deps, no key material): strict RFC 8785 subset
  encode/decode (reject duplicate keys, floats, non-UTF8, unknown fields), `ActuationCertificate`
  struct and codec, `Suite` table (`ed25519`; `mldsa65` only if `:crypto.supports` lists it at
  boot), pure `Verifier.verify/5` with a quorum seam for X3, shared vectors. Court: byte-equality
  with `priv/identity/canonical_vectors.json` (drift court against L01).
- X1b owns `LIB/authority_client.ex` NEW (no key, mTLS or UDS to X2, no port or NIF),
  `test/support/authority_client_fake.ex` NEW (real Ed25519 key; reason: X2 is a separate OS
  process), `T/x1_*` (6), and the certificate step in `consequence_kernel.ex` (relay) which
  requests a certificate, then re-verifies locally as defense in depth.
- Split: field list, refusal rows, vectors generated later (NEW PACK TEMPLATE REQUIRED:
  `actuation-authority`); verifier, suite dispatch, client transport handwritten.
- Courts: X1-C1..C6 (per-field mutation, no ambient key, replay/expiry/alg, canonical vectors,
  unavailable, anti-vacuity). Fleet reuse: `chicago/courts/plan_authority.ex:399` Ed25519
  pattern; autofde-lab `ConsequenceBoundary` as vector shape only.
- Deps: L01, L03, L04 (X1a needs only L01 vectors and L03 codes); X1b needs L05, L11, L12.
- Build: `_build-laneX1`. Repo: ash_a2a.

### X2 authority service (W6)

- Owns `authority_service/**` NEW: separate mix project and OTP release
  `authority_service` (own `mix.exs`, `config/runtime.exs`, `rel/`), issuer, key store,
  policy, certificate builder (via `sa2a_wire`), mTLS `:ssl` listener, hash-chained audit log.
  Issue-only: no execute, no dispatch, no NIF, no port, no `System.cmd`.
- Split: refusal table and vectors generated (`actuation-authority` template); key store, issuer,
  policy, listener, audit handwritten. Keys are read from a mounted file at boot only.
- Fleet reuse: `portable-consequence-protocol-pack` vector and gate pattern;
  `runtime-evidence-authenticity-control-pack` court pattern; osx-clnr custody-file pattern
  (0600 file, 0700 dir, outside any workspace).
- Courts: X2-C1..C6 (red-first stub issuer, key isolation, vectors and alg id, process
  isolation with a real second OS process in tests only, issue-only surface, no mocks).
- Deps: X1a, L11, L03. Build: `_build-laneX2`. Repo: ash_a2a (directory at repo root).

### X3 signer registry (W3)

- Owns `signer_registry/**` NEW (separate mix project, root directory, not `apps/`; path deps
  `sa2a_wire`): registry (public keys only, integrity-checked), suite, verifier (k-of-n over
  distinct authority domains, dedupe, expiry, revocation bound to policy epoch),
  independence court, vectors.
- Split: refusal atoms, vectors, registry schema generated later (`actuation-authority`);
  quorum logic handwritten.
- Fleet reuse: OTP `:crypto` only. Shape references only: `pqc_consensus_round` quorum
  certificate (erlmcp, `.broken3`, disabled; F36), ggen `pki.rs` revocation list (lacks epoch).
- Courts: X3-C1..C8 (k-1, mutated digest, duplicate and same-domain, revoked/expired/stale,
  downgrade, registry tamper, no private key, anti-vacuity).
- Deps: X1a, L03. Build: `_build-laneX3`. Repo: ash_a2a.

### X4 actuator (W6, integration court W9)

- Owns `actuator/**` NEW: separate mix project and release `sa2a_actuator`; deps only
  `sa2a_wire` and `signer_registry`; forbidden deps `:ash`, `:ash_a2a`, `:wasmex`, `:req`,
  `:oban`. Modules: fence (16 RFC-006 s16 checks, fixed order), claim store (`:ekv`, single
  writer per effect, states claimed, completed, unknown_outcome, monotonic generation),
  revocation, static-map effectors, evidence sealing (actuator-held key), listener with size
  caps, `Dockerfile`, `k8s/actuator-*.yaml` (new files; no edits under `k8s/` existing files).
- Split: refusal table, certificate and PreparedEffect field lists, suite table, `fence_16.json`
  vectors generated later (NEW PACK TEMPLATE REQUIRED: `sa2a-actuation-surface`); fence flow,
  claim atomicity, listener, evidence handwritten.
- Fleet reuse: `graphlaw_host` out-of-process pattern only (copy the idea, no code, no Wasmex);
  `k8s` default-deny NetworkPolicy pattern; `gate-vacuity-court-pack` mutation-per-check.
- Courts: SEC-X4-1..11 in-project; SEC-X4-12 (cross-domain forgery, L20b, needs X2) and
  SEC-X4-13 (key-separation preflight, relay to L11's `security_preflight.ex` in W9 via L20b)
  are BLOCKED until then.
- Deps: X1a, X3, L04 (field list); soft L12, L20. Build: `_build-laneX4`. Repo: ash_a2a.

### A1 VKG evidence intake (W8)

- Owns NEW: `LIB/evidence/{vkg_intake,vkg_record}.ex`, `T/evidence/vkg_intake_*` (5). Schema-only
  adapter over serialized `VKG.Serializer` JSON; no compile dependency on `ash_r2rml` (F01).
  It refuses: `authority != NONE`, standing `test_double_only` (only `observed_not_actuated` is
  admissible), a non-64-hex digest, an unbound `catalog_sha256`, a missing signature when a key is
  provisioned. It never trusts the `NONE` field (F03) and treats VKG digests as opaque (F02).
- Evidence record: `evidence_id = receipt.id`, subject digest from the SA2A canonical form, VKG
  `plan/catalog/result` digests as source bindings, `previous` as chain link. SemanticSubject is
  composed as `digest(ontology/profile/shacl digest + receipt.sha256 + row_sha256 set)`, not reused.
- Consumer pin: `ash_r2rml` `d4971a4`, never the working checkout (F04). Deep verification via
  `AshR2RML.VKG.verify/2` is an external step recorded UNVERIFIED in the record's standing.
- Split: struct and refusal rows from cs2-semantic-work consumer templates are candidates
  (`consumer_adapter.ex.tmpl`, authority NONE); NEW PACK TEMPLATE REQUIRED for constructor-only
  form. Handwritten: intake checks.
- Courts: mutate authority, standing, digest, catalog, signature; each must refuse; refusal on a
  mutated subject proves the gate is not vacuous.
- Deps: L01, L02, L03. Build: `_build-laneA1`. Repo: ash_a2a.

### A2 GraphLaw WASI client (W8)

- Owns NEW: `LIB/graph_law/{wasi_client,wasi_runtime}.ex`, `graphlaw/wasi_vendor.ex`,
  `priv/graphlaw/MANIFEST_WASI.json`, `T/graph_law/wasi_*` (5). Speaks the JSON ABI
  (`gl_alloc`, `gl_free`, `gl_call`, `ABI_VERSION=1`); legacy v26.7.5 bindgen path is untouched
  (F08). Outside the DO kernel: GraphLaw output is O with authority NONE; its `Lease/Ceiling`
  is engine-scoped and never an SA2A lease.
- Pin the v26.9.28 release asset by locally hashed `graphlaw.wasm` checksum (F06), not main
  `09fbd69` (26.9.29 unreleased). Host pins WASI `clock_time_get` and `random_get` for cross-host
  digest equality (F07). Spawn through SafeExec `:wasmtime`; a thin JSON-lines host does not
  ship in graphlaw and is NEW work, checked against marketplace and ggen_igniter first (UNVERIFIED
  none exists). Refusal map `{kind,engine,dialect,message}` to SA2A codes (F09).
- Split: refusal map generated (`refusal-code-registry` template); client and pinning handwritten.
- Courts: determinism with pinned clock and RNG, artifact swap refused, refusal-map totality,
  differential RDFC-1.0 against the in-BEAM canonical form (C20-style).
- Deps: L03, L13. Build: `_build-laneA2`. Repo: ash_a2a; graphlaw repo read-only.

### A3 planning subprocess (W8)

- Owns: NEW `LIB/planning/ferroplan_subprocess.ex`, `T/planning/ferroplan_subprocess_*` (4);
  edits `native/hddl_cli/{Cargo.toml,Cargo.lock,src/main.rs}`, `LIB/planning.ex` (plan identity
  into the Candidate). `hddl_solver.ex` stays L13's; the spawn goes through SafeExec `:hddl_cli`.
- Adds: caller-side kill deadline (`max_wall_ms` plus grace, SIGKILL; F25), memory `ulimit`,
  stdout cap (1-4 MiB), input size cap, content-addressed per-request temp files (no path TOCTOU),
  limits via argv/JSON (today hardcoded `PlannerLimits::default()`), and planner identity
  (`hddl_cli` binary sha256 plus pinned ferroplan rev). Pin stays `e90928d7` (0.28.0) unless
  bumped on purpose; local `~/ferroplan` is 0.29.0 (F26).
- Outcomes: `{"error"}`, timeout, or `solved=false` map to unsupported/blocked, never refused,
  and never advance state. Plan is a Candidate only, digest-bound into a PreparedEffect.
- Courts: hung, oversize, and timeout runs yield a typed refusal within budget plus grace and no
  state change; forbidden import of planner modules from the kernel and Actuator.
- Deps: L02, L03, L13. Build: `_build-laneA3`. Repo: ash_a2a; ferroplan read-only.

### A4 allocation advisor (W8)

- Owns NEW: `LIB/budget/{allocation_advisor,cmca_client}.ex`, `T/budget/allocation_advisor_*`
  (4). Advisory only: length-framed JSON, hard timeout, fail closed. CMCA request and result
  blake3 plus `bcinr_source_sha` are recorded into the PreparedEffect digest inputs; the
  output is untrusted O and L17's ledger re-verifies sums and bounds in integers.
- Shape: CMCA `allocate` is fixed N=8, K=4, Q=4 (F15); more than 8 children are chunked or
  refused. Wire schema: `wasm4pm-cmca` `allocate_json`. Worker: a native stdin/stdout wrapper in
  the wasm4pm repo (cross-repo X-07) or `bcinr` `cmca_allocate_cli` (I/O format UNVERIFIED).
  Do not pin until bcinr PR #42 merges (F16) and wasm4pm-cmca re-pins (F17): BLOCKED(X-07).
- Courts: tampered response refused, timeout typed refusal without effect, CMCA sum bits above
  65536 refused, children above parent after floor refused.
- Deps: L17, L13 (`:cmca_worker`). Build: `_build-laneA4`. Repo: ash_a2a.

## Where X1-X4 live (physical key separation)

| Project | Path | Holds | Release |
|---------|------|-------|---------|
| Wire and verify | `sa2a_wire/` | no keys, public verify only | library |
| Signer registry | `signer_registry/` | public keys only | library |
| AuthorityService | `authority_service/` | authority signing keys | `authority_service` |
| Actuator | `actuator/` | actuator evidence key, claim store | `sa2a_actuator` |
| Kernel | `lib/ash_a2a/**` | receipt seal keys (KeyCustody) | `ash_a2a` |

- All four X directories are separate mix projects at the root of the one canonical checkout
  (not an umbrella, no `apps/`), each with its own `_build`, deps, and release.
- Three disjoint key domains: kernel receipt-seal keys, authority signing keys (X2 only),
  actuator evidence key (X4 only). Disjoint files, env, OS users, and k8s namespaces. Courts:
  X2-C2 (no key reachable from the control plane), SEC-X4-13, SEC-M09 key separation.
- The kernel depends on `sa2a_wire` by path for verify only. X4 must not depend on `:ash_a2a`.
- No NIF and no port inside the kernel. Tests may spawn real OS processes; the kernel may not.

## Corrections applied from repository verification

Verdicts are from the verification pass. FALSE and PARTIAL claims changed the plan as shown.

- F01 FALSE: ash_r2rml references SA2A. A1 lives on the SA2A side; no compile dependency.
- F02 PARTIAL: exact-source identity (mapping, query, ontology bytes, not DB state; two digest
  schemes). A1 treats VKG digests as opaque; evidence is "observed at T".
- F03 PARTIAL: `authority=NONE` is enforced but self-declared. A1 enforces it independently.
- F04 correction: checkout is `epoch/v26.9.15-semantic-subject` at `e03adfe`, 21 ahead. Pin
  `d4971a4`.
- F05 PARTIAL: GraphLaw model is an in-process JSON ABI, not a job-file CLI. A2 client and host.
- F06 PARTIAL: wasm identity is not pinned by `ASSETS.sha256`. A2 hashes the release asset.
- F07 PARTIAL: GraphLaw determinism (WASI clock and RNG). A2 pins both in the host.
- F08 FALSE: vendored GraphLaw equals PR #10 module. It is v26.7.5 bindgen; A2 adds a second
  manifest record and leaves the legacy path.
- F09 PARTIAL: refusal typing lossy. A2 ships a mapping table (generated candidate).
- F10 PARTIAL: beam4pm PR #102 subject preservation is by copy; `ExactSubject.same?/2` is
  never called. C5 enforces it. F11: local beam4pm is stale (`e3d4f462`, 26.9.24).
- F12 TRUE: beam4pm has a DO edge (`Actuation.run/2`, `BoundedDo`). C5 retires it. F13: OCEL
  router is unauthenticated, C6.
- F14 FALSE: CMCA conserves `sum = 1`. L17's ledger owns the hard `<=` check.
- F15 TRUE: `allocate` is fixed 8/4/4. A4 chunks or refuses.
- F16 PARTIAL: bcinr PR #42 is open and unmerged. A4 does not pin it. F17: wasm4pm-cmca pins
  26.7.28 and `b76dcb37`; re-pin needed (X-07).
- F18 FALSE: gymact "checked flat budget split" (it is a weighted 50/50 mix over the Pareto
  frontier). Only `_apportion_integer` is ported. F19 FALSE: gymact has shared vectors (4
  inline unittest cases); vectors are generated.
- F20 FALSE: gymact `brce.py` is a cryptographic seal (it is an `object()` sentinel). Not a
  precedent. F21 PARTIAL: `rust/crown` admission is presence-only checks.
- F22 PARTIAL: xaas PR #96 depends on ash_a2a 26.9.28 (release-tag files and VERSION only;
  `mix.exs` still `~> 26.9.12`). F23 PARTIAL: xaas consumes ash_a2a APIs (zero compiled
  `AshA2A.*` calls). W10 is greenfield adapter work.
- F24 PARTIAL: `direct_external = deny` (an empty allow-list declaration, not a refusal at the
  DO point). C2 covers `DeliverWebhook`, `Mailer`, and UltraCode `System.cmd`.
- F25 FALSE: Ferroplan subprocess has no timeout (in-process 10 s watchdog exists; the
  caller-side OS timeout is absent). A3 adds the kill deadline.
- F26 FALSE: hddl_cli pin matches local ferroplan (0.28.0 vs 0.29.0). Identity records the pin.
- F27 FALSE: `sa2a-bridge-pack` targets the ash_a2a kernel (it targets xaas and autofde-lab
  ports). Not used for kernel generation. F28 PARTIAL: `portable-consequence-protocol-pack`
  supplies static surface (it is a black-box wire court and vector corpus).
- F29 FALSE: `ggen_igniter/priv/ggen/kernel` exists. Lane G authors `priv/ggen/sa2a_kernel`.
- F30: `mix.lock` pins ggen_igniter 26.9.8 vs source 26.9.28; G bumps it. F31 PARTIAL: drift gate
  has no single `sync --check`; the composite command in Generator protocol is used.
- F32 PARTIAL: OTP `:crypto` does ML-DSA and EdDSA. The pinned 27.2.4 has EdDSA only; suite table
  gates `mldsa65` (Addendum B).
- F33 FALSE: ash_a2a has signing code (it has only hash and HMAC); X1 is net-new.
- F34 FALSE: affidavit has real PQC (BLAKE3 mock); not used as a signer or vector source.
- F35 FALSE: erlmcp has epoch or generation fencing. L10 and X4 design generation fencing fresh.
  F36 PARTIAL: erlmcp k-of-n prior art (weighted, `.broken3`); design reference only.
- F37 TRUE: `_LANES.md` has no X lanes. Added. F38 PARTIAL: no open ash_a2a PRs (`gh` output was
  empty, exit status unchecked); re-check at G0.
- F39 PARTIAL: FLAME adapter call sites (`execution/flame.ex`, module name guess had zero refs)
  UNVERIFIED; L06 greps before editing.
- F40 observed drift: `Actuation.external_token/2` has zero refs, `KillSwitch.trip` has zero lib
  callers, and court texts cite `Agent.dispatch_skill/4` while the code is `/5`. L06 and L12
  fix the text; L12 decides a production trip caller.

## Cross-repo edits (all land in W10, after G9 and an ash_a2a release containing the kernel)

One canonical checkout per repository, normal branches, fix forward. Owner is the operator or
a coordinator lane started for that repo; none of these edits is made by an ash_a2a lane.

- X-01 `/Users/sac/xaas`: `Xaas.Actuation` adapter keeps `run/4`, `prepare_external/4`,
  `checkpoint_external/2`, `seal_external/2` and delegates to `ConsequenceKernel`; `mix.exs`
  dep bump.
- X-02 `/Users/sac/xaas`: `DeliverWebhook`, `Mailer`, UltraCode `System.cmd` become external
  effects.
- X-03 `/Users/sac/xaas`: `Castle.Kernel.CLI` DO moves behind X4; drop the config-selectable
  kernel module.
- X-04 `/Users/sac/beam4pm`: enforce `ExactSubject.same?/2` in dispatch; digest on
  `RecoveryReceipt`.
- X-05 `/Users/sac/beam4pm`: retire or fence `Actuation.run/2` and `BoundedDo`.
- X-06 `/Users/sac/beam4pm`: authenticate `OcelIngest.Router`; SA2A evidence enters at NONE.
- X-07 `/Users/sac/wasm4pm`: `wasm4pm-cmca` native worker bin and bcinr re-pin;
  BLOCKED(bcinr PR #42 merge).
- X-08 `/Users/sac/ggen-marketplace`: upstream `sa2a-kernel-surface` pack templates (optional).

Read-only for this map: `ash_r2rml` (pin `d4971a4`), `graphlaw` (release asset), `bcinr`
(PR #42 merged by the operator), `ferroplan`, `gymact` (vectors generated read-only),
`ggen_igniter` (dev dep), `affidavit`, `erlmcp`. beam4pm edits target remote `main`
(`e7d64a01`, PR #102 merge `43994bd7`) after the operator fast-forwards the stale checkout.

## Generated versus handwritten summary

- Generated by G in W2 (byte-equal takeover): refusal-code table, canonical vectors, effector
  inventory, certificate and PreparedEffect field lists. Later waves add generated
  security-profile constants, envelope defaults, wire tables, standing axes, row table.
- Handwritten residue (permanent, each with a `handwritten/<lane>.md` row and an
  `UNSUPPORTED(generator-capability)` ontology row): Canonical encoder, durable prepare and store,
  kernel GenServer and execute order, claim CAS, budget arithmetic, seal and binding logic,
  verifier flows, X1-X4 fence, issuer, quorum, and all courts.
- Aggregated into `docs/jira/v26.9.28-kernel/HANDWRITTEN.md` by L20b; the count must shrink
  monotonically when the pack templates land.

## See Also

- `docs/jira/v26.9.28-kernel/_LANES.md` and `RESOLUTIONS.md` (history and pinned seams)
- `docs/jira/v26.9.28-kernel/HANDOFF.md`
- `docs/rfc/RFC-SA2A-004` through `RFC-SA2A-006` and the RFC-006 substrate map
- `~/.claude/rules/same-checkout-fanout.md` and `~/.claude/rules/fanout-first.md`
