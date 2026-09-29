# RESOLUTIONS

Pinned shared seams for the v26.9.28 kernel lanes (M01-M24, SEC-M21). Every lane uses these
names, shapes and orders identically. Where a plan disagrees, this file wins. Skeptic
corrections are applied; each is tagged `[skeptic]`.

Base: `/Users/sac/ash_a2a` HEAD `8af12616314c12c58dfa6cd03c83c0c8ad657eb6`, tree dirty
(RFC-004 lanes A-F). Last Updated: 2026-09-28.

## Quick reference

1. Preconditions and staging
2. PreparedEffect
3. ConsequenceKernel contract
4. Refusal codes and S42 classes
5. EffectInstance and identity minting
6. PreparedEffectStore behaviour
7. ReceiptStore additions (claims, generation, fence)
8. SecurityProfile and selection
9. Legacy-compat profile switch
10. Canonical identity API
11. Telemetry event names
12. Conflict decisions
13. Court rules
14. Open questions

## 1. Preconditions and staging

- OBSERVED: the working tree edits `dispatcher.ex`, `brce_anchor.ex`, `command_bus.ex`,
  `agent.ex`, `receipt_outbox.ex`, `authority.ex`, `authority/grant.ex`,
  `semantic/refusal.ex`, `spg_conformance.ex`, and several tests. Untracked:
  `test/ash_a2a/rfc004_*`.
- **Hard precondition**: no kernel lane writes those files until the RFC-004 lane commits.
  Edits anchor by function name, never by line number `[skeptic: M01,M02,M04,M05,M09]`.
- **Single writer per hot file** (coordinator serializes; lanes propose hunks):
  `command_bus.ex`, `dispatcher.ex`, `agent.ex`, `semantic/refusal.ex`, `receipt_outbox.ex`,
  `receipt_store/{memory,ekv}.ex`, `architecture_verifier/adapters.ex`.
- **Stage A** (mergeable before the kernel exists, no dependency on M01/M02 modules):
  - `Identity.Canonical` phase 1 (M14).
  - Forbidden-opts refusal in `Dispatcher.resolve_skill` and `BrceAnchor` name-arm removal (M02).
  - `:none`-broker branch removal, opts-broker ignore, `rebound?` unseen-token refusal,
    constraint fail-closed (M04/M05/M06 stage A).
  - `Dispatcher.dispatch/6` refusing non-observe without matching authenticated anchor (M04 p1).
  - Outbox authentic-fetch, path-identity MAC (M09 stage A).
  - Store `commit` authentication (M23 phase A).
  - WebhookPolicy on OCEL egress (M20 phase 0).
  - `SafeExec`, argv/pid validators (M19 phase A).
  - `FileObject.resolve/2` (SEC-M21 phase 1).
  - Unknown-outcome guards (M13), `bound_gate` in `pre_do_gate` (M22 interim).
  - Effector contract derive plus class/action-type guard at `dispatcher.ex` `run_skill` (M03 A).
- **Stage B** (needs kernel): M01 full, effector inversion, live fence, `PreparedEffectStore`,
  `SecurityProfile` closure, `EffectClaim` generation CAS, `Receipt` seal keyring,
  `ConsequenceKernel.external_request`, lineage.
- Stage A hunks are written so stage B replaces them without a second migration: Stage A
  functions are named as the stage B internals (`bind_principal_actor/2`, `bound_gate/3`,
  `ReceiptSeal.verify_for_commit/2`).

## 2. PreparedEffect

`lib/ash_a2a/prepared_effect.ex`, module `AshA2A.PreparedEffect`. Owner: M01 lane. Other
lanes request fields through this table only.

| field | type | source / rule |
|---|---|---|
| `principal_id` | `String.t()` | `Identity.principal/1` of the verified identity |
| `actor_digest` | `digest()` | `Identity.actor_digest/1` of the verified identity (M07) |
| `exact_subject` | `digest()` | semantic subject digest, JCS (M05) |
| `capability_id` | `String.t()` | canonical id from the capability index, never a display name |
| `canonical_input_digest` | `digest()` | `Canonical.digest(command.input)` |
| `message_input_digest` | `digest()` | `Canonical.digest(Dispatcher.fetch_input(message))` (M07) |
| `request_id` | `String.t()` | `Command.command_id` (request identity) |
| `effect_instance_id` | `String.t()` | caller-declared, validated, see section 5 |
| `effect_id` | `digest()` | kernel-derived effect digest, see section 5 |
| `authority_decision_id` | `digest()` | broker decision id |
| `authority_epoch` | `non_neg_integer()` | broker epoch at prepare |
| `policy_epoch` | `non_neg_integer()` | `SecurityProfile.policy_epoch/0` at prepare |
| `capability_release_digest` | `digest()` | `CapabilityRelease.binding_digest/1` |
| `security_profile_digest` | `digest()` | `SecurityProfile.active().digest` |
| `resource_envelope` | `map()` | JCS-safe, ints only; see `ResourceEnvelope` (M22) |
| `consequence_class` | `:pure \| :observe \| :change \| :external_do` | kernel-derived; `:unknown` is never stored |
| `request_generation` | `pos_integer()` | request claim generation |
| `execution_generation` | `pos_integer()` | effect claim generation (fence token) |
| `lineage` | `%{root_effect_id, parent_effect_id \| nil, depth, fan_out_index}` | kernel-derived (M22) |
| `prepared_at` | `DateTime.t()` | excluded from digest |
| `prepared_digest` | `digest()` | `Canonical.digest` of all fields except `prepared_at`, `prepared_digest` |

- `digest()` = `"sha256:" <> 64 lowercase hex`.
- `prepared_effect_id` = `prepared_digest` (content-addressed). Same content prepares to the
  same id, which makes prepare idempotent.
- No public constructor. `PreparedEffect.__seal__/1` (`@doc false`) accepts only a
  `%ConsequenceKernel.Ticket{}`. Struct-literal forgery is refused by the store lookup and
  digest recompute, not by the struct definition `[skeptic: M04,M08]` (Elixir cannot make a
  struct unforgeable).
- The digest is unkeyed. Authenticity is the store seal (section 6). This resolves M01
  (HMAC-in-digest) vs M04/M08 (authenticated store): **store seal wins**.
- `PreparedEffect.verify/1` recomputes the digest only. `ConsequenceKernel.verify_prepared/1`
  is the authenticity check (store row equality).
- Observe and pure effects use the same struct (`consequence_class` `:observe`/`:pure`), a
  reduced precondition set, and the `:observation` receipt kind (M03 wanted a lighter
  `ObservationEffect`; rejected to keep one effector contract).

## 3. ConsequenceKernel contract

Module `AshA2A.ConsequenceKernel` (GenServer + pure helpers). Sole caller of any
`AshA2A.Effector`. Owner: M01.

```elixir
@spec prepare(candidate :: map()) :: {:ok, prepared_effect_id :: digest()} | {:error, refusal()}
@spec prepare_observe(candidate :: map()) :: {:ok, digest()} | {:error, refusal()}
@spec prepare_child(parent_id :: digest(), candidate :: map()) :: {:ok, digest()} | {:error, refusal()}
@spec execute(prepared_effect_id :: digest()) :: {:ok, %AshA2A.Receipt{}} | {:error, refusal()}
@spec verify_prepared(%AshA2A.PreparedEffect{}) :: :ok | {:error, refusal()}
@spec checkpoint(%AshA2A.PreparedEffect{}) :: :ok | {:error, refusal()}
@spec external_request(prepared_effect_id :: digest(), target :: String.t() | digest()) ::
        {:ok, reservation :: term()} | {:error, refusal()}
@spec actor_for(%AshA2A.PreparedEffect{}) :: {:ok, map()} | {:error, refusal()}
@spec resolve_capability(capability_id :: String.t()) :: {:ok, %AshA2A.Skill{}} | {:error, refusal()}
# refusal() :: %{code: atom(), class: s42_class(), reason: atom() | nil, field: atom() | nil}
```

`prepare/1` candidate carries identifiers only: `principal` (from verified identity),
`capability_id`, `input`, `message`, `effect_instance_id`, `request_id`. Never an
`%Authority{}`, `%Skill{}`, `actor`, broker, policy, generation or bound (candidate keys
outside this set, or any key in the forbidden list of section 8, refuse
`policy_opt_forbidden`).

`prepare/1` order:

1. `SecurityProfile.forbidden_opts/1`.
2. `Canonical.normalize` of input, then `EffectInstance.fetch/1` (change/external_do only).
3. `resolve_capability/1` by exact id (0 or >1 match refuses).
4. Class derive via `EffectorContract` (M03); `:unknown` refuses `consequence_unclassified`.
5. `CapabilityRelease` binding from the profile closure.
6. `Authority.Broker.issue_decision/3` (server-side, never a caller struct).
7. `bind_principal_actor` and `bind_message_input`.
8. `ResourceEnvelope` resolution.
9. Ticket, seal, `PreparedEffectStore.put_prepared/1`, return the id.

`execute/1` order (the fixed graph; lanes may add checks only at the marked slots):

1. `PreparedEffectStore.verified_fetch/1` (seal + digest + identity).
2. Per-`effect_id` execute lock (kernel process, single flight).
3. Request claim confirm, then effect claim confirm.
4. `unknown_outcome` gate (M13); refuse if the effect is unresolved-unknown.
5. Capability re-resolve by exact id; release digest equals prepared; consequence class
   re-derived equals prepared class.
6. Live `SecurityProfile` epoch and closure digest; kill switch (mandatory class, section 8).
7. `BudgetLedger.reserve` (M22).
8. Live `AuthorityFence.fence` (broker `resolve/4`, epoch compare); observe class fenced against
   a read ceiling.
9. `ReceiptStore.begin_effect/4` CAS: **last** store transition before the effector.
10. `Effector.apply(prepared)` exactly once, inside the same process as step 9's caller (no
    message hop or `bounded_dispatch` spawn between fence and effector `[skeptic: M06]`; the
    fence runs inside the spawned child if a spawn is needed).
11. Kernel-only receipt finalize, `settle`/`release` the reservation, `mark_consumed`.

- Effector timeout yields `dispatch_timeout` and an `unknown_outcome` receipt; the actuation
  entry is marked unknown (`mark_actuation_unknown/3`) and never reclaimable.
- Post-DO commit failure routes to the outbox as `unknown_outcome`; never re-execute.
- Stage A interim: the same order runs inside `CommandBus.run/4` + `pre_do_gate/3` using the
  Command; the kernel takes the code over unchanged.

Effector behaviour:

```elixir
defmodule AshA2A.Effector do
  @callback apply(%AshA2A.PreparedEffect{}) :: {:ok, term()} | {:error, term()}
end
```

Effectors: `Effector.AshAction`, `Effector.OnCancelHook` (M19: module-only, behaviour
`AshA2A.OnCancel`), `Effector.PushWebhook`, `Effector.OcelExport`, `Network.Egress` (M20),
`Effector.FileOp` (SEC-M21), `Effector.Provider` for Oban/FLAME/Presence (see 12.19).

- Each is `@doc false`, first clause `apply(%PreparedEffect{})`, and calls
  `ConsequenceKernel.verify_prepared/1` first, refusing `prepared_effect_forged`.

Reads and streams: **all** Ash effectors are in scope, including `Ash.read`, `Ash.stream!`,
`Ash.bulk_*`, `Ash.run_action` `[skeptic: M01,M03]`.

Dispatcher after inversion: `Dispatcher.resolve/4` (pure, no Ash effect) and
`Dispatcher.fetch_input/1` (made public) stay. `dispatch/3..6` are deleted at stage B.

Stage A: `dispatch/6` stays but refuses non-observe unless the anchor is authentic and bound
(section 12.16).

Ambient anchor: stage A keeps `BrceAnchor.put/take` but `put/1` is `@doc false`, and `admit/2`
compares the authentic outbox record (principal, capability, input digest, consequence).
Stage B deletes `put/1`, `take/0`, `clear/0`, `admit/2`, `decide/3`.

## 4. Refusal codes and S42 classes

Shape: `{:error, %{code: atom(), class: atom(), reason: atom() | nil, field: atom() | nil}}`.

**Ownership**: all NEW codes below are registered through
`AshA2A.ConsequenceKernel.RefusalCodes.__sa2a_refusal_codes__/0` (auto-collected by
`Refusal.provided_mapping/0`, OBSERVED `refusal.ex:825-836`). `refusal.ex @mapping` is not
edited by lanes (it is dirty in-flight). A doctest asserts `Refusal.classify/1` returns the
class for every code (no `:blocked_unknown`). Existing codes keep their existing class
`[skeptic: M24,M18,M22]`.

Already mapped, reuse verbatim (never redefine): `authority_required`, `authority_mismatch`
(`:refused_authority`), `capability_mismatch`, `capability_release_refused`
(`:refused_capability`), `capability_release_closure_missing` (`:refused_provenance`),
`consequence_unclassified`, `consequence_class_unknown` (`:refused_consequence`),
`kill_switch_tripped`, `budget_exhausted`, `bounds_fan_out_exceeded`,
`bounds_depth_exceeded`, `bounds_parallelism_exceeded` (`:refused_bounds`),
`outbox_bad_tag`, `outbox_untagged_entry` (`:refused_receipt`), `outbox_key_unavailable`
(`:blocked_resource`), `foreign_format` (`:refused_namespace`), `bad_term`
(`:refused_structure`), `actuation_in_flight`, `actuation_conflict` (`:refused_receipt`).

Existing in CommandBus/other provider maps (uncommitted): `authority_revoked`,
`authority_expired`, `authority_constraint_mismatch`, `authority_revalidation_unavailable`,
`kill_switch_unavailable`. Re-declare them once in `RefusalCodes` with the classes below and
delete the CommandBus duplicates in the same commit.

### New codes (single table)

| code | class | owner |
|---|---|---|
| `prepared_effect_forged`, `prepared_effect_seal_invalid` | `:refused_provenance` | M01/M08 |
| `prepared_effect_not_found`, `prepared_effect_digest_mismatch`, `prepared_effect_consumed`, `prepared_effect_stale_epoch` | `:refused_receipt` | M08 |
| `kernel_only_effector`, `effector_edge_forbidden`, `effector_command_forbidden`, `kernel_bypass` | `:refused_authority` | M01/M08 |
| `capability_opt_forbidden`, `capability_ambiguous`, `capability_release_digest_mismatch`, `capability_digest_mismatch`, `release_override_refused` | `:refused_capability` | M02/M24 |
| `capability_release_closure_digest_mismatch`, `capability_release_closure_tampered` | `:refused_provenance` | M24 |
| `policy_opt_forbidden` | `:refused_authority` | M16 |
| `security_profile_missing` | `:refused_provenance` | M16 |
| `kill_class_unbound`, `legacy_dedup_refused` | `:refused_consequence` | M16 |
| `legacy_release_refused` | `:refused_capability` | M16 |
| `legacy_profile_receipt_refused` | `:refused_provenance` | 9 |
| `effector_contract_violation`, `consequence_action_type_mismatch`, `observe_mutated_subject`, `observe_on_non_derivable_action` (compile-time DslError tag only), `observation_receipt_missing` | `:refused_consequence` | M03 |
| `authority_decision_missing`, `authority_unknown_decision`, `authority_decision_mismatch`, `authority_subject_mismatch`, `authority_input_mismatch`, `authority_envelope_exceeded`, `authority_epoch_stale`, `authority_epoch_advanced`, `authority_policy_epoch_stale`, `authority_release_mismatch`, `authority_effect_instance_mismatch`, `authority_not_granted`, `authority_broker_unconfigured`, `authority_forged` | `:refused_authority` | M04/M05/M06 |
| `authority_revalidation_unavailable` | `:blocked_resource` | M06 |
| `principal_actor_mismatch`, `deputy_input_mismatch`, `ambient_authority_refused`, `authorization_bypass_refused`, `cancel_principal_mismatch` | `:refused_authority` | M07 |
| `missing_effect_instance_id`, `invalid_effect_instance_id`, `effect_instance_reuse_conflict` | `:refused_receipt` | M11 |
| `effect_in_flight`, `effect_claim_missing`, `replay_effect_divergence`, `effect_release_unproven`, `unknown_outcome_unresolved` | `:refused_receipt` | M10/M13 |
| `stale_generation`, `stale_execution` | `:refused_identity` | M12 |
| `fence_store_unsupported`, `effect_claim_store_unavailable`, `budget_ledger_unavailable`, `prepared_journal_unavailable` | `:blocked_resource` | M10/M12/M22/M09 |
| `prepared_journal_key_required`, `prepared_journal_key_unknown`, `prepared_state_unauthenticated` | `:refused_provenance` | M09 |
| `prepared_record_identity_mismatch`, `prepared_record_stale_epoch` | `:refused_receipt` | M09 |
| `canonical_unsupported_term`, `canonical_key_collision`, `canonical_float_ambiguous`, `canonical_integer_out_of_range`, `canonical_invalid_utf8`, `canonical_bound_exceeded`, `canonical_legacy_digest_scheme`, `digest_scheme_mismatch` | `:refused_identity` | M14 |
| `receipt_seal_required`, `receipt_not_kernel_issued`, `receipt_subject_mismatch`, `receipt_unsealed`, `standing_claim_mismatch`, `standing_axis_missing` | `:refused_receipt` | M23/M15 |
| `receipt_key_not_configured` | `:blocked_resource` | M23 |
| `standing_writer_unauthorized`, `ledger_token_required` | `:refused_authority` | M15 |
| `continuation_not_found`, `continuation_scope_unbound` | `:refused_identity` | M17 |
| `outbox_legacy_format`, `schema_unknown_field`, `schema_type_mismatch`, `schema_version_unsupported`, `schema_depth_exceeded`, `schema_size_exceeded` | `:refused_structure` | M18 |
| `callback_not_registered`, `callback_arity_mismatch`, `dynamic_dispatch_forbidden`, `exec_capability_unknown`, `exec_arg_invalid`, `exec_executable_unpinned`, `exec_timeout`, `sa2a_graphlaw_untrusted_artifact` | `:refused_capability` (`exec_timeout`: `:blocked_resource`) | M19 |
| `refused_endpoint_capability_missing`, `endpoint_capability_tampered`, `refused_endpoint_purpose_mismatch`, `refused_endpoint_dns_changed`, `refused_llm_endpoint_override` | `:refused_authority` | M20 |
| `refused_endpoint_port`, `refused_endpoint_scheme`, `refused_endpoint_redirect` | `:refused_bounds` | M20 |
| `path_traversal_refused`, `path_escape_refused`, `path_symlink_refused`, `path_root_undeclared`, `path_object_id_invalid` | `:refused_bounds` | SEC-M21 |
| `file_effect_undeclared_capability` | `:refused_capability` | SEC-M21 |
| `cascade_depth_exceeded`, `parallelism_exceeded`, `external_request_budget_exceeded`, `effect_deadline_exceeded`, `envelope_unbounded`, `envelope_override_refused` | `:refused_bounds` | M22 |

### Name decisions

- Runtime "class `:unknown` or undeclared effector" is `consequence_unclassified` (not a new
  code). `consequence_class_unknown` is kept for the legacy path. `consequence_class_mismatch`
  is dropped in favour of `consequence_action_type_mismatch`.
- `fan_out_exceeded` is dropped; reuse `bounds_fan_out_exceeded`. `authority_expired` etc.
  stay as named above.
- Continuation: `continuation_receipt_not_found` and `continuation_package_not_found` stay
  mapped but are unreachable from `Agent`.
- Boundary: `stale_execution` and `stale_generation` are aliases; use `stale_generation` from
  new code, keep `stale_execution` as the store-local atom until stores migrate.

## 5. EffectInstance and identity minting

- Module `AshA2A.EffectInstance` (owner M11).
- **Never minted** by `CommandBus`, `Agent`, `Dispatcher`, the kernel or any transport.
  Caller-declared only, carried in `Command.effect_instance_id` and the A2A message DataPart
  key `"effect_instance_id"`. No derivation from `command_id`, `request_id`, `message_id`,
  retry count, or a transport idempotency key.
- Format: printable ASCII `\A[\x21-\x7e]{1,256}\z`, opaque. Refuse a value equal to
  `command_id`, `request_id` or `message_id` (`invalid_effect_instance_id`).
- Scope: registry key `{principal_id, effect_instance_id}` (per principal).
- Required for `:change` and `:external_do`; `:pure`/`:observe` exempt; `:unknown` refuses
  first.
- `effect_id` (kernel-derived) = `Canonical.digest(%{"schema" => "ash-a2a.effect-identity/v1",
  "principal_id", "capability_id", "exact_subject", "canonical_input_digest",
  "effect_instance_id"})`. Field order irrelevant (JCS). `Actuation.effect_digest` is the same
  value; `actuation_id = Identity.actuation(effect_id)`.
- Same instance id + same tuple: duplicate (retry). Same id + different tuple:
  `effect_instance_reuse_conflict`. New id + same tuple: a new consequence.
- `opts[:idempotency_key]`, `metadata.idempotency_key`, `authority.constraints
  external_idempotency_token` are **evidence only** (receipt field
  `external_evidence_token`), never identity `[skeptic: M11]`. `idempotency_key` for the
  external system still prefers the transport token.
- API: `validate/1`, `fetch/1` (from Command), `register(store, principal, id, effect_id)`.
  `Actuation.identity/2` returns `{:ok, t} | {:error, code}`; `identity!/2` added; the three
  callers (`command_bus.ex`, `execution_identity.ex:81`, doctests) migrate.

## 6. PreparedEffectStore behaviour

Module `AshA2A.PreparedEffectStore` (owner M09/M08). Durable, authenticated. Callable for
writes only from `ConsequenceKernel`.

```elixir
@callback put_prepared(%PreparedEffect{}) :: {:ok, id} | {:error, refusal()}
@callback verified_fetch(id) :: {:ok, %PreparedEffect{}} | {:error, refusal()}
@callback mark_consumed(id, execution_generation :: pos_integer()) ::
            :ok | {:error, :prepared_effect_consumed | :stale_generation}
@callback release(id, execution_generation :: pos_integer()) :: :ok | {:error, term()}
@callback list_quarantined() :: [map()]
@callback path_for(id) :: Path.t()   # test fixtures only, via FileObject root
```

- Record codec: magic `SA2AJ2` || `key_id` || JCS bytes || `hmac-sha256:<key_id>:<hex>` over
  `"ash_a2a/prepared-journal/v2" || key_id || path_identity || jcs_bytes`. `path_identity` =
  `"<request_id>|<effect_id>"`.
- `verified_fetch` unseals, recomputes `prepared_digest`, and compares decoded identity to
  path identity. Existence is never evidence `[skeptic: M09]`.
- No `term_to_binary`/`binary_to_term` in the record path. The PreparedEffect is JSON-safe by
  construction.
- Key custody: `AshA2A.KeyCustody` (kernel-supervised process, state only). API `seal/2`,
  `verify/3`, `key_ids/0`. **No key read API; no `:persistent_term` and no `Application` env
  for key material** `[skeptic: M01]`. The journal key, receipt binding key and outbox key are
  one keyring with separate domain-separation strings. `:receipt_binding_key` fallback is
  removed.
- `ReceiptOutbox` remains the receipt journal (stage A hardening: same codec, authenticated
  `fetch_authentic/2`). `anchored?/1` becomes a verifying read; unverifiable entries count as
  anchored for reclaim decisions (fail closed) and as NOT anchored for admission and for
  post-failure outcome claims (`command_bus.ex` outcome classification) `[skeptic: M09]`.
- Stage A keeps `term_to_binary` under the MAC (decode only after tag and identity verify).
  The JSON `Wire.Receipt` codec (M18) is a stage B prerequisite for dropping ETF; until then
  ETF appears only as MAC'd storage, allowlisted in the architecture court.

## 7. ReceiptStore additions (claims, generation, fence)

Existing names are kept (`claim/2`, `claim_actuation/3`, `commit/2`, `commit_actuation/3`,
`release_actuation/2`, `confirm_claim/3`). **`EffectClaim` = the actuation entry; `RequestClaim`
= the command claim entry.** No new claim stores and no `claim_effect` rename `[conflict
M10 vs M11/M12]`.

Add (required, not optional, for durable stores; `boot_check/1` refuses a store lacking them):

```elixir
@callback begin_effect(request_key, effect_key, %{request_generation: g1, execution_generation: g2}, opts) ::
            :ok | {:error, :stale_generation | :effect_in_flight | :receipt_store_unavailable}
@callback fetch_actuation(effect_key, opts) :: {:ok, entry | nil} | {:error, term()}
@callback mark_actuation_unknown(actuation, %Receipt{}, opts) :: :ok | {:error, term()}
@callback recover_claim(command, receipt_execution_id, receipt_generation, opts) :: term()
```

- Claim state enum `:claimed | :executing | :done | :released`. Generation is a strictly
  monotonic positive integer per key, never caller-supplied (drop `opts[:execution_id]`
  honoring on fresh claim). Tombstones hold the high-water mark through release, eviction and
  sweep.
- `:executing` and unresolved `unknown_outcome` entries are never reclaimable and never
  released.
- **Order (RFC-004:147)**: request claim first, then effect claim. Request-claim `{:replay,_}`
  and lease reclaim may yield evidence or a typed refusal, but never `{:execute,_}` for
  `:change`/`:external_do` unless the effect entry is `:released` `[skeptic: M10]`.
  `ActuationClaimLease.decide/3` reads only the effect entry (never `primary_claim`).
- Replay evidence: `AshA2A.ReplayEvidence` (owner M10) `%{receipt_id, effect_id, outcome,
  replayed?: true}`; kind `:evidence_replay`; carries no `execution_id`.
- `unresolved_unknown?(r)` = `terminal_status == :unknown_outcome and metadata.outcome !=
  :reconciled`. `Reconciliation.mark_reconciled/3` sets `terminal_status: :reconciled` and
  `actor: :reconcile`. A reconciled receipt still yields `{:duplicate, r}`, not `:in_flight`
  `[skeptic: M13]`.
- `Store.commit/2` takes `actor:` (default `:automatic`); only `Reconciliation` and outbox
  drain pass `:reconcile`. Identical-receipt re-commit is allowed. Commit authenticates via
  `ReceiptSeal.verify_for_commit/2` and refuses `receipt_unsealed` /
  `receipt_subject_mismatch`.

## 8. SecurityProfile and selection

Module `AshA2A.SecurityProfile` (owner M16; M04/M05/M09/M19/M20/M22/M23/M24 add fields via
this table only). Thin frozen snapshot over the existing `Authority.SecurityPreflight`
(`strict?/0`, `check!/0`, allow-legacy ack); **not** a second strict flag `[skeptic: M04]`.

```elixir
%AshA2A.SecurityProfile{
  profile: :release | :legacy_compat | :test,
  profile_id: String.t(),
  digest: digest(),
  policy_epoch: non_neg_integer(),
  release_closure_digest: digest(),        # pinned artifact digest
  release_mode: :strict,                   # constant
  dedup_mode: :strict,                     # constant
  kill_classes: %{change: atom(), external_do: atom(), observe: atom() | nil},
  authority_policy: :broker,
  authority_broker: {module(), keyword()},
  require_authenticated_caller: true,
  strict_observe: true,
  require_effect_contract_for_generic: true,
  opaque_read_preparations: :refuse | :attest,
  keyring_ids: %{active: key_id, verify: [key_id]},   # ids only, never key bytes
  file_roots: %{atom() => %{path: Path.t(), classes: [atom()], mode: :rw | :ro}},
  network: %{allowed_schemes, allowed_ports, allow_cidrs, ocel_ingest_candidate,
             llm_endpoints, egress_max_body_bytes},
  envelope: %ResourceEnvelope{},
  legacy_flags: [atom()]                   # empty unless profile == :legacy_compat
}
```

API: `load!/1` (boot only), `active/0`, `digest/1`, `kill_class_for/2`,
`forbidden_opts/1`, `release_binding/1`, `envelope/0`, `file_roots/0`, `network_policy/0`,
`install_for_test!/1` and `for_test/1` (**compiled only under `MIX_ENV=test`**).

- **Selection**: from the release profile artifact (`priv/security_profile/release.json`,
  JCS, `chatman.security-profile/v1`) whose sha256 is a compile-time constant of the release
  build. Pinned in a kernel-owned process at `Application.start/2` (before children); reads
  are `active/0` only.
- Boot refuses (typed) if: artifact missing or digest mismatch, a non-pure class has no
  kill class, a durable root is under `System.tmp_dir!`, `dedup_mode`/`release_mode` not
  strict, or a legacy value is present outside `:legacy_compat`.
- **Never from opts or env at call time.** Forbidden keys (refuse `policy_opt_forbidden`
  before any claim):
  `:actuation_dedup :kill_switch_class :kill_switch :capability_release_closure
  :capability_release_mode :capability_release_binding :authority_policy :policy
  :authority_broker :require_authenticated_caller :strict_security :auth_identity
  :resolved_skill :skill :capability_id :wasm_path :req_llm_opts :generate_object
  :plan_generate_object :store :allow_cidrs :allow_http :resolver`.
  This is one list, `@forbidden_policy_opts` in `SecurityProfile`, used by `Dispatcher`,
  `CommandBus`, `Agent`, `Info` `[skeptic: M02,M16]`. `agent_card/2` raises
  `ArgumentError` with the typed reason rather than silently dropping.
- `Agent` runs `forbidden_opts/1` in `handle_message` **before** it consumes
  `@dispatch_opt_keys`.
- **Compat exception**: `opts[:auth_identity]` remains accepted at stage A only as an
  assertion checked for equality with the verified principal (M07 phase A); at stage B it is
  removed.
- Kill switch: class from `kill_classes`; the default `KillSwitch` instance only; consulted
  at claim time and in step 6 of `execute/1`. No opts instance. Unavailable yields
  `kill_switch_unavailable`.
- The test profile is the only place a resolver or `allow_cidrs` may be injected. Fixtures
  that used `actuation_dedup: :off` (chicago replay, offline_replay) forge the double-actuated
  chain directly through the ledger `[skeptic: M11]`.

## 9. Legacy-compat profile switch

`profile: :legacy_compat` loads only if config carries a signed-off ack (the existing
`SecurityPreflight` allow_legacy acknowledgement plus `expires` date). It never loads in a
release build without the ack; expired ack refuses boot. Every receipt records
`security_profile: %{profile, digest, legacy_flags}`.

Survive **only** under `:legacy_compat` (closed flag list):

| flag | old behavior kept | stamped |
|---|---|---|
| `:transport_verified_grants` | `authority_policy :transport_verified_grants_capability` standing grants | receipt + decision |
| `:observe_generic_opt_in` | generic `:action` `:observe` admitted via `observe_generic_actions` name list (still needs an `effect_contract` attestation to run; opt-in alone is not attestation) | receipt |
| `:legacy_receipt_format_read` | v1 ETF outbox/evidence-chain bytes readable through `mix ash_a2a.outbox.migrate` only, never at runtime | migration receipt |
| `:legacy_digest_migration` | v1 ETF-digest records recognised for `Canonical.Migration` recompute; otherwise refused `canonical_legacy_digest_scheme` | migration receipt |

Never survive, in any profile (delete, do not flag):

- ambient anchor `put/take` as authority;
- caller `resolved_skill`; opts-selected broker, policy, kill class, dedup mode, release
  mode or closure; `admitted_by` broker substitution;
- the `:none`-broker fail-open branch; unseen-token broker verify;
- `:declared` and `:off` dedup for `:change`/`:external_do`; `:legacy` release mode;
- `Application`-env provider modules; MFA `on_cancel`; fun/MFA extended-card providers;
- unkeyed journal or binding writes outside `:test`.

Effects of a `legacy_compat` stamp:

- `Standing.Derive` caps the evidence axis at `:receipted`; never `:verified`/`:attested`.
- Strict replay and offline replay refuse legacy-stamped receipts as
  `legacy_profile_receipt_refused`.
- Health reports `:legacy_compat` as BLOCKED, not OK.

## 10. Canonical identity API

`AshA2A.Identity.Canonical` (`lib/ash_a2a/identity/canonical.ex`, owner M14). The only
module referencing `Jcs`; the only exported digest family `[skeptic: M14]`.

```elixir
@type digest :: String.t()  # "sha256:" <> 64 lowercase hex
@spec normalize(term()) :: {:ok, json_term} | {:error, %{code: atom(), path: String.t()}}
@spec encode(term()) :: {:ok, binary()} | {:error, refusal()}     # JCS bytes (RFC 8785)
@spec digest(term()) :: {:ok, digest} | {:error, refusal()}
@spec digest!(term()) :: digest                                    # internal use, raises typed
@spec verify(term(), digest) :: :ok | {:error, refusal()}
@spec mac(key_id :: String.t(), domain :: String.t(), term()) :: String.t() # "hmac-sha256:<key_id>:<hex>"; via KeyCustody
```

Rules (closed, total):

- Maps to JSON objects; keys binary or atom, stringified; integer keys refused;
  post-stringify collision refused `canonical_key_collision`.
- `nil/true/false` native; any other atom becomes its string (atom and string are the same
  value by contract).
- Integers within ±2^53 only, else `canonical_integer_out_of_range` (carry big values as
  decimal strings).
- Integral floats refused `canonical_float_ambiguous`; non-integral finite floats pass
  through JCS shortest form.
- `DateTime`/`Date` become ISO-8601 UTC strings.
- Tuples, pids, refs, funs, ports, improper lists, and structs without an
  `Canonical.Encodable` impl are refused `canonical_unsupported_term` with a JSON-pointer
  path. Invalid UTF-8 refused. Depth and size bounded.
- Digest output is always `sha256:<64hex>`. Bare-hex, `h:` and `hmac-` forms are removed;
  the HMAC form keeps its own `hmac-sha256:` prefix as a MAC type, not a content digest.
- Schema tags `ash-a2a.<object>/v1` on every identity map; persisted objects carry
  `digest_scheme: "jcs-sha256/v1"`. Old scheme is refused
  (`canonical_legacy_digest_scheme`) unless `Canonical.Migration` recomputes it.
- Sites converted (mechanical): `Command.fingerprint`, `Actuation.digest`, `Binding`
  link/field digests (bump `@version` to 2), `Authority.grant_token_id`,
  `CapabilityRelease.digest_term`/closure/`binding_digest/1`, `Gall.Closure.Determinism`,
  `Gall.CommandReceipt`, `Authority.Decision.digest`, `Semantic.Envelope.evidence_digest`,
  `HILT.WorkOrder`, `ExecutionIdentity`, `Transport.Principal.digest`, `ExecutionSnapshot`,
  `PreparedEffect`, `EffectInstance`, `ContinuationScope`.
- Storage encodings (`ReceiptOutbox` ETF, `ExecutionSnapshot` envelope) are allowed **only**
  as MAC'd storage; every digest inside is recomputed via `Canonical` after decode.
- **Two-phase Command projection** `[skeptic: M14]`. Phase 1 (M14 alone) is a schema-tagged
  map of the CURRENT fingerprint fields (principal, task, capability, normalized input,
  authority token, semantic subject, spg token, semantic metadata identity) and keeps
  `agent_id`. Phase 2 (after M03/M11 add fields) swaps in `effect_instance_id`, `plan_identity`,
  `authority_grant_id` and drops `agent_id` and transport fields.
- `Command.new/2` keeps returning a struct. Add `Command.new_checked/2` returning
  `{:ok, cmd} | {:error, refusal}`; `CommandBus.admit` and the transport plug call it before
  any claim.
- Allowlist for `term_to_binary`, `phash2`, `inspect` reaching hashing: classify every one of
  the 50 sites by file:line as identity, storage or cache before the court is written
  (`receipt_outbox.ex` and `execution_snapshot.ex` storage; `refusal.ex:827`,
  `hook_reactor/engine.ex:140`, `graph_law/wasm.ex:269` caches).
- Golden vectors: `priv/identity/canonical_vectors.json`, recomputed by an independent
  implementation (named skip when absent).

## 11. Telemetry event names

Preserved unchanged (kernel emits them; shims live until the consumers, including
`test/ash_a2a_telemetry_ocel_*`, are converted `[skeptic: M01]`):

- `[:ash_a2a, :dispatch, :start | :stop | :exception]`
- `[:ash_a2a, :dispatch, :brce_gate]`
- `[:ash_a2a, :receipt, :committed]`
- the `Process.put(:ash_a2a_ocel_command_bus_dispatch)` correlation flag; also carried in
  `PreparedEffect.lineage`.

New:

| event | metadata |
|---|---|
| `[:ash_a2a, :kernel, :prepare, :start \| :stop \| :exception]` | `capability_id, consequence_class, effect_id` |
| `[:ash_a2a, :kernel, :execute, :start \| :stop \| :exception]` | same plus `prepared_effect_id, request_generation, execution_generation` |
| `[:ash_a2a, :kernel, :refused]` | `code, class, stage, capability_id` |
| `[:ash_a2a, :kernel, :effector, :apply, :start \| :stop \| :exception]` | `effector, effect_id` |
| `[:ash_a2a, :authority, :fence]` | `decision_id, epoch, outcome` |
| `[:ash_a2a, :budget, :reserve \| :settle \| :release \| :exhausted]` | `scope, dimension, cost` |
| `[:ash_a2a, :security_profile, :loaded \| :refused]` | `profile, digest, code` |
| `[:ash_a2a, :store, :begin_effect]` | `outcome, execution_generation` |
| `[:ash_a2a, :cancel, :hook_refused]` | `task_id, code` (replaces `:cancel_principal_mismatch` telemetry) |
| `[:ash_a2a, :egress, :attempt \| :refused]` | `purpose, endpoint_capability_id, code, pinned_ip` |
| `[:ash_a2a, :file, :effect \| :refused]` | `root_id, op, code` |
| `[:ash_a2a, :unknown_outcome, :marked \| :blocked]` | `effect_id` |

## 12. Conflict decisions

Each: decision, reason.

1. **Effector input: struct vs id (M01/M04/M08).** `Effector.apply/1` takes the
   kernel-fetched `%PreparedEffect{}`; it calls `verify_prepared/1` and refuses on mismatch.
   The kernel passes only the id downstream of `prepare`. `Dispatcher.dispatch_prepared/2`
   is dropped; the Ash body moves to `Effector.AshAction`. Reason: one contract, and the
   effector cannot trust a struct literal.
2. **HMAC key custody (M01).** Kernel-owned process state, no read API; `verify` is a
   `GenServer.call`. `:persistent_term` and Application env are refused (M01's own risk
   note contradicted its step 2). An in-VM adversary that can `:sys.get_state` the kernel is
   out of scope and stated so; a court asserts `:persistent_term.get` yields no key
   `[skeptic: M01]`.
3. **Keyed digest vs authenticated store.** Digest unkeyed, store seal authenticates.
4. **Claim order (M10 vs RFC-004:147).** Request claim then effect claim (section 7).
5. **New store callback names (M10 vs M11 vs M12).** Keep existing names, add
   `begin_effect/4`, `fetch_actuation/2`, `mark_actuation_unknown/3`, `recover_claim/4`.
6. **Generations (M12).** Both `request_generation` and `execution_generation` live on
   `PreparedEffect`; `begin_effect` checks both; a new `effect_instance_id` starts its own
   key at 1 and never resets a prior key.
7. **SecurityProfile vs SecurityPreflight/Decision (M04).** Reuse existing modules; one
   `Authority.Decision` type (extend it; ticket struct named `Authority.DecisionTicket`).
8. **Broker contract (M04/M05/M06).** `Authority.Broker` gets
   `issue_decision/3`, `verify_decision/3`, `resolve/4`, `epoch/1` as `@optional_callbacks`
   with fail-closed fallback during migration (chicago fixtures swap `:authority_broker` env).
   `authority_decision_id` = `Canonical.digest(%{"schema"=>"ash-a2a.authority-decision/v1",
   principal_id, capability_id, exact_subject, canonical_input_digest, effect_instance_id,
   authority_epoch, policy_epoch, capability_release_digest, constraints, resource_envelope})`
   (derived, not issued opaque). Constraints and envelope live at the broker. Unknown
   constraint keys fail closed except an allowlist of evidence-only keys
   (`:external_idempotency_token`). `admitted_by` on a caller-carried `%Authority{}` is
   ignored for broker selection and stripped `[skeptic: M06]`.
9. **`Authority.new/3` outside `Authority.*` (M05).** ~20 lib callers. Introduce
   `Authority.TestSupport.mint/3`; migrate callers; chicago lib modules are allowlisted only if
   declared non-production and excluded from the release build. The architecture rule
   allowlist is explicit paths, not a wildcard `[skeptic: M05]`.
10. **Refusal for `authority_constraint_mismatch` etc.** Single registration (section 4);
    CommandBus duplicates deleted.
11. **Observe path (M01/M03/M06).** Observe is fenced (authenticated principal, release,
    profile epoch, read-ceiling authority), needs no anchor and no `PreparedEffect`
    persistence beyond the sealed record, and produces an `:observation` receipt only when
    external I/O is declared. Classification is derived from the contract, never from
    `skill.consequence` alone.
12. **`:pure` class (M03).** Added additively to `Skill`, DSL, index, refusal. Derivation
    happens in the transformer (`Ash.Resource.Info` available); opaque module preparations,
    manual, `after_action` yield `:unknown`.
13. **Generic-`:action` `:observe` strict default (M03).** `strict_observe: true` from the
    profile; breaks `ash_a2a_agent_command_bus_test.exs:14` and `rfc004_agent_scope_test.exs:51`
    until they carry `effect_contract` attestations (in the edit list).
14. **`Receipt.standing` (M15).** Removed as a field; `Receipt.standing/1` is a derived
    function. Legacy receipts decode by ignore-and-recompute; binding `@version` bumps with
    the M14 Binding change (one bump, not two). Durability evidence reuses
    `Chicago.Collaborators.DurabilityProbe`, not a new mechanism `[skeptic: M15]`. Peer
    outcome stays a map plus a mint-sealed `:standing_seal` (no `%Peer.Outcome{}`).
15. **Continuation scope (M17).** `K = {principal_id, exact_subject, package_fingerprint}`; task
    id dropped (compile/close/replan are separate tasks). Derived closing `command_id =
    Identity.command(Canonical.digest(%{principal_id, fingerprint}))`. One external code
    `continuation_not_found`. Anonymous continuation refused in `dispatch_semantic` before
    compile. `PackageStore` arity changes with scope; per-principal cap default 1000
    `[skeptic: M17]`.
16. **`Dispatcher.dispatch/6` at stage A (M04/M08).** Refuse non-observe unless the
    `BrceAnchor` is authentic (outbox `fetch_authentic`), bound to principal, capability,
    input digest, and a broker-verified `Authority` is present. `BrceAnchor` refusal stays
    ordered first for the unanchored case so `check_sole_do_fence_refuses_unanchored_dispatch`
    still passes.
17. **Chicago fixtures in lib (M01 step 8, M08, M21).** Move all `chicago/fixtures/*` that
    call `Ash.create` and `Dispatcher.dispatch` to `test/support` behind `elixirc_paths`
    (`MIX_ENV=test`), or allowlist them by explicit path with a per-file justification; no
    "one-line re-point" `[skeptic: M01]`. Allowlists are digest-pinned file lists.
18. **Static "no raw effect" courts (M01, M08, M18, M19, M20, SEC-M21).** One shared adapter,
    AST-based (`Code.string_to_quoted`, aliases resolved, docs stripped), one allowlist file
    `priv/architecture/effect_allowlist.exs` (digest-pinned). Sinks: `Ash.create|update|
    destroy|run_action|stream|read|bulk_*`, `Req.*`, `ReqLLM.*`, `:httpc`, `:gen_tcp.connect`,
    `:ssl.connect`, `System.cmd`, `Port.open`, `:os.cmd`, `apply/2,3`, `:erlang.apply`,
    `Kernel.apply`, `Code.eval*`, `String.to_atom`, `Module.concat` (non-literal),
    `binary_to_term`, `File.write|rm|rm_rf|mkdir_p|rename`, `:dets.open_file`. Known dynamic
    sites the allowlist must classify: `delivery/oban.ex:91-96`, `execution/flame.ex:26`,
    `durability/durable_server.ex:139`, `receipt_outbox.ex:431`, `topology/{presence,group}.ex`,
    `a2a_transport/extended_card.ex:90`, `planning.ex:121`, `telemetry/metrics.ex:127`,
    `semantic/conformance.ex:217`, `semantic/machine_experience.ex:307,359`,
    `planning/hddl_solver.ex:100`, `graphlaw/*`, `graph_law/*`,
    `chicago/fixtures/logic_sparql.ex:403`, `chicago/mutation.ex:425`,
    `chicago/fresh_consumer.ex:996`, `chicago/release/composition_lock.ex`,
    `agent.ex:101` (compile-time). `xref` sees literal alias/remote-call edges only;
    `apply/3` with literals and `Module.concat` are caught by the runtime seal check
    (court wording pinned accordingly) `[skeptic: M01]`.
19. **Provider effects (M19/M20).** Oban, FLAME, Presence, DurableServer, OutboxStore
    resolve through `CallbackRegistry.fetch(kind, id)` with ids from `SecurityProfile`. On
    stage B they run as kernel effects (`Effector.Provider`); on stage A only the
    literal-id and env-provider closures land. `on_cancel` is module-only + `on_cancel_config`
    (JCS-digested into the capability release), executed as a `:change` compensation
    `PreparedEffect`; `CallbackRegistry` is not built for `on_cancel` (verifier + direct
    call suffice `[skeptic: M19]`); verifier logic lives inside `AshA2A.Verify`.
20. **Egress (M20).** `Network.Egress.request/2` requires a sealed `PreparedEffect`; no
    module-name caller check. OCEL ingest and push webhooks are `:external_do`.
    Admission is one `EndpointCapability.admit/4`; phase 0 (WebhookPolicy + `redirect: false`
    + pinned IP on the forwarder, `req_llm_opts!` allowlist) lands before the kernel.
21. **Budgets (M22).** Reuse `Semantic.Allocator.Budget` and `Semantic.Bounds`; `BudgetLedger`
    persists their state. No parallel counter algebra. Refusals reuse existing `bounds_*`.
    `bound_gate/3` at stage A sits in `pre_do_gate` after authority and kill switch; a refusal
    releases the claim via the existing `refuse_actuation` path. Observe consumes only the
    window budget. Observe: `Command.metadata` keys `lineage/depth/max_*` refuse
    `envelope_override_refused`; depth travels in `ExecutionContext`, not opts.
22. **Unknown-outcome gate (M13).** Store-level guards plus the replay path returns
    `{:error, %{code: :unknown_outcome_unresolved, receipt: r, outcome_known?: false}}`
    (breaks `command_bus_hardening_test.exs:214-219,243`; migrated in-lane). Resolved
    (reconciled) receipts still replay as evidence.
23. **Outbox key posture (M09/M18/M23).** One keyring; strict profile refuses unkeyed append;
    v1 legacy readable only by the migrate mix task.
24. **Receipt terminal evidence (M23).** Kernel-only transitions via
    `ConsequenceKernel.Token` (capability struct, checked at call, not module-name);
    `Receipt.finalize/reconcile/compensate/mark_unknown_outcome/from_reply` and
    `Binding.transition/bind` take it (`Reconciliation.mark_reconciled` included, which calls
    `Binding.transition` at `:330,:389` and `store.commit` at `:431`). Postcondition verifier
    is release-pinned (`capability_release.postcondition_verifier` + digest); pre-DO refusal at
    admission, not in `observe_postcondition`. Caller `:evidence_class`, `:plan_digest`,
    `:intended_effect`, `:chain_predecessor`, `:key` are deleted from receipt construction.
25. **`SecurityProfile` `file_roots` (SEC-M21).** One roots map; `FileObject.resolve/2` is the
    sole constructor; use-time `verify_at_use/1` re-lstat. Mix tasks run under a CLI profile
    that declares roots (no exemption). Path refusals map `:refused_bounds`.
26. **Capability release (M24).** `:legacy` mode and `release_config/1` opts/env reads deleted.
    Closure source: pinned artifact via `SecurityProfile`. `CapabilityIndex` skill gains
    `impl_digest` = `Canonical.digest` of `{id, resource module, action name, action type,
    input schema, effect class}` (no compile noise); coordinate with the in-flight
    `verify_resolved_skill` (compares struct `==`). Test suite installs a real release
    fixture in `test_helper.exs`.
27. **`Authority.Grant.policy/1` opts arity.** Keep a pure resolver for the Chicago
    `authority_policy` gate kind; production callers use the profile.
28. **Digest of `capability_release_digest`.** `CapabilityRelease.binding_digest/1 =
    Canonical.digest(binding)`; also covers `effect_contract_digest` (M03) and
    `on_cancel_config`.
29. **Test profile stability.** `install_for_test!/1` is `async: false` only and restores in
    `on_exit`. Existing tests move from `opts[:kill_switch_class]`, `:actuation_dedup`,
    `:capability_release_*`, `:authority_broker` to the installed profile
    (`test/support/security_profile_fixture.ex`).

## 13. Court rules

- Every court has a **pre-fix witness** (the attack succeeds on the unfixed subject) or is
  labelled REGRESSION-GUARD, not kill court. Courts asserting only `UndefinedFunctionError`
  do not count; each pairs with an observable-effect assertion (ledger rows, probe counter,
  listener hits).
- Courts needing `ConsequenceKernel`, `PreparedEffect`, `SecurityProfile`, `PreparedEffectStore`,
  `Authority` epoch, `EffectClaim` generation, `Allocator` effect dimension are tagged
  `BLOCKED(M01|M02)` and not runnable acceptance at stage A.
- Vacuous courts reassigned or dropped: SEC-M02-5 (regression guard), SEC-M03-2 rewritten
  to `sec_m03_generic_observe_optin_test.exs`, SEC-M04-2 rewritten (direct dispatch with a hand-put
  anchor and no authority), SEC-M05-8 (guard, extend `rfc004_agent_scope_test.exs`),
  SEC-M08-9 replaced by outbox-entry substitution, SEC-M10-1/2/3/7 rewritten per verdict,
  SEC-M11-1 paired with a differing-non-digest-field case, SEC-M12-1 rewritten (A passes
  the fence before B reclaims), SEC-M14-8 restricted to legacy-digest-in-snapshot,
  SEC-M18-1/4/7 replaced by valid-MAC hostile-ETF and valid-ETF-`Receipt` cases, SEC-M19-9
  relabelled regression guard, SEC-M20-1/2/9 split so only the opts-override/port/header
  clauses are red, SEC-M22-2 counter-based assertion, SEC-M24-3/5 assert typed refusals plus
  a pre-fix legacy-admits witness.
- Tests touching `Application` env or the profile: `async: false`, delete/restore env in
  `setup` (SEC-M04-1, SEC-M05-1, SEC-M16-5).
- Chicago rule: no `Mock`/`patch`/`monkeypatch`; fixtures are real modules or real minimal
  stores (fault-injecting store = real delegating module, documented reason).
- Mutation twin per gate registered in `priv/sa2a/chicago_mandatory_corpus.json`
  (shared file, owner: last lane to land; entries append only).
- Direct-`Dispatcher.dispatch` test files: **29**, not ~15 `[skeptic: M01]`; converted in-lane.

## 14. Open questions for the operator

1. `Command.new/2` return type: add `new_checked/2` (decided) or make `new/2` raise typed?
2. Are `agent_id`, `submitted_at`, provider, worker, transport excluded from request identity
   at phase 2 exactly as RFC-004 s5 states (assumed yes)?
3. Is a `:legacy_compat` profile wanted at all, or should the stage go straight to
   release-only? (The flag list in section 9 is the proposal.)
4. Symmetric HMAC seal vs an Ed25519 signer for `PreparedEffectStore`; symmetric is assumed.
5. `exact_subject` of a semantic `ExecutionPackage`: digest of source id and
   ontology/planning/candidate fingerprints. Confirm it equals `PreparedEffect.exact_subject`.
6. Integral-float refusal and tuple refusal will break existing inputs and lane-E
   `Determinism`; approve the sweep of `test/support` and chicago fixtures.
7. `observe` external I/O effect class: `:observe` with an observation receipt (assumed) vs
   `:external_do`.
8. OCEL forwarder event-time failure: shed (assumed) or block dispatch.
9. LLM path pinning: ReqLLM may not expose connect-IP pinning. Accept `UNSUPPORTED(pin)` with
   host allowlist plus no-redirect for LLM hosts?
10. Chicago court-plane modules (fresh_consumer `Port.open`, subject git, environment): stay
    in `lib` under a digest-pinned exemption, or move to `test/support`?
11. Legacy release mode: removed even for `legacy_compat` (assumed); confirm no deployment
    relies on it.
12. Reservation lease TTL default and strict envelope defaults (`max_invocations` 1 per
    instance, window quota per principal+capability).
13. `budget_scope` key: `{principal_id, root_request_id}` vs plan digest.
14. Whether `Receipt` `execution_generation` change lands with the `Binding` version bump in
    one migration (assumed yes) and who regenerates `CORPUS_DIGEST.sha256` and the golden replay
    corpora.
15. Ownership of `chicago_mandatory_corpus.json` and `refusal.ex` after RFC-004 lands.

## Merge resolution: origin/main W5 (claims/recovery) into local W5

Two W5 lineages met: local `factory/v26.9.29-c1-w5-claims-recovery-r17` (vector-only tests,
digest/`term_to_binary` identity helpers) and origin `Merge C1 W4/W5 protocol closure`
(authenticated claims, `ClaimProtocol`, claim stores, executable tests). Decisions:

- `W5.ClaimIdentity`, `W5.ReceiptChain`, `W5.ReplayEvidence`: origin side. Canonical JCS digests
  replace `term_to_binary`; `ReplayEvidence.verify/2` is required by `replay_match/mismatch`.
  Local tests for these are file-presence vectors and pass with either.
- `Runtime.{Prepare,Claim,Applying,Outcome}Stage`: local `PreparedDigest.fetch/1` accessors
  (fail closed with `:prepared_digest_missing`) kept; origin's `ClaimStage.claim_request/3` and
  `finalize/2` split kept, `run/3` composes them.
- `Runtime.Pipeline` stays the single DO path: prepare (`:key_provider` seals first) -> request
  and effect claim (`:claimed`) -> authority -> class admission -> `ClaimProtocol.claim` ->
  `begin_do` -> applying -> DO (exception/throw -> `UnknownOutcome`) -> outcome ->
  `PreparedEffectStore.complete` -> `ClaimProtocol.record_outcome`. Local kept the journal
  `:claimed` before authority (existing tests assert it); origin's later claim is added after
  class admission. The W5 claim is fail-closed: missing `:claim_store`, `:claim_store_handle`
  or `:claim_key` -> `:independent_effect_claim_store_required`. `consequence_kernel_test` and
  `authenticated_journal_test` were adapted to supply a real `EffectClaimStore.Memory`
  (fixtures gain `subject_digest`); assertions added on claim end state and receipt chain.
- Defects found by running the union, fixed at root: origin `claim_protocol.ex` did not parse
  (`with ... do:` followed by `else` block); `ClaimAuthenticator` crashed on non-binary owners
  (pids) via `to_string/1`; the claim MAC covered `state`, so `record_outcome` failed
  authentication after `begin_do` (state removed from the MAC body; transitions are
  `ClaimTransition`-admitted and receipt-chained).
- New refusal codes mapped in `lib/ash_a2a/semantic/refusal.ex` (W5 claim/recovery group).

## See Also

- `docs/rfc/RFC-SA2A-004-v26.9.28.md` - normative order and identity rules.
- `docs/rfc/RFC-SA2A-003-*` - bypass classes B1-B11 the mechanisms close.
- `docs/jira/v26.9.28-kernel/_LANES.md` - lane file ownership (written by the coordinator).
- `~/.claude/rules/same-checkout-fanout.md` - one checkout, disjoint file ownership.
