# Telemetry Reference

`ash_a2a` emits `:telemetry` events (the `:telemetry` library, a transitive
dependency). No reporter, poller, or metrics backend is configured by
default — attach your own handlers (`:telemetry.attach/4`,
[`:telemetry_poller`](https://hexdocs.pm/telemetry_poller/), or an
OpenTelemetry/Prometheus bridge) to consume them.

```elixir
:telemetry.attach("dispatch-log", [:ash_a2a, :dispatch, :stop], fn _event, measurements, metadata, _config ->
  Logger.info("dispatch #{metadata.skill_name} took #{measurements.duration}ns")
end, nil)
```

## Production event catalog

### Dispatch

| Event | Measurements | Metadata | Emitted by |
| --- | --- | --- | --- |
| `[:ash_a2a, :dispatch, :start]` / `[:ash_a2a, :dispatch, :stop]` (a `:telemetry.span`) | `duration` (native) on stop | `resource_or_domain`, `skill_name`; stop adds reply outcome, stage-tagged error `{:error, {stage, reason}}` on failure, and `object_id` (real identity of the acted-on record/instance, when one exists — never fabricated) | `AshA2A.Dispatcher.dispatch/6` (arities `/3`–`/5` remain valid via defaults) |
| `[:ash_a2a, :dispatch, :brce_gate]` | `system_time` | skill metadata + outcome/reason (sole-DO fence verdict) | `AshA2A.BrceAnchor` |
| `[:ash_a2a, :dispatch, :actuate]` | `system_time` | skill metadata + `anchored: boolean` | `AshA2A.BrceAnchor` |

### Agent process

| Event | Measurements | Metadata | Emitted by |
| --- | --- | --- | --- |
| `[:ash_a2a, :agent, :dispatch]` | `system_time` | routing metadata + `resource_or_domain` | `AshA2A.Agent` |
| `[:ash_a2a, :agent, :cancel]` | — | `resource_or_domain`, `task_id`, `context_id`, `actor`, `tenant` | `AshA2A.Agent` |
| `[:ash_a2a, :agent, :cancel_hook_error]` | — | same + error | `AshA2A.Agent` / `AshA2A.OnCancel` |

### CommandBus & receipts (consequence-bearing skills)

| Event | Measurements | Metadata | Emitted by |
| --- | --- | --- | --- |
| `[:ash_a2a, :command_bus, :preflight / :target / :admission / :kill_switch / :claim / :prepare / :actuate:start / :actuate:stop / :commit]` | `system_time` | `command_id`, `capability_id`, `principal_id` + stage outcome/code | `AshA2A.CommandBus` |
| `[:ash_a2a, :command_bus, :postcondition]` | — | outcome, reason, `postcondition_id`, verifier, `independent` | `AshA2A.Postcondition` |
| `[:ash_a2a, :receipt, :outboxed]` | — | receipt (journaled `:pending` pre-dispatch) | `AshA2A.CommandBus` |
| `[:ash_a2a, :receipt, :committed]` | — | receipt (final, post-dispatch) | `AshA2A.CommandBus` |
| `[:ash_a2a, :receipt_outbox, :reconciler, :tick]` | `committed`, `remaining` | — (drain summary; opt-in reconciler) | `AshA2A.ReceiptOutbox.Reconciler` |
| `[:ash_a2a, :receipt_outbox, :reconciler, :stuck]` | `attempts` | `command_id`, `receipt_id`, `threshold` — one event per stuck journal entry past the threshold (opt-in reconciler) | `AshA2A.ReceiptOutbox.Reconciler` |
| `[:ash_a2a, :reconciliation, :classified / :reconciled / :compensated]` | `system_time` | `command_id`, `receipt_id`, receipt status, `resolved_as`, label | `AshA2A.Reconciliation` |

### Authority

| Event | Measurements | Metadata | Emitted by |
| --- | --- | --- | --- |
| `[:ash_a2a, :authority, :decision]` | `system_time` | `outcome: :granted \| :refused`, `reason`/`code` (refusal code; `nil` when granted), capability, policy | `AshA2A.Authority.Grant` — the one decision event (RFC-SA2A-002 §12/§18) |
| `[:ash_a2a, :authority, :grant, :issue / :revoke / :renew]` | `system_time` | lifecycle outcome + reason | `AshA2A.Authority.Grant` |
| `[:ash_a2a, :authority, :decision_envelope, :verdict]` | — | envelope verdict (`:outcome`, `:code`) | `AshA2A.Authority.Decision` |

### Planning, semantic, evidence

| Event | Measurements | Metadata | Emitted by |
| --- | --- | --- | --- |
| `[:ash_a2a, :planning, :admit]` | `capability_count` | outcome/code, planner, formalism, fingerprint, standing, authority | `AshA2A.Planning` |
| `[:ash_a2a, :router, :tier_selected]` | — | router tier | `AshA2A.Planning.RequestRouter` |
| `[:ash_a2a, :planner, :invoke]` | — | planner invocation | `HddlSolver`, `SemanticSynthesis` |
| `[:ash_a2a, :llm, :invoke]` | — | LLM role invocation | `AshA2A.Semantic.Compiler` |
| `[:ash_a2a, :reconciliation, ...]` (above) | | | |
| `[:ash_a2a, :evidence, <decision>]` | `system_time` | outcome/code, chain digest | `AshA2A.Evidence.Class` |
| `[:ash_a2a, :sa2a, :conformance, :runtime_identity / :judged / :vector_judged / :replayed]` | — | conformance decision fields | `AshA2A.SA2A.Conformance` |
| `[:ash_a2a, :ocel, :shed]` | — | `url`, `reason` | `AshA2A.Telemetry.OcelForwarder` (bounded-fanout shed counter) |
| `[:ash_a2a, :semantic, :machine_experience, :register / :compile_back / :unregister]` | `classes` (register/unregister), `count: 1` (compile_back) | `class`, `kind`, `fingerprint` (register/compile_back); `class`, `reason`, `removed` (unregister — fires even when the class is absent, reporting `removed: false`) | `AshA2A.Semantic.MachineExperience` |
| `[:ash_a2a, :hook_reactor, :hook, :admission / :evaluate]` | `duration_us` | hook metadata + `:outcome` | `AshA2A.Semantic.HookReactor` |
| `[:ash_a2a, :hook_reactor, :intent, :constructed / :idempotency]` | `duration_us` | intent construction / idempotency-check metadata + `:outcome` | `AshA2A.Semantic.HookReactor` |
| `[:ash_a2a, :hook_reactor, :cascade, :bound]` | `requested`, `ceiling` | cascade-bound metadata | `AshA2A.Semantic.HookReactor` |

### Chicago / QA harness events (internal)

A large `[:ash_a2a, :chicago, ...]` family (mutation, observer, court
manifest, collaborator scans, OCEL validation) is emitted by the
conformance-court **test harness**, not the dispatch path — see
`lib/ash_a2a/chicago/`. Do not build production dashboards on these.

## OCEL forwarding

`AshA2A.Telemetry.OcelForwarder` is auto-attached by
`AshA2A.Application` at boot (idempotent; zero-cost when unconfigured) and
forwards **three** events as OCEL v2 HTTP POSTs when
`config :ash_a2a, :ocel_ingest_url` is set:
`[:ash_a2a, :dispatch, :stop]`, `[:ash_a2a, :receipt, :committed]`, and
`[:ash_a2a, :receipt, :outboxed]`. A CommandBus-routed dispatch produces
exactly one merged event (dispatch-span fields folded into the
receipt-derived event), never two. Concurrent POSTs are bounded by
`config :ash_a2a, :ocel_max_in_flight` (default 256); beyond the ceiling
events are shed, counted, and reported via `[:ash_a2a, :ocel, :shed]`.
Forwarding is best-effort: non-2xx responses and network failures are
logged and swallowed, never raised into dispatch. See
[Observe dispatch with OCEL](../how-to/observe-dispatch-with-ocel.md).

## Router tier counters

`AshA2A.Telemetry.RouterCounters` is the reference consumer of
`[:ash_a2a, :router, :tier_selected]` — an opt-in, in-process `:counters`
instrument (never auto-attached) counting the deterministic/phrase/llm tier
split of `AshA2A.Planning.RequestRouter.route/3`. `new/0` makes a zeroed
reference, `attach!/2`/`attach!/3` attach it (each instance owns its own
counters storage), `counts/1` reads `%{deterministic: n, llm: n, phrase: n}`,
and `detach/1` removes the handler. `attach!/3`'s `:owner` option isolates
sources per emitter: `:any` (default) counts every emitter on the node,
while a pid counts only events emitted by that process — so overlapping
instances (concurrent test drivers, per-request measurement) never inflate
each other's counts.
