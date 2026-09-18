# Configuration Reference

Everything `ash_a2a` reads from application environment
(`Application.get_env(:ash_a2a, ...)`) and from the OS environment, with
defaults and where each key is consumed. All keys are optional; the
fail-closed defaults are deliberate.

## Application config — core dispatch & receipts

| Key | Default | Consumed by / meaning |
| --- | --- | --- |
| `:agents` | `[]` | `AshA2A.Application` — agent modules booted under its `A2A.AgentSupervisor`. |
| `:receipt_store` | `AshA2A.ReceiptStore.Memory` | `AshA2A.Application` / `AshA2A.CommandBus` — replay-safe receipt storage. `Ekv` gets automatic EKV child wiring. A custom module must be supervised by the host (the app starts no children for it). |
| `:receipt_store_ekv_opts` | `[]` | EKV options for `AshA2A.ReceiptStore.Ekv`. Defaults inject `name: AshA2A.ReceiptStore.Ekv`, `cluster_size: 1`, and `data_dir: System.tmp_dir!()/ash_a2a_receipt_store_ekv`. **The tmp-dir default is not guaranteed to survive a host reboot** — set a real persistent `:data_dir` for production. |
| `:receipt_commit_retry_delays_ms` | `[50, 150]` | `CommandBus` receipt-commit retry backoff. |
| `:actuation_dedup` | `:declared` | `CommandBus` actuation de-duplication mode. |
| `:claim_lease_ms` | `300_000` | Receipt-store claim lease TTL (the crash-recovery window a claimed-but-unfinished command is guarded by). |
| `:receipt_binding_key` | — | Key binding a receipt to its evidence (`AshA2A.Receipt.Binding`). |
| `:receipt_outbox_dir` | — | `AshA2A.ReceiptOutbox` filesystem journal directory (pending receipts written before dispatch). |
| `:outbox_reconciler_interval_ms`, `:outbox_stuck_attempts_threshold` | — | Outbox reconciler polling and stuck-detection thresholds. |
| `:durable_server_provider` | — | `AshA2A.Durability.DurableServer` provider seam. |

## Application config — authority

| Key | Default | Consumed by / meaning |
| --- | --- | --- |
| `:authority_policy` | `:broker` | `AshA2A.Authority.Grant`. `:broker` is the fail-closed default (grants required). `:transport_verified_grants_capability` is the legacy escalation mode — **violates RFC-SA2A-001 S29**; migration window only. |
| `:authority_broker` | — (none) | Broker module implementing `AshA2A.Authority.Broker`. Shipped: `Broker.InMemory` (GenServer, single node, dev/tests) and `Broker.Ekv` (durable). Unset + `:broker` policy = every consequential dispatch refused `:authority_required` with a warning naming the missing config. |

## Application config — LLM roles, telemetry, planning

| Key | Default | Consumed by / meaning |
| --- | --- | --- |
| `:llm_profiles` | `[]` | `AshA2A.LLMProfiles` — role (e.g. `:semantic_reasoner`) to `provider/model` + options. Misconfigured roles raise at use. |
| `:ocel_ingest_url` | `nil` (silent no-op) | `AshA2A.Telemetry.OcelForwarder` — POSTs OCEL v2 events to `"<url>/ocel/events"`. |
| `:ocel_ingest_timeout_ms` | `2_000` | Forwarder HTTP timeout. |
| `:ocel_max_in_flight` | `256` | Hard ceiling of concurrent forwarded POSTs (`Task.Supervisor max_children`); excess events are shed and counted. |
| `:ocel_task_supervisor` | — | Override the forwarder's supervisor name. |
| `:hddl_cli_path` | source-relative | `AshA2A.Planning.HddlSolver` — path to the built `native/hddl_cli` binary. **The computed default only resolves inside a source checkout of this repo, never inside an installed Hex dependency** — production users of the planning path must build the binary and set this key. |

## Application config — semantic engine / GraphLaw (opt-in surfaces)

| Key | Default | Notes |
| --- | --- | --- |
| `:evidence_class` | `AshA2A.Evidence.LocalTest` | Evidence classification module. |
| `:graph_law` | `AshA2A.Semantic.GraphLaw.Wasm` | Semantic-pipeline law engine. |
| `:planning_bounds` | `[]` | Planning bound guards (`AshA2A.Semantic.Conformance`). |
| `:graphlaw_wasm_path` | — | WASM artifact path — read by **seven** modules (`GraphLaw.Wasm`, `Runtime`, `WasmDriver`, `WasmtimeRuntime`, `WasmexHost`, `Semantic.GraphLawBridge`, `RootManifest.EngineProbe`); prefer this app-env key over env vars. |
| `:graphlaw_host_path`, `:graphlaw_probe_host_path`, `:graphlaw_node_path`, `:node_executable`, `:graphlaw_host_script`, `:graphlaw_runtime_b_executable`, `:graphlaw_conformance_vectors_path` | — | Runtime-B host/node/executable overrides; see the respective modules under `lib/ash_a2a/graph_law/`. |
| `:sa2a_corpus_dir`, `:sa2a_graphlaw_wasm`, `:chicago_topology_root`, `:admitted_vocabulary`, `:root_manifest`, `:semantic_engine` | — | Conformance/harness knobs (corpus location, manifest roots). |

Per-module form is also supported where noted, e.g.
`config :ash_a2a, AshA2A.Semantic.GraphLaw.Wasm, [...]`.

## Environment variables

| Variable | Read by | Purpose |
| --- | --- | --- |
| `GRAPHLAW_WASM_PATH` | `GraphLaw.WasmDriver` | WASM path (after `:graphlaw_wasm_path`). |
| `PRAXIS_GRAPHLAW_WASM` | `GraphLaw.Runtime` | WASM path (runtime A). |
| `GRAPHLAW_WASM` | `Semantic.GraphLaw.Wasm`, `RootManifest.EngineProbe` | WASM path fallback. |
| `ASH_A2A_GRAPHLAW_WASM` | `Semantic.GraphLawBridge` | WASM path (bridge). |
| `SA2A_GRAPHLAW_WASM` | `SA2A.GraphLaw` | WASM path (conformance court). |
| `GRAPHLAW_HOST_EXECUTABLE` | `GraphLaw.RuntimeB` | Host executable; else first `node`/`bun` on PATH. |
| `ASH_A2A_NODE` | `GraphLaw.WasmHost` | Node binary for the JS WASM host. |
| `ASH_A2A_B3SUM` | `GraphLaw.Manifest` | `b3sum` binary for BLAKE3 digests. |
| `PRAXIS_ROOT`, `WASM_PACK` | `GraphLaw.Vendor` | Vendoring toolchain only (`mix ash_a2a.vendor_graphlaw`). |
| `SWARM_K8S_SERVICE` | `swarm/config/runtime.exs` | Gates libcluster DNS topology in the swarm test app. |

> **Precedence warning**: there are *five* different WASM-path env vars
> above, each read by a different runtime. In production pick the app-env
> key `:graphlaw_wasm_path` (or the per-module form) over env vars, and set
> exactly one source — the fallback chains are per-module, not global.

## Swarm release variables (test harness, not the library)

`RELEASE_DISTRIBUTION`, `RELEASE_NODE`, `RELEASE_COOKIE`, `RELEASE_TMP`,
and `POD_IP` are consumed by the `swarm/` release image's boot scripts and
`k8s/deployment.yaml` — they configure BEAM distribution for the Kubernetes
swarm test, not `ash_a2a` itself.
