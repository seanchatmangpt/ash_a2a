# ash_a2a v26.9.14 — Release Closure Receipt

**Generated:** 2026-09-14 · **Standing:** PARTIAL_ALIVE (see `remaining_falsifiers`)

## 1. Identity

| Field | Value |
|---|---|
| `release` | 26.9.14 |
| `base_sha` | `43414331d59f2c6ceef41bcf3327bf739ceb1bcc` (`main`) |
| `final_sha` | `4f873029382b2470808dd430158bd8d2e956d20a` |
| `branch` | `v26.9.14/release-closure` |
| `pr` | https://github.com/seanchatmangpt/ash_a2a/pull/18 (OPEN, not merged) |
| `files_changed` | 45 (+5721 / -46) |
| `commits` | 38 |

## 2. Test evidence (exact final SHA, hosted, not local-inferred)

| Field | Value |
|---|---|
| `tests` | 311 |
| `doctests` | 3 |
| `properties` | 9 |
| `failures` | 0 |
| `excluded` | 7 |
| `zero_mock` | true — `grep -rn "Mox\|:meck\|Mock(\|MagicMock\|unittest.mock\|monkeypatch" test/` → zero real matches (only doc-comment mentions naming what is *not* used) |
| `architecture_verifier` | 9/9 real checks PASS (`mix ash_a2a.verify_architecture`) |

## 3. Production-reachability flags (real production code paths, verified via test + architecture_verifier)

| Capability | Status | Evidence |
|---|---|---|
| `semantic_production_reachable` | ALIVE | `AshA2A.Agent.semantic_request?/2` gate real-compiles + real-dispatches (`check_semantic_requests_gate_compiles`, `check_unopted_semantic_request_falls_through`, `test/ash_a2a_agent_semantic_request_test.exs`) |
| `execution_package_production_reachable` | ALIVE | `AshA2A.Semantic.ExecutionPackage.to_reply/1` real-converts an admitted package to a real `Dispatcher.reply()` |
| `feedback_production_reachable` | ALIVE | receipt → feedback → replan closure (`lib/ash_a2a/semantic/feedback.ex`, wave-3 unit 2) |
| `replan_production_reachable` | ALIVE | `AshA2A.Agent.replan/3` gated on an admitted `:continuation_fingerprint`; `test/ash_a2a_agent_semantic_replan_test.exs` — replan candidates are `authority: none`, never auto-DO |
| `commandbus_only_do` | ALIVE | `AshA2A.Dispatcher.run_skill/4`'s change/external_do branches route through `CommandBus.run/4`; :read stays direct (not consequence-bearing) |
| `stable_command_identity` | ALIVE | `command_id` = real `A2A.Message.message_id` (or caller `:continuation_fingerprint`); `check_fingerprint_excludes_transport_timestamp` proves stability across a real ~2h `submitted_at` gap |
| `replay_verified` | ALIVE | `check_change_consequence_succeeds_with_matching_authority` — `receipt.replayed? == false` on first run; `CommandBus.run/4`'s `{:replay, receipt}` branch exercised in `test/ash_a2a_agent_command_bus_test.exs` |
| `conflict_verified` | ALIVE | `check_command_bus_conflict_refused_on_reused_command_id` — reused `command_id` + different content → `{:error, %{code: :command_conflict}}` |
| `authority_verified` | ALIVE | `check_change_requires_authority` — `:change` consequence with no `Authority` → `{:error, %{code: :authority_required}}` |
| `unknown_consequence_refusal_verified` | ALIVE | `check_unknown_consequence_refused` — `:unknown` consequence fails closed with `{:error, %{code: :consequence_unclassified}}` *before* any dispatch attempt |

## 4. Per-dependency real-integration flags

Per the required three-state law (REAL_INTEGRATED / OPTIONAL_REAL_INTEGRATED / UNSUPPORTED_AND_NOT_ADVERTISED, no ambiguous fourth state) — with one named exception below that does not cleanly fit any of the three:

| Dependency | Status | Evidence |
|---|---|---|
| `solver_real` (ferroplan/hddl_cli) | REAL_INTEGRATED | real `System.cmd/2` subprocess invocation; CI builds the exact pinned Rust binary (`cargo +1.97.1 build --release --locked`) |
| `reactor_real` | REAL_INTEGRATED | `lib/ash_a2a/reactor/command_workflow.ex` — real `Reactor.run/2` DAG execution (`test/ash_a2a/reactor_command_workflow_test.exs`), not a bare function call |
| `ash_state_machine_real` | REAL_INTEGRATED | `lib/ash_a2a/task_lifecycle.ex` uses `AshStateMachine` for real; `test/ash_a2a/task_lifecycle_state_machine_test.exs` |
| `oban_real` | REAL_INTEGRATED | `AshA2A.Delivery.Oban.enqueue/3` real-inserts into a real `oban_jobs` table (real Postgres); `Oban.Testing.perform_job/2` real-executes a real `Oban.Worker` |
| `ash_oban_real` | **DECLARED, UNEXERCISED** (disclosed gap — see §7) | `grep -rln "AshOban" lib/ test/` → zero matches. Dependency is declared and resolvable in `mix.exs` but no resource uses `use AshOban`; only plain `Oban` is real-exercised |
| `durable_server_real` | REAL_INTEGRATED | real single-node kill+restart (`test/ash_a2a/durable_server_real_restart_test.exs`) against `DurableServer.Backends.EKVStore` |
| `real_node_loss_verified` | REAL_INTEGRATED | `:peer.start/1` + `:peer.stop/1` — a real second BEAM node over real Erlang distribution (`test/ash_a2a/distributed_node_loss_test.exs`), OTP 28's `:slave` replacement |
| `group_real` | REAL_INTEGRATED | `test/ash_a2a/group_real_topology_test.exs` exercises `AshA2A.Topology.Group` against a real `:group` registry |
| `presence_real` | REAL_INTEGRATED | `test/ash_a2a_runtime_providers_integration_test.exs` — real `Phoenix.Presence` backed by real `Phoenix.PubSub` |
| `flame_real` | REAL_INTEGRATED (local backend) | `test/ash_a2a/flame_real_placement_test.exs` — real `FLAME.LocalBackend` placement, not cloud infra |
| `ash_r2rml_real` | REAL_INTEGRATED | `test/ash_a2a/semantic_projection_r2rml_real_test.exs` — real Turtle output via `AshR2RML.render/1` |
| `ocel_real` | REAL_INTEGRATED (with disclosed defect) | `AshA2A.Telemetry.OcelForwarder` real HTTP POST to a real local Bandit-backed sink (`test/ash_a2a_ocel_default_path_sink_test.exs`); double-emission defect disclosed in §7 |

## 5. Package / publish court

| Field | Value |
|---|---|
| `package_built` | true — `mix hex.build` exit 0 |
| `package_version` | 26.9.14 |
| `package_contents_verified` | true — unpacked via `mix hex.build --unpack`; 65 files (`lib/`, `priv/ggen/`, `mix.exs`, `README.md`, `CHANGELOG.md`, `LICENSE`, `hex_metadata.config`); zero scratch/test/secret files; 18 real dependency requirements match `mix.exs` exactly |
| `publish_dry_run` | PUBLISH_DRY_RUN_VERIFIED |
| `publish_dry_run_command` | `mix hex.publish --dry-run` |
| `publish_dry_run_exit` | 0 |
| `publish_dry_run_gate_verified` | true — confirmed from installed Hex source (hexpm/hex v2.5.1, `create_release/4`): `dry_run?` gates `send_release/2` (which calls `Hex.API.Release.publish()`) unconditionally on the flag, never on the confirmation prompt answer — structurally cannot reach the network publish call |

## 6. Hosted CI (exact final SHA — not inferred from local green)

| Field | Value |
|---|---|
| `hosted_ci` | EXACT_HEAD_CI_VERIFIED |
| `hosted_ci_sha` | `4f873029382b2470808dd430158bd8d2e956d20a` (matches `final_sha` exactly) |
| `hosted_ci_run` | https://github.com/seanchatmangpt/ash_a2a/actions/runs/34813358877 |
| `hosted_ci_conclusion` | success — real log: `3 doctests, 9 properties, 311 tests, 0 failures (7 excluded)` |
| `hosted_ci_prior_failure` | run 34811946430 on SHA `37045a2` real-FAILED (exit 2): `AshA2A.ObanDeliveryQualificationTest`'s `setup_all` could not reach Postgres — the CI workflow never provisioned one. Root-caused, fixed forward (commit `4f87302`: real `postgres:16` service matching `config/test.exs`), re-verified green on the corrected SHA. This is a real, disclosed pre-existing CI/local-parity gap this release's own new Oban work introduced, caught and closed within this same cycle — not silently absorbed into a "local green" claim |

## 7. Merge / publish / tag status

| Field | Value |
|---|---|
| `merged` | **false** |
| `published` | **false** |
| `tagged` | **false** |

No merge, publish, or tag was performed, per explicit constraint.

## 8. Disclosed, not resolved (real gaps — not silently claimed fixed)

1. **`ash_oban` declared but unexercised.** `mix.exs` requires `{:ash_oban, "~> 0.8"}`; zero real usage anywhere in `lib/` or `test/`. Only plain `Oban` (via `AshA2A.Delivery.Oban`) is real-integrated. Does not cleanly map to REAL_INTEGRATED or UNSUPPORTED_AND_NOT_ADVERTISED — named explicitly rather than forced into either bucket. **Addendum, post-merge:** resolved on `main` — `AshA2A.Test.Fixture.ScheduledSweep` (`test/support/scheduled_sweep_fixture.ex`) exercises a real `scheduled_actions` cron entry, qualified against a real Postgres-backed `oban_jobs` table by `test/ash_a2a/scheduled_sweep_qualification_test.exs` (3 tests, real `AshOban.Test.schedule_and_run_triggers/2`, no mocks). See `CHANGELOG.md`'s `[26.9.14]` entry for the real integration note this surfaced (the installed `ash_oban` version's worker only invokes scheduled actions via the generic-action path).
2. **OCEL double-event emission** on CommandBus-routed dispatch — real, asserted by `test/ash_a2a_ocel_default_path_sink_test.exs`, not yet deduplicated at the SHA this receipt was written for (`4f873029382b2470808dd430158bd8d2e956d20a`, PR #18 head). **Addendum, post-merge:** fixed independently on `epoch/v26.9.15-semantic-subject` (commit `c9e5509`) before this branch was merged into `main`; both fixes landed together in the real merge commit `06b8098`. `test/ash_a2a_ocel_default_path_sink_test.exs`'s own first test now asserts `length(events) == 1` and passes. This item is resolved as of `main`; left here unedited above (immutable point-in-time receipt) with this addendum rather than silently rewritten.
3. **`DurableServer` cross-node rehome unexercised** — only real single-node kill+restart is proven (`durable_server_real_restart_test.exs`); multi-node rehome needs a real multi-node fixture, not built this cycle.
4. **`consequence: :observe` resource-author override** — an intentional, compile-time-only, never remotely-triggerable escape hatch. Disclosed as a known design surface, not a defect.
5. **~58 ExDoc "references function/module ... but it is hidden" warnings** remain post-fix (doc build still succeeds, exit 0). Majority cross-reference other packages' (`A2A`, `DurableServer`, `Mix`) own `@doc false` internals — not ash_a2a's to un-hide. Remainder is ash_a2a's own `AshA2A.Agent.__dispatch__/3` cited narratively across `AshA2A.ArchitectureVerifier` moduledoc prose. Cosmetic; reformatting every instance to dodge ExDoc's autolinker was judged out of scope (doc-prose churn, not a defect). **Addendum, post-merge:** the ash_a2a-owned subset (5 hidden entities cited by arity in narrative prose across 10 files, grown to 64 raw / 32 unique warning lines by the time of the fix, not 58 — later additions this session added more citations of the same pattern) was resolved on `main`: dropped the trailing `/arity` from each backtick reference so ExDoc's autolinker stops attempting resolution, without un-hiding anything or changing any prose meaning. Verified via a real before/after `mix docs` run: 64 → 22 raw hidden-warning lines, the remaining 22 confirmed to be exactly the correctly-out-of-scope dependency/stdlib internals this item already named.
6. **Local `ash_a2a_test_pg` Docker container left running** (port 55432, up ~2h at receipt time) — not explicitly requested to be torn down; flagged for the user's own decision rather than acted on unprompted.

## 9. Standing

**PARTIAL_ALIVE.**

Fully ALIVE: CommandBus-only-DO enforcement on the real default dispatch path, consequence-semantics fail-closed behavior, stable command identity, replay/conflict/authority admission, semantic-request production surface (opt-in, non-silent), receipt-driven replanning (authority: none, never auto-DO), package build, dry-run publish (structurally verified non-mutating), exact-head hosted CI (after one real, disclosed, fixed-forward CI infra gap).

Not ALIVE / explicitly withheld by design: merge, publish, tag — all `false`, per hard constraint, not a limitation of the work.

Real, disclosed, unresolved: `ash_oban` unexercised; OCEL double-emission; DurableServer cross-node rehome; ~58 cosmetic doc-hidden-reference warnings.

## 10. Remaining falsifiers

- Merging PR #18 and re-running CI on the merge commit (not yet done — separate instruction required).
- A real multi-node `DurableServer` rehome test would falsify or confirm "cross-node rehome unexercised."
- Exercising `AshOban` for real (a resource using `use AshOban`) would either confirm or replace the "declared, unexercised" status.
- A real OCEL sink assertion counting exactly one event per CommandBus-routed dispatch would falsify or confirm the double-emission disclosure once fixed.

Claude-Session: https://claude.ai/code/session_017Dd9AnjCaRgumnhptViGXM
