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

## Event catalog (mirrors `AshA2A.Telemetry.Events`)

Status: verified (2026-11-16, Elixir 1.20.4 / OTP 29.1.1): `mix test test/telemetry_catalog_test.exs`,
6 passed.

This table mirrors `AshA2A.Telemetry.Events.all/0` (`lib/ash_a2a/telemetry/events.ex`)
by hand; if the two disagree, the module wins. It lists 184 events:
`[:ash_a2a, ...]` and `[:a2a, ...]` emitted from `lib/`, with spans expanded to
`:start` / `:stop` / `:exception`. `AshA2A.Telemetry.Events.attach_logger/1` logs
every one of them (event name, measurements, metadata keys only).

What the catalog does and does not promise:

- Event **names** are checked by `test/telemetry_catalog_test.exs`, a textual scan
  of `lib/`. It is only prefix-strong for dynamic-suffix emitters (for example
  `[:ash_a2a, :command_bus | suffix]`) and cannot tell an emitter from a consumer
  that merely names an event.
- Measurement and metadata keys are the primary keys at the emit sites, not a
  schema. The older per-family tables further down carry more narrative detail.
- `[:ash_a2a, :chicago, ...]` (conformance-court harness) events are not catalogued.
- `[:ash_a2a, :replan, ...]` and `[:ash_a2a, :gall, :closure, ...]` have no
  emitting caller in `lib/` (`AshA2A.Replan.Telemetry.emit/3` is never called;
  `AshA2A.Gall.Closure.TelemetryEnvelope` only builds a map), so they are not
  catalogued. See `AshA2A.Telemetry.Events.unemitted_prefixes/0`.

| Event | Measurements | Metadata | Description |
| --- | --- | --- | --- |
| `[:a2a, :agent, :call, :start]` | `system_time`, `monotonic_time` | `agent`, `message_id` | Protocol.call to an agent process (span start) |
| `[:a2a, :agent, :call, :stop]` | `duration`, `monotonic_time` | `agent`, `message_id` | Protocol.call to an agent process (span stop) |
| `[:a2a, :agent, :call, :exception]` | `duration`, `monotonic_time` | `agent`, `message_id`, `kind`, `reason`, `stacktrace` | Protocol.call to an agent process (span exception) |
| `[:a2a, :agent, :message, :start]` | `system_time`, `monotonic_time` | `reply_type` | agent message handling (span start) |
| `[:a2a, :agent, :message, :stop]` | `duration`, `monotonic_time` | `reply_type` | agent message handling (span stop) |
| `[:a2a, :agent, :message, :exception]` | `duration`, `monotonic_time` | `reply_type`, `kind`, `reason`, `stacktrace` | agent message handling (span exception) |
| `[:a2a, :agent, :cancel, :start]` | `system_time`, `monotonic_time` | `task_id` | agent cancel handling (span start) |
| `[:a2a, :agent, :cancel, :stop]` | `duration`, `monotonic_time` | `task_id` | agent cancel handling (span stop) |
| `[:a2a, :agent, :cancel, :exception]` | `duration`, `monotonic_time` | `task_id`, `kind`, `reason`, `stacktrace` | agent cancel handling (span exception) |
| `[:a2a, :bidi, :input]` | `count` | `task_id` | uplink message accepted into a running task |
| `[:a2a, :push_config, :volatile]` | `count` | `task_id`, `config_id` | push config stored in memory only |
| `[:a2a, :push_notification, :delivery]` | `duration` | `task_id`, `context_id`, `config_id`, `url`, `result` | push notification delivery result |
| `[:a2a, :task, :late_event_dropped]` | `count` | `task_id`, `terminal_state`, `event` | event after terminal state dropped |
| `[:a2a, :task, :transition]` | `system_time` | `task_id`, `context_id`, `from`, `to` | task state transition |
| `[:a2a, :task, :transition_refused]` | `system_time` | `task_id`, `from`, `to`, `reason` | illegal task transition refused |
| `[:a2a, :task_store, :put_failed]` | `count` | `task_id`, `reason` | task store put failed |
| `[:ash_a2a, :a2a_transport, :push, :attempt]` | `count` | `task_id`, `config_id`, `attempt`, `outcome` | one signed webhook push attempt |
| `[:ash_a2a, :agent, :cancel]` | - | `resource_or_domain`, `task_id`, `context_id`, `actor`, `tenant` | agent task cancelled |
| `[:ash_a2a, :agent, :cancel_hook_error]` | - | `resource_or_domain`, `task_id`, `error` | on-cancel hook raised or failed |
| `[:ash_a2a, :agent, :dispatch]` | `system_time` | `resource_or_domain`, `route` | agent routed a skill dispatch |
| `[:ash_a2a, :attestation, :build]` | - | `outcome`, `code` | attestation build decision |
| `[:ash_a2a, :attestation, :verify]` | - | `outcome`, `code` | attestation verify decision |
| `[:ash_a2a, :authority, :broker, :lookup]` | - | `outcome` | authority broker grant lookup |
| `[:ash_a2a, :authority, :decision]` | `system_time` | `outcome`, `reason`, `capability_id`, `policy` | authority grant decision (granted or refused) |
| `[:ash_a2a, :authority, :decision_envelope, :verdict]` | - | `outcome`, `code` | decision envelope verdict |
| `[:ash_a2a, :authority, :grant, :issue]` | `system_time` | `outcome`, `reason`, `capability_id` | authority grant issue lifecycle |
| `[:ash_a2a, :authority, :grant, :revoke]` | `system_time` | `outcome`, `reason`, `capability_id` | authority grant revoke lifecycle |
| `[:ash_a2a, :authority, :grant, :renew]` | `system_time` | `outcome`, `reason`, `capability_id` | authority grant renew lifecycle |
| `[:ash_a2a, :authzen, :monotonic, :refused]` | `system_time` | `code`, `digest`, `depth`, `parent_effective`, `requested`, `excess` | delegation widening refused |
| `[:ash_a2a, :cluster, :checkpoint, :terminal_skipped]` | `count` | `task_id`, `state` | terminal task not checkpointed |
| `[:ash_a2a, :cluster, :drain, :init]` | `count` | `drain_manager`, `drain_timeout_ms`, `signal_handler` | drain manager init |
| `[:ash_a2a, :cluster, :drain, :cordon]` | `count` | `drain_manager`, `reason`, `tracked` | drain manager cordon |
| `[:ash_a2a, :cluster, :drain, :complete]` | `count` | `drain_manager`, `checkpointed`, `cordon_to_exit_ms` | drain manager complete |
| `[:ash_a2a, :cluster, :drain, :task_skipped]` | `count` | `drain_manager`, `task_id`, `reason` | drain manager task_skipped |
| `[:ash_a2a, :cluster, :handover]` | `count` | `task_id`, `source_node`, `reason`, `checkpointed_at` | checkpoint handover broadcast |
| `[:ash_a2a, :cluster, :handover, :completed]` | `count` | `task_id`, `node` | handed-over task completed |
| `[:ash_a2a, :command_bus, :preflight]` | `system_time` | `command_id`, `capability_id`, `principal_id`, `outcome`, `code` | CommandBus preflight stage |
| `[:ash_a2a, :command_bus, :target]` | `system_time` | `command_id`, `capability_id`, `principal_id`, `outcome`, `consequence`, `code` | CommandBus target resolution stage |
| `[:ash_a2a, :command_bus, :admission]` | `system_time` | `command_id`, `capability_id`, `principal_id`, `outcome`, `consequence`, `code` | CommandBus admission stage |
| `[:ash_a2a, :command_bus, :kill_switch]` | `system_time` | `command_id`, `capability_id`, `principal_id`, `outcome`, `code` | CommandBus kill-switch stage |
| `[:ash_a2a, :command_bus, :claim]` | `system_time` | `command_id`, `capability_id`, `principal_id`, `outcome`, `code` | CommandBus claim stage |
| `[:ash_a2a, :command_bus, :prepare]` | `system_time` | `command_id`, `capability_id`, `principal_id`, `outcome`, `code` | CommandBus prepare stage |
| `[:ash_a2a, :command_bus, :commit]` | `system_time` | `command_id`, `capability_id`, `principal_id`, `outcome`, `status` | CommandBus commit stage |
| `[:ash_a2a, :command_bus, :work_order]` | `system_time` | `command_id`, `capability_id`, `principal_id`, `outcome`, `work_order_digest`, `code` | CommandBus work-order admission |
| `[:ash_a2a, :command_bus, :pre_do_gate]` | `system_time` | `command_id`, `capability_id`, `principal_id`, `outcome`, `code` | CommandBus pre-DO refusal gate |
| `[:ash_a2a, :command_bus, :lease_gate]` | `system_time` | `command_id`, `capability_id`, `principal_id`, `outcome`, `mask`, `code` | CommandBus two-port lease gate |
| `[:ash_a2a, :command_bus, :actuation_commit]` | `system_time` | `command_id`, `capability_id`, `principal_id`, `outcome`, `reason`, `receipt_id` | CommandBus actuation commit failed after retries |
| `[:ash_a2a, :command_bus, :commitment]` | `system_time` | `command_id`, `capability_id`, `principal_id`, `transition`, `consequence` | CommandBus conditional commitment transition |
| `[:ash_a2a, :command_bus, :actuate, :start]` | `system_time` | `command_id`, `capability_id`, `principal_id` | CommandBus actuation start |
| `[:ash_a2a, :command_bus, :actuate, :stop]` | `system_time`, `duration` | `command_id`, `capability_id`, `principal_id`, `outcome` | CommandBus actuation stop |
| `[:ash_a2a, :command_bus, :postcondition]` | - | `outcome`, `reason`, `postcondition_id`, `verifier`, `independent` | postcondition verdict |
| `[:ash_a2a, :command_bus, :swallowed_failure]` | `count` | `site`, `kind` | best-effort CommandBus step failed |
| `[:ash_a2a, :copilot, :stage_skipped]` | `count` | `stage`, `coordinator_id` | copilot pipeline stage skipped |
| `[:ash_a2a, :dispatch, :start]` | `system_time`, `monotonic_time` | `resource_or_domain`, `skill_name` | skill dispatch (span start) |
| `[:ash_a2a, :dispatch, :stop]` | `duration`, `monotonic_time` | `resource_or_domain`, `skill_name` | skill dispatch (span stop) |
| `[:ash_a2a, :dispatch, :exception]` | `duration`, `monotonic_time` | `resource_or_domain`, `skill_name`, `kind`, `reason`, `stacktrace` | skill dispatch (span exception) |
| `[:ash_a2a, :dispatch, :brce_gate]` | `system_time` | `outcome`, `reason` | sole-DO fence verdict |
| `[:ash_a2a, :dispatch, :actuate]` | `system_time` | `anchored` | dispatch actuation anchor |
| `[:ash_a2a, :enterprise, :pipeline, :completed]` | `duration_ns` | `stages`, `dlp_findings`, `cmek`, `affidavit` | enterprise pipeline completed |
| `[:ash_a2a, :enterprise, :pipeline, :refused]` | `duration_ns` | `stage`, `code` | enterprise pipeline refused |
| `[:ash_a2a, :episode, :planning]` | `duration_us` | `outcome` | semantic episode: planning stage |
| `[:ash_a2a, :episode, :allocation]` | - | `kind`, `outcome`, `code`, `envelope_id` | semantic episode: allocation decision |
| `[:ash_a2a, :episode, :start]` | - | `outcome` | semantic episode: episode reached executor |
| `[:ash_a2a, :episode, :admission]` | `duration_us` | `outcome`, `code` | semantic episode: episode admission |
| `[:ash_a2a, :episode, :bound]` | - | `outcome` | semantic episode: bound decision |
| `[:ash_a2a, :episode, :stop]` | `duration_us`, `memory_peak_bytes` | `outcome` | semantic episode: episode terminal outcome |
| `[:ash_a2a, :episode, :transition, :request]` | - | `outcome` | semantic episode: transition reached a stage |
| `[:ash_a2a, :episode, :transition, :start]` | `in_flight` | `outcome` | semantic episode: route admitted into window |
| `[:ash_a2a, :episode, :transition, :stop]` | `authority_us`, `do_us` | `outcome` | semantic episode: route outcome |
| `[:ash_a2a, :evidence, :promote]` | `system_time` | `from`, `to`, `prior_chain_digest`, `offered_evidence_digest`, `outcome`, `code`, `chain_digest` | evidence class promotion |
| `[:ash_a2a, :evidence, :assert]` | `system_time` | `from`, `to`, `prior_chain_digest`, `outcome`, `code`, `chain_digest` | evidence class assertion |
| `[:ash_a2a, :finops, :chargeback]` | `tokens`, `system_time` | `cost_center`, `budget_account_id`, `ceiling`, `consumed`, `admitted`, `code` | FinOps chargeback tag per admission decision |
| `[:ash_a2a, :graph_law, :wasm, :batch]` | `calls` | `wasm_path`, `outcome`, `code` | GraphLaw wasm batch (historical :graph_law spelling) |
| `[:ash_a2a, :graphlaw, :engine, :call]` | `system_time`, `verify_us`, `total_us`, `startup_us`, `peak_memory_bytes` | `outcome`, `mode` | GraphLaw engine call |
| `[:ash_a2a, :graphlaw, :engine, :load, :start]` | `system_time` | `bytes` | GraphLaw engine load start |
| `[:ash_a2a, :graphlaw, :engine, :load, :stop]` | `system_time` | `outcome`, `code`, `import_count`, `expected_sha256` | GraphLaw engine load stop |
| `[:ash_a2a, :graphlaw, :host, :recycle]` | `system_time` | `wasm_sha256`, `reason` | warm wasm host instance recycled |
| `[:ash_a2a, :health, :checked]` | `duration` | `status` | health check run |
| `[:ash_a2a, :hook_reactor, :hook, :admission]` | `duration_us` | `outcome` | hook reactor: hook meta-admission |
| `[:ash_a2a, :hook_reactor, :hook, :evaluate]` | `duration_us` | `outcome` | hook reactor: per-hook evaluation |
| `[:ash_a2a, :hook_reactor, :intent, :constructed]` | `duration_us` | `outcome` | hook reactor: candidate intent built |
| `[:ash_a2a, :hook_reactor, :intent, :idempotency]` | `duration_us` | `outcome` | hook reactor: receipt-store idempotency lookup |
| `[:ash_a2a, :hook_reactor, :intent, :route_start]` | - | `outcome` | hook reactor: route admitted into parallel window |
| `[:ash_a2a, :hook_reactor, :intent, :routed]` | - | `outcome` | hook reactor: CommandBus outcome for the intent |
| `[:ash_a2a, :hook_reactor, :cascade, :start]` | - | `outcome` | hook reactor: cascade start |
| `[:ash_a2a, :hook_reactor, :cascade, :bound]` | `requested`, `ceiling` | `outcome` | hook reactor: cascade bound decision |
| `[:ash_a2a, :hook_reactor, :cascade, :stop]` | - | `outcome` | hook reactor: cascade terminal outcome |
| `[:ash_a2a, :llm, :invoke]` | `count` | `site`, `role` | LLM role invocation |
| `[:ash_a2a, :planner, :invoke]` | `count` | `planner`, `role`, `outcome` | planner invocation |
| `[:ash_a2a, :logic, :closure, :start]` | - | `outcome`, `code` | logic closure stage start |
| `[:ash_a2a, :logic, :closure, :entailment]` | - | `outcome`, `code` | logic closure stage entailment |
| `[:ash_a2a, :logic, :closure, :engine]` | - | `outcome`, `code` | logic closure stage engine |
| `[:ash_a2a, :logic, :closure, :decision]` | - | `outcome`, `code` | logic closure stage decision |
| `[:ash_a2a, :logic, :closure, :stop]` | - | `outcome`, `code` | logic closure stage stop |
| `[:ash_a2a, :ocel, :delivered]` | `duration` | `endpoint` | OCEL POST delivered |
| `[:ash_a2a, :ocel, :failed]` | `duration` | `endpoint`, `status`, `reason` | OCEL POST failed |
| `[:ash_a2a, :ocel, :ignored]` | `count` | - | OCEL forwarder ignored an event |
| `[:ash_a2a, :ocel, :shed]` | `count` | `endpoint`, `reason` | OCEL event shed at in-flight ceiling |
| `[:ash_a2a, :ocel, :unconvertible]` | `count` | - | event not convertible to OCEL |
| `[:ash_a2a, :ocel_broadcaster, :dropped]` | `count` | `broadcaster`, `dropped_total` | SIEM buffer drop-oldest |
| `[:ash_a2a, :ocel_broadcaster, :flush_failed]` | `count` | `broadcaster`, `reason` | SIEM sink flush failed |
| `[:ash_a2a, :ocel_broadcaster, :unconvertible]` | `count` | `broadcaster`, `kind` | event not convertible for SIEM |
| `[:ash_a2a, :planning, :admit]` | `capability_count` | `outcome`, `code`, `planner`, `formalism`, `fingerprint`, `standing`, `authority` | plan admission |
| `[:ash_a2a, :planning, :preflight]` | - | `outcome`, `code` | plan preflight verdict |
| `[:ash_a2a, :protocol, :plug, :authorize_refused]` | - | `operation`, `task_id`, `refusal`, `wire_code` | protocol plug authorize refusal |
| `[:ash_a2a, :reactor, :compensate]` | `count` | `command_id`, `reason`, `options` | reactor compensation |
| `[:ash_a2a, :reconciliation, :classified]` | `system_time` | `command_id`, `receipt_id`, `status`, `resolved_as` | reconciliation classified |
| `[:ash_a2a, :reconciliation, :reconciled]` | `system_time` | `command_id`, `receipt_id`, `status`, `resolved_as` | reconciliation reconciled |
| `[:ash_a2a, :reconciliation, :compensated]` | `system_time` | `command_id`, `receipt_id`, `status`, `resolved_as` | reconciliation compensated |
| `[:ash_a2a, :receipt, :binding, :bind]` | - | `outcome`, `code` | receipt binding bind |
| `[:ash_a2a, :receipt, :binding, :verify]` | - | `outcome`, `code` | receipt binding verify |
| `[:ash_a2a, :receipt, :committed]` | - | `receipt` | final receipt committed |
| `[:ash_a2a, :receipt, :outboxed]` | - | `receipt` | pending receipt journaled pre-dispatch |
| `[:ash_a2a, :receipt_outbox, :decode_failed]` | `count` | `cause` | outbox journal entry undecodable |
| `[:ash_a2a, :receipt_outbox, :sync_dir_failed]` | `count` | `dir`, `reason` | outbox directory fsync failed |
| `[:ash_a2a, :receipt_outbox, :reconciler, :tick]` | `committed`, `remaining` | - | outbox reconciler drain summary |
| `[:ash_a2a, :receipt_outbox, :reconciler, :corrupt]` | `count` | `filenames`, `reasons` | undecodable journal files |
| `[:ash_a2a, :receipt_outbox, :reconciler, :stuck]` | `attempts` | `command_id`, `receipt_id`, `threshold` | journal entry stuck past threshold |
| `[:ash_a2a, :replay, :chain_sealed]` | `system_time` | `chain_id`, `chain_ref`, `length`, `commands`, `evidence_bytes`, `link_root`, `basis_root` | evidence chain sealed |
| `[:ash_a2a, :replay, :verified]` | `system_time`, `verify_us`, `total_us`, `startup_us`, `peak_memory_bytes` | `outcome`, `mode` | offline replay verdict |
| `[:ash_a2a, :router, :tier_refused]` | - | `tier`, `reason` | request router tier refused |
| `[:ash_a2a, :router, :tier_selected]` | - | `tier` | request router tier selected |
| `[:ash_a2a, :runtime, :configured]` | `system_time` | `receipt_store`, `durable`, `data_dir_tmp`, `receipt_outbox_dir_tmp` | boot-time runtime posture |
| `[:ash_a2a, :sa2a, :conformance, :judged]` | - | `outcome` | SA2A conformance judged |
| `[:ash_a2a, :sa2a, :conformance, :replayed]` | - | `outcome` | SA2A conformance replayed |
| `[:ash_a2a, :sa2a, :conformance, :runtime_identity]` | - | `outcome` | SA2A conformance runtime_identity |
| `[:ash_a2a, :sa2a, :conformance, :vector_judged]` | - | `outcome` | SA2A conformance vector_judged |
| `[:ash_a2a, :security, :dlp]` | `duration_ns`, `findings` | `types` | DLP filter run |
| `[:ash_a2a, :security_profile, :dev_bypass]` | - | `profile` | dev_bypass build stamped receipts |
| `[:ash_a2a, :security_profile, :legacy_compat]` | - | `profile` | legacy_compat boot posture |
| `[:ash_a2a, :semantic, :admission, :start]` | - | `candidate_digest` | semantic admission pipeline start |
| `[:ash_a2a, :semantic, :admission, :stage]` | - | `stage`, `outcome` | semantic admission stage attempted |
| `[:ash_a2a, :semantic, :admission, :stop]` | - | `outcome`, `code` | semantic admission pipeline stop |
| `[:ash_a2a, :semantic, :allocation]` | `count` | `class`, `resolver` | unknown-class allocation |
| `[:ash_a2a, :semantic, :allocator, :decision]` | - | `outcome`, `code` | semantic allocator decision |
| `[:ash_a2a, :semantic, :bounds, :delegate]` | - | `outcome`, `code` | semantic bounds delegation |
| `[:ash_a2a, :semantic, :canonical_graph, :digest]` | - | `outcome`, `code` | canonical graph digest |
| `[:ash_a2a, :semantic, :canonical_graph, :pin]` | - | `outcome`, `code` | canonical graph pin |
| `[:ash_a2a, :semantic, :canonical_graph, :compare]` | - | `outcome`, `code` | canonical graph compare |
| `[:ash_a2a, :semantic, :construct]` | - | `outcome`, `code` | CONSTRUCT pipeline stage |
| `[:ash_a2a, :semantic, :extension, :negotiate]` | - | `outcome`, `code` | extension negotiation |
| `[:ash_a2a, :semantic, :falsifier_suite, :admit]` | - | `outcome`, `code` | falsifier suite admission |
| `[:ash_a2a, :semantic, :hooks, :run]` | - | `outcome`, `code` | GraphLaw hook execution |
| `[:ash_a2a, :semantic, :ir_admission]` | - | `outcome`, `code` | IR admission verdict |
| `[:ash_a2a, :semantic, :iri, :mint_private]` | - | `outcome`, `code` | private IRI mint |
| `[:ash_a2a, :semantic, :iri, :resolve]` | - | `outcome`, `code` | IRI resolve |
| `[:ash_a2a, :semantic, :llm_boundary, :candidate]` | - | `outcome`, `code` | LLM boundary candidate |
| `[:ash_a2a, :semantic, :machine_experience, :register]` | `classes` | `class`, `kind`, `fingerprint` | machine-experience class register |
| `[:ash_a2a, :semantic, :machine_experience, :compile_back]` | `count` | `class`, `kind`, `fingerprint` | machine-experience compile-back |
| `[:ash_a2a, :semantic, :machine_experience, :unregister]` | `classes` | `class`, `reason`, `removed` | machine-experience class unregister |
| `[:ash_a2a, :semantic, :mapping, :register]` | - | `outcome`, `code` | mapping register (legacy call site) |
| `[:ash_a2a, :semantic, :mapping_registry, :register]` | - | `outcome`, `code` | mapping registry register |
| `[:ash_a2a, :semantic, :mapping_registry, :reconcile]` | - | `outcome`, `code` | mapping registry reconcile |
| `[:ash_a2a, :semantic, :meta_admission, :confer]` | `system_time` | `kind`, `outcome` | meta-admission confer |
| `[:ash_a2a, :semantic, :meta_admission, :standing]` | `system_time` | `kind`, `outcome` | meta-admission standing |
| `[:ash_a2a, :semantic, :ontology, :project]` | - | `outcome`, `code` | ontology projection |
| `[:ash_a2a, :semantic, :ontology_cache, :load]` | - | `outcome`, `code` | ontology cache load |
| `[:ash_a2a, :semantic, :peer, :receive]` | - | `activated`, `message_id` | peer received a message |
| `[:ash_a2a, :semantic, :peer, :admission, :start]` | - | `peer` | peer admission start |
| `[:ash_a2a, :semantic, :peer, :decision]` | - | `outcome`, `path` | peer admission decision |
| `[:ash_a2a, :semantic, :plan_package]` | `system_time` | `outcome`, `code`, `profile` | plan package decision |
| `[:ash_a2a, :semantic, :plan_package, :build]` | - | `outcome`, `code` | plan package build |
| `[:ash_a2a, :semantic, :plan_package, :verify]` | - | `outcome`, `code` | plan package verify |
| `[:ash_a2a, :semantic, :plan_projection, :verify]` | - | `outcome`, `code` | plan projection verify |
| `[:ash_a2a, :semantic, :root_manifest, :load]` | - | `outcome`, `code` | root manifest load |
| `[:ash_a2a, :semantic, :root_manifest, :verify]` | - | `outcome`, `code` | root manifest verify |
| `[:ash_a2a, :semantic, :root_manifest, :mutate]` | - | `outcome`, `code` | root manifest mutate |
| `[:ash_a2a, :semantic, :select]` | - | `outcome`, `code` | SELECT pipeline stage |
| `[:ash_a2a, :semantic, :sparql_update, :decision]` | - | `outcome`, `mutating` | SPARQL update admission decision |
| `[:ash_a2a, :semantic, :standing, :transition]` | - | `outcome`, `code` | standing ledger transition |
| `[:ash_a2a, :semantic, :term, :operational_use]` | - | `outcome`, `code` | term operational use (second call site) |
| `[:ash_a2a, :semantic, :term_registry, :build]` | - | `outcome`, `code` | term registry build |
| `[:ash_a2a, :semantic, :term_registry, :operational_use]` | - | `outcome`, `code` | term registry operational use |
| `[:ash_a2a, :semantic, :unknown, :admit_for_do]` | `count` | `class`, `reason` | unknown admitted for DO |
| `[:ash_a2a, :siem, :delivered]` | `events`, `duration` | `platform`, `endpoint` | SIEM batch delivered |
| `[:ash_a2a, :siem, :failed]` | `events`, `duration` | `platform`, `endpoint`, `reason` | SIEM batch failed |
| `[:ash_a2a, :task, :orphan_failed]` | `count` | `task_id` | orphan task failed by sweep |
| `[:ash_a2a, :task, :orphan_sweep_unsupported]` | `count` | `store`, `reason` | store cannot sweep orphans |
| `[:ash_a2a, :task_events, :journal_error]` | `count` | `task_id`, `seq` | task event journal error |
| `[:ash_a2a, :transport, :plug, :list_refused]` | - | `subject`, `refusal`, `wire_code` | task-list wire refusal |
| `[:ash_a2a, :transport, :request, :start]` | `system_time`, `monotonic_time` | `transport`, `method` | transport request (HTTP/JSON-RPC/gRPC) (span start) |
| `[:ash_a2a, :transport, :request, :stop]` | `duration`, `monotonic_time` | `transport`, `method` | transport request (HTTP/JSON-RPC/gRPC) (span stop) |
| `[:ash_a2a, :transport, :request, :exception]` | `duration`, `monotonic_time` | `transport`, `method`, `kind`, `reason`, `stacktrace` | transport request (HTTP/JSON-RPC/gRPC) (span exception) |
| `[:ash_a2a, :transport, :request, :error]` | `count` | `transport`, `method` | discrete transport error |

## Production event catalog

### Dispatch

| Event | Measurements | Metadata | Emitted by |
| --- | --- | --- | --- |
| `[:ash_a2a, :dispatch, :start]` / `[:ash_a2a, :dispatch, :stop]` (a `:telemetry.span`) | `duration` (native) on stop | `resource_or_domain`, `skill_name`; stop adds reply outcome, stage-tagged error `{:error, {stage, reason}}` on failure, and `object_id` (real identity of the acted-on record/instance, when one exists — never fabricated) | `AshA2A.Dispatcher.dispatch/6` (arities `/3`–`/5` remain valid via defaults) |
| `[:ash_a2a, :dispatch, :exception]` | `duration` | raised-exception metadata — emitted automatically by the span when dispatch raises | `AshA2A.Dispatcher.dispatch/6` |
| `[:ash_a2a, :health, :checked]` | `duration` | `status` (aggregated liveness/readiness verdict) | `AshA2A.Health` on every check run |
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
| `[:ash_a2a, :command_bus, :work_order]` | `system_time` | `command_id`, `capability_id`, `principal_id`, `outcome: :verified` + `work_order_digest`, or `outcome: :refused` + `code` (emitted only when opts carry `:work_order`) | `AshA2A.CommandBus` (HILT work-order admission) |
| `[:ash_a2a, :command_bus, :pre_do_gate]` | `system_time` | common CommandBus metadata + `outcome: :refused`, `code` (emitted on the pre-DO refusal path) | `AshA2A.CommandBus` |
| `[:ash_a2a, :command_bus, :lease_gate]` | `system_time` | common metadata + `outcome: :admitted`, `mask: 0` or `outcome: :refused`, `code`, `mask` (failed conjuncts); silent when no lease is presented | `AshA2A.CommandBus` (two-port lease gate) |
| `[:ash_a2a, :command_bus, :actuation_commit]` | `system_time` | common metadata + `outcome: :failed`, `reason` (inspected), `receipt_id`; emitted only when `commit_actuation/3` fails after retries | `AshA2A.CommandBus` |
| `[:ash_a2a, :command_bus, :postcondition]` | — | outcome, reason, `postcondition_id`, verifier, `independent` | `AshA2A.Postcondition` |
| `[:ash_a2a, :receipt, :outboxed]` | — | receipt (journaled `:pending` pre-dispatch) | `AshA2A.CommandBus` |
| `[:ash_a2a, :receipt, :committed]` | — | receipt (final, post-dispatch) | `AshA2A.CommandBus` |
| `[:ash_a2a, :receipt, :binding, :bind / :verify]` | — | receipt-binding outcome (RFC-SA2A-002 §40 Gate 9) | `AshA2A.Receipt.Binding` |
| `[:ash_a2a, :replay, :chain_sealed]` | — | evidence-chain seal outcome | `AshA2A.Receipt.EvidenceChain` |
| `[:ash_a2a, :replay, :verified]` | — | offline replay verdict | `AshA2A.Receipt.OfflineReplay` |
| `[:ash_a2a, :receipt_outbox, :reconciler, :tick]` | `committed`, `remaining` | — (drain summary; opt-in reconciler) | `AshA2A.ReceiptOutbox.Reconciler` |
| `[:ash_a2a, :receipt_outbox, :reconciler, :corrupt]` | `count` | `filenames`, `reasons` — undecodable journal files, once per tick | `AshA2A.ReceiptOutbox.Reconciler` |
| `[:ash_a2a, :receipt_outbox, :reconciler, :stuck]` | `attempts` | `command_id`, `receipt_id`, `threshold` — one event per stuck journal entry past the threshold (opt-in reconciler) | `AshA2A.ReceiptOutbox.Reconciler` |
| `[:ash_a2a, :reconciliation, :classified / :reconciled / :compensated]` | `system_time` | `command_id`, `receipt_id`, receipt status, `resolved_as`, label | `AshA2A.Reconciliation` |

### Authority

| Event | Measurements | Metadata | Emitted by |
| --- | --- | --- | --- |
| `[:ash_a2a, :authority, :decision]` | `system_time` | `outcome: :granted \| :refused`, `reason`/`code` (refusal code; `nil` when granted), capability, policy | `AshA2A.Authority.Grant` — the one decision event (RFC-SA2A-002 §12/§18) |
| `[:ash_a2a, :authority, :grant, :issue / :revoke / :renew]` | `system_time` | lifecycle outcome + reason | `AshA2A.Authority.Grant` |
| `[:ash_a2a, :authority, :decision_envelope, :verdict]` | — | envelope verdict (`:outcome`, `:code`) | `AshA2A.Authority.Decision` |
| `[:ash_a2a, :authority, :broker, :lookup]` | — | broker grant-lookup outcome | `AshA2A.Authority.Broker` |

### Planning, semantic, evidence

| Event | Measurements | Metadata | Emitted by |
| --- | --- | --- | --- |
| `[:ash_a2a, :planning, :admit]` | `capability_count` | outcome/code, planner, formalism, fingerprint, standing, authority | `AshA2A.Planning` |
| `[:ash_a2a, :planning, :preflight]` | — | preflight verdict over a `BoundedPlan` | `AshA2A.Planning.Preflight` |
| `[:ash_a2a, :router, :tier_selected]` | — | router tier | `AshA2A.Planning.RequestRouter` |
| `[:ash_a2a, :router, :tier_refused]` | — | router tier refusal | `AshA2A.Planning.RequestRouter` |
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

### Semantic pipeline (opt-in surfaces)

All events below carry `outcome` in metadata (family-specific verdict, e.g.
`:digested`/`:refused`, `:built`/`:refused`, `:admitted`/`:refused`) and empty
measurements unless noted. They fire only on the opt-in semantic paths.

| Event | Emitted by |
| --- | --- |
| `[:ash_a2a, :semantic, :canonical_graph, :digest / :pin / :compare]` | `AshA2A.Semantic.CanonicalGraph` (RDFC-1.0 canonicalization, pin verification, graph comparison) |
| `[:ash_a2a, :semantic, :iri, :mint_private / :resolve]` | `AshA2A.Semantic.Iri` |
| `[:ash_a2a, :semantic, :ontology, :project]` / `[:ash_a2a, :semantic, :ontology_cache, :load]` | `AshA2A.Semantic.Ontology`, `AshA2A.Semantic.OntologyCache` |
| `[:ash_a2a, :semantic, :mapping, :register]` / `[:ash_a2a, :semantic, :mapping_registry, :register / :reconcile]` | `AshA2A.Semantic.MappingRegistry` (`ash_r2rml` mapping admission and reconciliation; the unprefixed `:mapping` spelling is the legacy call site) |
| `[:ash_a2a, :semantic, :term_registry, :build / :operational_use]`, `[:ash_a2a, :semantic, :term, :operational_use]` | `AshA2A.Semantic.TermRegistry` (the `:term` spelling is the second call site of the same registry) |
| `[:ash_a2a, :semantic, :plan_package, :build / :verify]`, `[:ash_a2a, :semantic, :plan_projection, :verify]` | `AshA2A.Semantic.PlanPackage`, `AshA2A.Semantic.PlanProjection` |
| `[:ash_a2a, :semantic, :root_manifest, :load / :verify / :mutate]` | `AshA2A.Semantic.RootManifest` |
| `[:ash_a2a, :semantic, :sparql_update, :decision]` | `AshA2A.Semantic.FalsifierSuite` (SPARQL-update admission decision) |
| `[:ash_a2a, :semantic, :unknown, :admit_for_do]`, `[:ash_a2a, :semantic, :allocation]` | `AshA2A.Semantic.Unknown` (`count: 1` measurement; `class` metadata) |
| `[:ash_a2a, :semantic, :falsifier_suite, :admit]` | `AshA2A.Semantic.FalsifierSuite` |
| `[:ash_a2a, :semantic, :ir_admission]` | `AshA2A.Semantic.Admission` (IR admission verdict) |
| `[:ash_a2a, :semantic, :hooks, :run]` | `AshA2A.Semantic.GraphLawBridge` (GraphLaw hook execution) |
| `[:ash_a2a, :semantic, :llm_boundary, :candidate]` | `AshA2A.Semantic.LlmBoundary` |
| `[:ash_a2a, :semantic, :select]` / `[:ash_a2a, :semantic, :construct]` | `AshA2A.Semantic.Select`, `AshA2A.Semantic.Construct` (SELECT vs CONSTRUCT pipeline stages) |
| `[:ash_a2a, :semantic, :bounds, :delegate]` | `AshA2A.Semantic.Bounds` |
| `[:ash_a2a, :semantic, :allocator, :decision]` | `AshA2A.Semantic.Allocator` |
| `[:ash_a2a, :semantic, :meta_admission, :confer / :standing]` | `AshA2A.Semantic.MetaAdmission` |
| `[:ash_a2a, :semantic, :standing, :transition]` | `AshA2A.Semantic.Standing` (HMAC-sealed ledger transition) |
| `[:ash_a2a, :semantic, :extension, :negotiate]` | `AshA2A.Semantic.Extension` |
| `[:ash_a2a, :semantic, :peer \| suffix]` | `AshA2A.Semantic.Peer` (`:receive`, `:admission, :start`, `:decision`) |
| `[:ash_a2a, :replan \| suffix]` | `AshA2A.Replan.Telemetry` defines the prefix, but nothing in `lib/` calls `emit/3`: no replan event is emitted today (UNVERIFIED by execution; grep only) |
| `[:ash_a2a, :attestation, :build / :verify]` | `AshA2A.Semantic.Attestation` |
| `[:ash_a2a, :episode \| suffix]` | `AshA2A.Semantic.Episode` — suffixed sub-events over one semantic episode |
| `[:ash_a2a, :logic, :closure, event]` | `AshA2A.Semantic.LogicClosure` — per-closure-stage events (`:start`, `:entailment`, `:engine`, `:decision`, `:stop`) |

### Enterprise, evidence, authzen, SIEM, reactor

| Event | Measurements | Metadata | Emitted by |
| --- | --- | --- | --- |
| `[:ash_a2a, :enterprise, :pipeline, :completed]` | `duration_ns` | `stages` (traced stages plus `:dispatch, :dlp_outbound, :cmek, :affidavit, :ocel`), `dlp_findings` (unique finding types), `cmek`, `affidavit` | `AshA2A.Enterprise.Pipeline` |
| `[:ash_a2a, :enterprise, :pipeline, :refused]` | `duration_ns` | `stage`, `code` | `AshA2A.Enterprise.Pipeline` |
| `[:ash_a2a, :security, :dlp]` | `duration_ns`, `findings` (count) | `types` (per-type counts); emitted when the filter runs over a term | `AshA2A.Security.DLPFilter` |
| `[:ash_a2a, :evidence, :promote]` | `system_time` | `from`, `to`, `prior_chain_digest`, `offered_evidence_digest`, `outcome` (`:promoted`/`:refused`), `code`, `chain_digest` | `AshA2A.Evidence.Class.promote/3` |
| `[:ash_a2a, :evidence, :assert]` | `system_time` | `from`, `to`, `prior_chain_digest`, `offered_evidence_digest` (`nil`), `outcome` (`:admitted`/`:refused`), `code`, `chain_digest` | `AshA2A.Evidence.Class.assert_at_least/2` |
| `[:ash_a2a, :authzen, :monotonic, :refused]` | `system_time` | `code`, `digest`, `depth`, `parent_effective`, `requested`, `excess` | `AshA2A.AuthZEN.Monotonic` (delegation widening refusal) |
| `[:ash_a2a, :siem, :delivered]` | `events`, `duration` (native) | `platform`, `endpoint` (redacted) | `AshA2A.Telemetry.SIEM` |
| `[:ash_a2a, :siem, :failed]` | `events` (0), `duration` (native) | `platform`, `endpoint` (redacted), `reason` | `AshA2A.Telemetry.SIEM` |
| `[:ash_a2a, :reactor, :compensate]` | `count: 1` | `command_id`, `reason`, `options`; emitted when the command map is present | `AshA2A.Reactor.ExecuteCommand.compensate/4` |
| `[:ash_a2a, :gall, :closure, <stage>]` | `count: 1` | `outcome`, `candidate_digest`, `command_id`, `receipt_id`, `authority: :none` | Event map built by `AshA2A.Gall.Closure.TelemetryEnvelope.event/4`; that module only constructs the map and does not call `:telemetry.execute/3` (no executing caller found in `lib/`) |

### Cluster lifecycle & FinOps

| Event | Measurements | Metadata | Emitted by |
| --- | --- | --- | --- |
| `[:ash_a2a, :cluster, :drain, :init / :cordon / :complete]` | `count` | `drain_manager` (registered name), `drain_timeout_ms`; `:init` adds `signal_handler` (whether the OS signal handler installed); `:cordon` adds `reason` and `tracked` (tracked tasks open at cordon); `:complete` adds `checkpointed` (drained task ids) and `cordon_to_exit_ms` | `AshA2A.Cluster.DrainManager` (drain lifecycle: supervisor init, cordon, two-phase drain completion) |
| `[:ash_a2a, :cluster, :handover]` / `[:ash_a2a, :cluster, :handover, :completed]` | `count` | `task_id`, `source_node`, `reason` (default `:drain`), `checkpointed_at`; the `:completed` suffix narrows to `task_id` + `node` | `AshA2A.Cluster.Handover` (checkpoint handoff broadcast, then the resumed task's completion) |
| `[:ash_a2a, :finops, :chargeback]` | `tokens`, `system_time` | `cost_center`, `budget_account_id`, `ceiling`, `window_started_at`, `window_ms`, `consumed`, `admitted` (boolean), `code` (admission code; `nil` when fully attributed) | `AshA2A.FinOps.BudgetEnforcer` (per-request chargeback tag; emitted on every admission decision, admitted or refused) |

### Runtime, transport & security

| Event | Emitted by |
| --- | --- |
| `[:ash_a2a, :runtime, :configured]` | `AshA2A.Application` (boot-time runtime posture report) |
| `[:ash_a2a, :a2a_transport, :push, :attempt]` | `AshA2A.A2ATransport.PushDelivery` (one signed webhook delivery attempt) |
| `[:ash_a2a, :security_profile, :dev_bypass]` | `AshA2A.SecurityProfile.Template` (a `:dev_bypass` build stamped its receipts) |
| `[:ash_a2a, :security_profile, :legacy_compat]` | `AshA2A.SecurityProfile.Boot` |
| `[:ash_a2a, :transport, :plug, :list_refused]` | `AshA2A.A2ATransport.Plug` (task-list wire refusal; metadata: `subject`, `refusal` (committed `AshA2A.Semantic.Refusal`), `wire_code`; no measurements) |
| `[:ash_a2a, :protocol, :plug, :authorize_refused]` | `AshA2A.Protocol.Plug` authorize court (metadata: `operation`, `task_id`, `refusal` (committed `AshA2A.Semantic.Refusal`), `wire_code`; no measurements) |

### GraphLaw engine

| Event | Emitted by |
| --- | --- |
| `[:ash_a2a, :graphlaw, :engine, :call]` | `AshA2A.GraphLaw.EngineTelemetry` |
| `[:ash_a2a, :graphlaw, :engine, :load, :start / :stop]` | `AshA2A.GraphLaw.EngineLoad` |
| `[:ash_a2a, :graphlaw, :host, :recycle]` | `AshA2A.GraphLaw.WasmexHost` (warm-instance recycle) |
| `[:ash_a2a, :graph_law, :wasm, :batch]` | `AshA2A.Semantic.GraphLaw.Wasm` — note the historical `:graph_law` spelling, distinct from the `:graphlaw` engine family above |

> The `AshA2A.Transport.Runtime` wrapper emits the span
> `[:a2a, :agent, :start / :stop / :exception]` (prefix `:a2a`, not
> `:ash_a2a`) around agent message handling; the prefix is historical and
> now originates from the in-repo `AshA2A.Protocol.Telemetry` module, not
> this catalog's `[:ash_a2a, ...]` families.

### Chicago / QA harness events (internal)

A large `[:ash_a2a, :chicago, ...]` family (mutation, observer, court
manifest, collaborator scans, OCEL validation) is emitted by the
conformance-court **test harness**, not the dispatch path — see
`lib/ash_a2a/chicago/`. Do not build production dashboards on these.

### v1.1 live and generation surface

There are no dedicated `live` or `generation` event families. A grep of
`:telemetry.execute`/`:telemetry.span` in `lib/` finds no emit call in
`AshA2A.Transport.Live`, `AshA2A.Transport.Live.Session`, or
`AshA2A.Protocol.Task.Generation`. The events below are the ones that exist
on the v1.1 live/generation path:

| Event | Measurements | Metadata | Emitted by |
| --- | --- | --- | --- |
| `[:a2a, :task, :transition]` | `system_time` | `task_id`, `context_id`, `from`, `to` | `AshA2A.Protocol.Agent.State` (each transition advances the task generation) |
| `[:a2a, :task, :transition_refused]` | `system_time` | `task_id`, `from`, `to`, `reason` | `AshA2A.Protocol.Agent.State` |
| `[:a2a, :bidi, :input]` | `count: 1` | `task_id` | `AshA2A.Bidi` (an uplink message accepted into a running task; emitted only on `{:ok, :accepted}`) |
| `[:ash_a2a, :transport, :request, :start / :stop / :exception]`, `[:ash_a2a, :transport, :request, :error]` | span `duration`; `count: 1` on error | request metadata | `AshA2A.Protocol.Telemetry` (also wraps gRPC RPCs, `AshA2A.Transport.GRPC.Server`) |
| `[:a2a, :push_notification, :delivery]` | `duration` | `task_id`, `context_id`, `config_id`, `url`, `result` | `AshA2A.Protocol.PushNotification` |

### Failure-visibility, orphan and drain events

| Event | Measurements | Metadata | Emitted by |
| --- | --- | --- | --- |
| `[:ash_a2a, :command_bus, :swallowed_failure]` | `count` | `site`, `kind` | `AshA2A.CommandBus` (a best-effort step failed; also logged) |
| `[:ash_a2a, :receipt_outbox, :sync_dir_failed]` | `count` | `dir`, `reason` | `AshA2A.ReceiptOutbox` (directory fsync failed) |
| `[:ash_a2a, :receipt_outbox, :decode_failed]` | `count` | `cause` | `AshA2A.ReceiptOutbox` (journal entry undecodable; return stays `:bad_term`) |
| `[:a2a, :task, :late_event_dropped]` | `count` | `task_id`, `terminal_state`, `event` | `AshA2A.Protocol.Agent` (event after a terminal state; task untouched) |
| `[:a2a, :task, :transition]` | `system_time` | `task_id`, `context_id`, `from`, `to` | `AshA2A.Protocol.Agent.State` (a task state change; the status entry is appended through `AshA2A.Protocol.Task.Generation.append_status/2`, so each transition is a v1.1 generation step) |
| `[:a2a, :task, :transition_refused]` | `system_time` | `task_id`, `from`, `to`, `reason` | `AshA2A.Protocol.Agent.State` (illegal transition; task untouched) |
| `[:a2a, :push_config, :volatile]` | `count` | `task_id`, `config_id` | `AshA2A.Protocol.Agent.State` (push config stored in memory only) |
| `[:ash_a2a, :task, :orphan_failed]` | `count` | `task_id` | `AshA2A.Protocol.Task.OrphanSweep` |
| `[:ash_a2a, :task, :orphan_sweep_unsupported]` | `count` | sweep metadata | `AshA2A.Protocol.Task.OrphanSweep` (store cannot sweep) |
| `[:ash_a2a, :copilot, :stage_skipped]` | `count` | stage, reason | `AshA2A.Copilot.Pipeline` (observable stage skip) |
| `[:ash_a2a, :ocel, :ignored]` | `count` | — | `AshA2A.Telemetry.OcelForwarder` (event ignored) |
| `[:ash_a2a, :transport, :request, :start]` | `system_time` | transport metadata | `AshA2A.Protocol.Telemetry` (request span start) |
| `[:ash_a2a, :transport, :request, :stop]` | `duration` | transport metadata | `AshA2A.Protocol.Telemetry` (request span stop) |
| `[:ash_a2a, :transport, :request, :exception]` | `duration` | transport metadata, `kind`, `reason` | `AshA2A.Protocol.Telemetry` (request span exception) |
| `[:ash_a2a, :transport, :request, :error]` | `count` | transport metadata | `AshA2A.Protocol.Telemetry` (discrete error event) |
| `[:ash_a2a, :cluster, :drain, :task_skipped]` | `count` | `drain_manager`, `task_id`, `reason` (`:no_task_store`, `:checkpoint_failed`, `:not_checkpointed`) | `AshA2A.Cluster.DrainManager` |
| `[:ash_a2a, :task_events, :journal_error]` | `count` | `task_id`, `seq` | `AshA2A.A2ATransport.TaskEvents` |
| `[:ash_a2a, :cluster, :checkpoint, :terminal_skipped]` | `count` | `task_id`, `state` | `AshA2A.Cluster.Checkpoint` (terminal task not checkpointed) |
| `[:ash_a2a, :ocel_broadcaster, :unconvertible]` | `count` | `broadcaster`, `kind` | `AshA2A.Telemetry.OcelBroadcaster` |
| `[:ash_a2a, :ocel, :unconvertible]` | `count` | none | `AshA2A.Telemetry.OcelForwarder` |

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
logged and swallowed, never raised into dispatch. Delivery outcomes are
observable as `[:ash_a2a, :ocel, :delivered]` and
`[:ash_a2a, :ocel, :failed]` (alongside the `:shed` counter above). See
[Observe dispatch with OCEL](../how-to/observe-dispatch-with-ocel.md).

## OCEL broadcaster (SIEM egress)

`AshA2A.Telemetry.OcelBroadcaster` buffers forwarded OCEL v2 events and
flushes them to SIEM sinks on an interval (bounded, drop-oldest; a failed
sink flush re-buffers the events at the front of the queue). Two events
observe its health:

| Event | Measurements | Metadata | Emitted by |
| --- | --- | --- | --- |
| `[:ash_a2a, :ocel_broadcaster, :dropped]` | `count` | `broadcaster` (registered name), `dropped_total` (cumulative drops) | `AshA2A.Telemetry.OcelBroadcaster` (drop-oldest bound enforcement) |
| `[:ash_a2a, :ocel_broadcaster, :flush_failed]` | `count` | `broadcaster`, `reason` (the typed SIEM delivery failure) | `AshA2A.Telemetry.OcelBroadcaster` (a sink flush failed; events re-buffered, never lost silently) |

## SLO metric definitions

`AshA2A.Telemetry.Metrics` ships plain-data metric definitions
(`definitions/0`: `%{type, name, event, measurement, tags, unit}`) and the
same as `Telemetry.Metrics` structs (`metrics/0`) for
`TelemetryMetricsPrometheus`, OpenTelemetry, or LiveDashboard — so a host
can build SLO dashboards without hand-pairing start/stop events. The host
must depend on `:telemetry_metrics` itself (`metrics/0` raises a clear
error without it); durations are `:native` and pre-tagged for
`unit: {:native, :millisecond}` conversion.

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
