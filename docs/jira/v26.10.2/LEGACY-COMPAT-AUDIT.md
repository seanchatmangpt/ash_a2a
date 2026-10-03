# Legacy-Compat Audit (D6)

RFC-SA2A-007 boot preflight names six legacy-compat conditions. This audit
enumerates every in-repo consumer of them, classifies each consumer, migrates
the ones where a durable equivalent is honest, and states the retirement
criterion for the `:legacy_compat` profile itself. The profile machinery
(`AshA2A.SecurityProfile`, `AshA2A.SecurityProfile.Boot`) is sanctioned and
untouched: this audit only removes the *need* for it in-repo.

## The six conditions

`AshA2A.SecurityProfile.Boot.violations/2` refuses these under `:strict`:

| condition | boot env key | strict requirement |
|---|---|---|
| `receipt_store_in_memory` | `:receipt_store` | not `AshA2A.ReceiptStore.Memory` |
| `outbox_dir_not_durable` | `:receipt_outbox_dir` | `ReceiptStore.durable_path?/1` (non-tmp) |
| `outbox_key_missing` | `:receipt_outbox_key` / `:receipt_binding_key` | >= 32-byte HMAC key |
| `capability_release_mode_legacy` | `:capability_release_mode` | `:strict` |
| `authority_broker_missing` | `:authority_broker` | non-nil broker |
| `kill_switch_class_missing` | `:kill_switch_class` | non-nil class |

## Which profile runs in-repo

The compiled profile is per-env (`config/config.exs`): `:dev_bypass` (test),
`dev.exs` (dev), `:strict` (prod). Under `:dev_bypass`,
`Boot.enforce!/2` computes no strict violations at all, so **no in-repo
consumer boots under `:legacy_compat`**. The only in-repo producer of the six
`legacy_compat` warnings is the profile court itself
(`test/ash_a2a/security_profile/boot_test.exs`), which calls
`Boot.enforce!(:legacy_compat, bad)` — the machinery under test, class (b)
below by definition.

The cousin warnings *are* witnessed on real runs: the outbox writer warns
`no :receipt_outbox_key ... UNTAGGED` on every real `CommandBus.run` that
journals a `:change` command (witnessed 2026-10-02 on
`test/ash_a2a_telemetry_ocel_forwarder_command_bus_test.exs`
pre-migration), and `AshA2A.Application` warns
`receipts are not durable in this runtime` at boot because the suite runs on
the default Memory receipt store.

## Classification law

- (a) **migrate** — a durable equivalent is honest: the court's subject is
  not the Memory/legacy surface, every assertion survives the swap, and the
  swap does not break the file's async/serial contract.
- (b) **stays** — the Memory/InMemory/legacy surface *is* the subject: unit
  tests of the store/broker behavior itself, honesty guards (Memory refuses
  to upgrade standing to `:durable`), asserted limitations, and courts whose
  subject is the compat surface.
- (c) **N/A** — snapshot-map fixtures with no store process or env consumer.

## Census

### receipt_store_in_memory

`grep -rl ReceiptStore.Memory test/` = 63 files: 13 under `test/ash_a2a/chicago/`
and 4 more chicago-named top-level files (C7's courts, out of lane scope),
leaving **46 non-chicago consumers**, classified:

| consumer(s) | class | law |
|---|---|---|
| `test/ash_a2a_telemetry_ocel_forwarder_command_bus_test.exs` | (a) **MIGRATED** | subject is OCEL event dedup on the wire; store durability is irrelevant to the subject, so the durable store is the honest default. Swapped the incidental Memory store for a real on-disk EKV instance (receipt_store_ekv_test.exs:25-36 pattern: unique name + `data_dir` + `cluster_size: 1` + `on_exit` cleanup) and added `receipt.standing == :durable` so the swap is falsifiable. |
| `test/ash_a2a_failure_injection_test.exs` describe(4) | (a) **MIGRATED** | subject is the `:authority_mismatch` refusal; the "nothing was committed" post-condition is store-agnostic. Same EKV pattern; `ReceiptStore.Ekv.fetch/2` now carries the post-condition. |
| `test/ash_a2a/receipt_store_ekv_test.exs` | (b) | subject is the store contract itself; the Memory clauses are the comparate (in-flight, replay, `:observed` standing) |
| `test/ash_a2a_receipt_r_projection_test.exs` | (b) | Memory use is the dishonesty guard: "the same command over Memory refuses rather than claiming durability" |
| `test/ash_a2a_command_bus_concurrency_test.exs` | (b) | subject is `CommandBus.run/4` racing `Memory`'s serialized `handle_call` |
| `test/ash_a2a_actuation_identity_test.exs` | (b) | enforcement against the real Memory store is the court |
| `test/ash_a2a_authority_confused_deputy_test.exs` | (b) | InMemory broker is the subject (asserted LIMITATION clause); store incidental to it |
| `test/support/governed.ex` | (b) | helper contract is async-safe, no-disk, real-GenServer collaborators; standing is never asserted through it |
| `test/support/crashing_receipt_store_fixture.ex`, `test/support/receipt_crash_window_fixture.ex` | (b) | crash-window fixtures instrument a base store; the crash-window courts own the wiring |
| `test/capability_release_standing_integration_test.exs` | (b) | MutatingStore implements the store behaviour delegating to Memory to inject a tamper window — the tamper seam is the subject |
| `test/ash_a2a/application_runtime_test.exs` | (b)/(c) | subject is the durability-report/refusal machinery; the non-durable runtime facts are the fixture |
| `test/ash_a2a/security_profile/boot_test.exs` | (c) | profile court over snapshot maps; no store process |
| `test/ash_a2a_receipt_s31_fields_test.exs`, `test/hilt_work_order_graph_digest_test.exs` | (b) | D6 gate trio members; Memory receipts are the fixtures for the receipt-shape/projection courts |
| remaining ~30 files (command_bus_test, kill_switch courts, oban_*, gall_*, semantic_*, flame_*, lifecycle/reactor, receipt_outbox_*, receipt_store/*) | (b) | store incidental but each file is a fixed-store real-collaborator court with store-agnostic assertions; migrating buys zero bit strength, and the lane's diff law is a small coherent diff, not a mass sweep. Named here rather than hand-waved. |

### outbox_dir_not_durable and outbox_key_missing

| consumer | class | law |
|---|---|---|
| `test/test_helper.exs` suite-wide per-run tmp outbox dir; no key in any config | (a, **handed off**) | the honest fix is config-level (`config/test.exs` — config lane's file): a persistent `:receipt_outbox_dir` and a `:receipt_binding_key` >= 32 bytes. Per-file fixes would race the shared env key across `async: true` modules. |
| rfc004_outbox_integrity, journal, receipt_binding_attestation courts | (b) | keyed/durable outboxes are per-test configured — the keyed path is already exercised in-repo; the outbox placement is the subject |
| crash-window / hardening / reconciler courts | (b) | outbox dir is the subject |

### capability_release_mode_legacy

| consumer | class | law |
|---|---|---|
| boot env unset suite-wide; `test/capability_release_test.exs` passes `capability_release_mode:` per-call | (b) + handoff | no per-test consumer needs a legacy boot mode; `:strict` is already exercised per-call. The boot-env lever is `config/test.exs` (config lane). |

### authority_broker_missing

| consumer | class | law |
|---|---|---|
| `config/test.exs` + `test/test_helper.exs`: shared run-wide `Broker.InMemory` | (b) | documented contract: one shared broker, grants keyed on `(principal, capability)` so `async: true` modules do not collide; the durable broker is courted separately (`authority_broker_ekv_test.exs`). Broker is never *missing* in-repo — the condition has no in-repo consumer. |

### kill_switch_class_missing

| consumer | class | law |
|---|---|---|
| boot env unset suite-wide | (a, **handed off**) | per-test consumers already set/pass `:kill_switch_class` explicitly (`rfc004_authority_effect_kill` put_env, `command_bus_kill_switch`/`kill_switch_durability` per-call) — the strict-satisfying value is the established in-repo usage; the boot-env default is `config/test.exs`'s lever |

## Retirement criterion for `:legacy_compat`

`:legacy_compat` becomes deprecable upstream when BOTH hold:

1. **Zero in-repo consumers boot under it** — already true today (the
   in-repo compiled profiles are `:dev_bypass`/`:dev`/`:strict`; only the
   profile court constructs a `:legacy_compat` run, as the machinery's own
   fixture). Recheck: `grep -rn "legacy_compat" config/ lib/` shows only the
   profile definition and its court.
2. **No documented host path recommends it** — verify no how-to/reference
   doc instructs a host to select `:legacy_compat`
   (`docs/reference/conformance-claim.md` and
   `docs/reference/telemetry.md` mention it only as behavior-of-record:
   forced NOT CONFORMANT + the
   `[:ash_a2a, :security_profile, :legacy_compat]` telemetry event).

Until then the profile stays as shipped: it is host-facing machinery, and
this repo's own suite needs neither it nor — after the two migrations above —
its warnings anywhere except its own court.

## Handoff to the config lane

Migrating the remaining boot-env conditions requires `config/test.exs`
(outside this lane's ownership): a persistent `:receipt_outbox_dir`, a
`:receipt_binding_key` (>= 32 bytes), `:capability_release_mode, :strict`,
and `:kill_switch_class` — at which point every one of the six conditions has
zero in-repo consumers and criterion (1) above holds by construction.

## Gate receipts

`MIX_BUILD_ROOT=_build-d6 mix compile --warnings-as-errors` clean;
migrated files green (see the D6 lane report for tails).

## See Also

- `docs/how-to/migrate-legacy-to-strict.md` — the host-facing migration guide
- `lib/ash_a2a/security_profile/boot.ex` — the six conditions' definitions
- `test/ash_a2a/receipt_store_ekv_test.exs` — the real-durable-store pattern
  this audit's migrations follow
