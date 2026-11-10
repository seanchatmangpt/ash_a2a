# PPlan Seams

See Also: [[message-lifecycle]] · [[architecture]] ·
package-boundary (~/ash_pplan/docs/PACKAGE-BOUNDARY.md)

## The two seams to `~/ash_pplan`

ash_a2a talks to `~/ash_pplan` through two independent, non-overlapping
seams. They call disjoint ash_pplan API surfaces and are kept separate
by design (reconciled 2026-10-04, lane P3):

| seam | module | ash_pplan surface | consumers |
|---|---|---|---|
| replan candidate policy | `AshA2A.Replan.Port.AshPPlan` | `AshPPlan.SA2A.Provider.propose/2` (owner adapter); fallback `AshPPlan.select_policy/3` (`:fond`) and `AshPPlan.plan/1` (`:powl`) | `AshA2A.Replan.Loop.run/4` via xaas `Xaas.Ultracode.SemanticDrive.PlanNext` `@ports`; registered in `AshA2A.Replan.ProviderRegistry` as `:ash_pplan` |
| task durability | `AshA2A.Providers.PPlan` | `AshPPlan.Reactor.Durable.Engine` (`start/attempt/signal/fetch/cancel`), `AshPPlan.Reactor.Durable.Run.store_module/1`, `AshPPlan.Reactor.Durable.Status.terminal?/1` | `AshA2A.Execution.PPlan` (`@provider`), `AshA2A.Providers.PPlanNotify` (read-only polling), `mix ash_a2a.install --with-pplan` (name-only config) |

## Why NOT one seam (no delegation)

Delegation — the port's execution primitive delegating to the provider —
was considered and rejected on the real call graphs:

* The port never runs a durable run. Its `propose/2` selects a policy
  (owner adapter) or unwraps a `:powl` plan (legacy fallback) and
  returns a candidate (`authority: :none`, `standing: :candidate`) for
  `AshA2A.Replan.Loop`. The provider's `dispatch/4` starts or adopts a
  task-id-keyed durable run and returns A2A task states. The return
  semantics differ; results are not interchangeable.
* Delegating would either (i) route `propose/2` through
  `Engine.start/attempt` — an actuation side effect in what xaas
  consumes as a candidate-only seam (the drive journals the candidate,
  never auto-admits; starting a durable run inside `propose/2` would
  add a real execution to a seam whose whole point is that nothing is
  executed) — or (ii) route dispatch through the port's owner adapter
  `AshPPlan.SA2A.Provider`, a semantic mismatch: policy selection is
  not durable execution. Either direction changes xaas-visible
  behavior, so per the reconciliation contract: do NOT delegate.
* Zero shared Engine-calling code. A call-site census of
  `AshPPlan.Reactor.Durable.Engine` in `lib/` shows exactly two
  wrappers: `AshA2A.Providers.PPlan` (all Engine functions) and
  `lib/ash_a2a/providers/pplan_notify.ex` (read-only `fetch` polling,
  lane P2's file). The port touches no Engine function. The contract's
  extraction condition ("both independently wrap Engine.start/attempt")
  does not hold — there is nothing shared to extract, so no
  `AshA2A.Execution.PPlan` (adapter) and `AshA2A.Providers.PPlanNotify` (completion bridge) internal modules were created.

## Consumers preserved

* xaas (`Xaas.Ultracode.SemanticDrive.PlanNext`) calls
  `AshA2A.Replan.Loop.run(subject, request, [{"ash_pplan", AshA2A.Replan.Port.AshPPlan}], max_attempts: 3)`;
  the port's `supports?/1` (`[:fond, :powl]` membership) and `propose/2`
  candidate contract (including the legacy `select_policy/3` fallback
  selectable via the `:ash_pplan_provider_module` / `:ash_pplan_module`
  opts) stay source-compatible.
* `AshA2A.Execution.PPlan` and `AshA2A.Providers.PPlanNotify` call the
  provider's `dispatch/4` / `resume/3` / `status/2` / `cancel/2` /
  `to_state/1` / `available?/0` API, unchanged.

## Integration-court inventory (cross-repo, `:pplan_court` tag)

One-command runner: `mix ash_a2a.pplan_courts` (receipt at
`receipts/pplan-courts-<date>.md`; zero discovered courts is UNVERIFIED,
never PASS). Court families on disk:

| court | file | what it proves |
|---|---|---|
| parity | `test/ash_a2a/replan/ash_pplan_port_parity_court_test.exs` | the replan port's candidate contract matches the real ash_pplan surface (owner adapter vs `select_policy/3`/`plan/1` fallback) |
| conformance | `test/replan/port_ashpplan_conformance_court_test.exs` | the port honors the declared provider API against the real AshPPlan modules |
| binding | `test/execution/task_run_binding_test.exs` | A2A task ids bind to durable pplan run ids across the provider seam |
| dispatch-durability | `test/execution/pplan_dispatch_durability_test.exs` | `dispatch/4` runs survive across restart through the durable engine |
| hazard-bridge | `test/telemetry_bridge/pplan_hazard_bridge_test.exs` | pplan engine telemetry maps into the ash_a2a hazard/strain bridge |
| OCEL-evidence | `test/ash_a2a_pplan_ocel_evidence_court_test.exs` | pplan execution emits OCEL-consumable evidence events |
| margin-gate | `test/ash_a2a_margin_gate_e2e_test.exs` | the financial-margin-envelope pack gates real plans end to end |

Path mode (`ASH_PPLAN_PATH`, below) is required for these courts; Hex-pin
mode exercises only the published API surface.

## Falsifiers

* Delegation falsifier (open): if a real caller ever needs the port's
  candidate to BE a durable run (candidate == run id), the division is
  wrong and a single-seam design must be re-derived; until observed,
  the two-seam division stands.
* No-duplication falsifier: if `AshA2A.Replan.Port.AshPPlan` ever calls
  any `AshPPlan.Reactor.Durable.Engine` function, this doc is stale and
  the seams have collapsed; re-reconcile.

## Dependency wiring (dev-only path override)

The `ash_pplan` dep in `mix.exs` is a Hex pin (`~> 26.10`) by default.
Setting `ASH_PPLAN_PATH` to a local canonical checkout (e.g.
`/Users/sac/ash_pplan`) switches the dep to `path:` at mix.exs eval time
(`System.get_env/1` — deps do not read env at compile time, so eval-time
selection is the only supported toggle).

* Default (no env): Hex pin. `mix.lock` pins 26.10.3; **ash_a2a CI always
  uses the Hex pin** — CI never sets `ASH_PPLAN_PATH`.
* Path mode: `ASH_PPLAN_PATH=.../ash_pplan MIX_ENV=test mix deps.get
  deps.compile ash_pplan && MIX_ENV=test mix compile`. Path deps are not
  recorded in `mix.lock`, so the stale Hex row is tolerated while the env
  is set; after unsetting, `mix deps.get` restores the Hex lock (verified
  round-trip, both compile exit 0).
* Cross-repo courts (`mix ash_a2a.pplan_courts` and other integration
  courts exercising real AshPPlan behavior against the local checkout)
  require path mode; Hex-pin mode exercises only the published API
  surface.
* Local parity is a **dev-only mode**: results from a path-mode run are
  not a Hex-release verdict — upstream W-lanes may be mid-flight in the
  local tree (as of 2026-11-07 the path dep compiles exit 0 but emits
  warnings from `lib/ash_pplan/playground/telemetry_broadcaster.ex`).

## Durability repairs upstream (what the consumer sees)

Since the two-seam reconciliation (2026-10-04) the ash_pplan durable store
hardened along three axes. Consumer-visible summary (seam level, not engine
internals):

* **Atomic `take_signal`** — the parked-Await resume path is now one
  serialized store transition: find/adopt-or-insert checkpoint, consume the
  signal, release the waiter. A resume can no longer replay a signal that a
  concurrent attempt already consumed (the Await replay window is closed;
  witnessed by the binding and dispatch-durability courts).
* **Terminal-signal refusal** — a signal delivered to a run already in a
  terminal status is refused (`{:error, :terminal}`); likewise a
  terminal-status run refuses NEW checkpoints (`{:error, :terminal}` /
  `{:error, :cancelling}`), while adoption of an existing key is unchanged.
  Consumers see late signals after cancel/complete as a typed refusal, not a
  silent state change.
* **Intent boundary = the checkpoint record** — a step's intent is durable
  exactly when its checkpoint is. The residual gap is the effect-to-record
  window: a kill between a step's effect execution and its `record` checkpoint
  leaves the effect re-executed on resume. That is the one boundary the
  dispatch-durability court still skips loudly (the Z18 kill-court skip names
  the boundary in its skip reason); it is pending an upstream
  intent-before-effect guard (claim_undo before the effect) and is not
  fixable from the ash_a2a side of the seam.
