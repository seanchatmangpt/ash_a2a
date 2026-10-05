# PPlan Seams

See Also: [[message-lifecycle]] · [[architecture]]

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

## Falsifiers

* Delegation falsifier (open): if a real caller ever needs the port's
  candidate to BE a durable run (candidate == run id), the division is
  wrong and a single-seam design must be re-derived; until observed,
  the two-seam division stands.
* No-duplication falsifier: if `AshA2A.Replan.Port.AshPPlan` ever calls
  any `AshPPlan.Reactor.Durable.Engine` function, this doc is stale and
  the seams have collapsed; re-reconcile.
