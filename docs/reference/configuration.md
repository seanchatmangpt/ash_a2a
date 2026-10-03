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
| `:receipt_store_call_timeout_ms` | `5_000` | `AshA2A.ReceiptStore.Memory` GenServer call timeout. |
| `:receipt_store_memory_max_entries` | — (unbounded) | `AshA2A.ReceiptStore.Memory` entry bound. |
| `:receipt_ttl_ms` | — (no TTL) | `AshA2A.ReceiptStore.Memory` receipt TTL. |
| `:actuation_dedup` | `:strict` | `CommandBus.actuation_dedup_mode/1` (per-call opt `:actuation_dedup` wins). `:strict` (default) enforces the effect claim on the derived effect digest for every `:change`/`:external_do` command, with or without an idempotency token. `:declared` (legacy opt-in) enforces only for commands carrying an explicit token; receipts record `intended_effect.actuation_dedup_compat == :declared_legacy`. `:off` (legacy opt-in) never claims an actuation (`:off_legacy`). See [migrate-legacy-to-strict](../how-to/migrate-legacy-to-strict.md). |
| `:claim_lease_ms` | `300_000` | Receipt-store claim lease TTL (the crash-recovery window a claimed-but-unfinished command is guarded by). |
| `:receipt_binding_key` | — (unset: keyed binding refuses `:receipt_binding_key_unavailable`) | Key binding a receipt to its evidence (`AshA2A.Receipt.Binding`). Production: a secret of at least 32 random bytes, identical on every node. |
| `:receipt_outbox_dir` | `System.tmp_dir!()/ash_a2a_receipt_outbox` | `AshA2A.ReceiptOutbox` filesystem journal directory (pending receipts written before dispatch). **The tmp-dir default does not survive a pod reschedule or host reboot** — the crash-recovery guarantee the outbox exists for is lost with it. Set a persistent directory in production. |
| `:receipt_outbox_key` | — (unset: journal records are unsigned) | HMAC key sealing the ConsequenceKernel `PreparedEffectStore.Journal` and `EffectClaimStore.DurableFile` records; identical on every node sharing the directory. |
| `:prepared_journal_dir` | falls back to `:receipt_outbox_dir` | `AshA2A.ConsequenceKernel.PreparedEffectStore.Journal` directory. |
| `:claim_store`, `:claim_store_dir`, `:claim_store_key` | — | Durable effect-claim store consumed by the ConsequenceKernel (`EffectClaimStore.DurableFile`): module, directory, and HMAC key. |
| `:outbox_reconciler` | `true` | `AshA2A.Application` starts `AshA2A.ReceiptOutbox.Reconciler` unless `false` (set only if the host supervises its own instance). |
| `:outbox_reconciler_interval_ms`, `:outbox_stuck_attempts_threshold` | `60_000`, `5` | Outbox reconciler polling interval and stuck-detection threshold. |
| `:outbox_ready_max` | `1_000` | `AshA2A.Health` — outbox ready-count above which readiness reports degraded. |
| `:require_durable_receipts` | `false` | `AshA2A.Application` boot-time durability enforcement. |
| `:standing_ledger_key` | — (unset: 32 random bytes per runtime) | `AshA2A.Semantic.Standing` seal key. Must be exactly 32 raw bytes; any other configured value raises `ArgumentError` at boot and on every transition. **Unset, the key is generated per node at boot and held in `:persistent_term`: a standing chain sealed on one node is refused (`:standing_ledger_unsealed`) on every other node and after any restart or rolling update.** Set the same key on every node of a cluster. |
| `:env` | `:prod` | `AshA2A.Application` boot-time durability warning: when `:prod` and receipts are non-durable (memory store, tmp data dirs), a warning is logged. Hosts set it to their Mix env. |
| `:outbox_reconciler_interval_ms`, `:outbox_stuck_attempts_threshold` | — | Outbox reconciler polling and stuck-detection thresholds. |
| `:durable_server_provider` | `DurableServer.Supervisor` | `AshA2A.Durability.DurableServer` provider seam. |

## Application config — authority

| Key | Default | Consumed by / meaning |
| --- | --- | --- |
| `:authority_policy` | `:broker` | `AshA2A.Authority.Grant`. `:broker` is the fail-closed default (grants required). `:transport_verified_grants_capability` is the legacy escalation mode — **violates RFC-SA2A-001 S29**; migration window only. |
| `:allow_legacy_authority_policy` | — (unset: legacy policy refused) | Must be exactly `:i_accept_privilege_escalation` for the legacy `:transport_verified_grants_capability` policy to be honored at all. |
| `:strict_security` | — | `AshA2A.Authority.SecurityPreflight` strict posture input. |
| `:authority_broker` | — (none) | Broker module implementing `AshA2A.Authority.Broker`. Shipped: `Broker.InMemory` (GenServer, single node, dev/tests) and `Broker.Ekv` (durable — gets automatic EKV child wiring from `AshA2A.Application`, with its own distinct `:name`/`:data_dir`, separate from the receipt store's EKV; config-only, no hand-started child needed since 2026-09-17). Unset + `:broker` policy = every consequential dispatch refused `:authority_required` with a warning naming the missing config. **`Broker.Ekv`'s `:data_dir` defaults to `System.tmp_dir!()/ash_a2a_authority_broker_ekv`, which does not survive a pod reschedule or reboot** — grants and revocations would be lost; pass `{AshA2A.Authority.Broker.Ekv, data_dir: "/persistent/path", cluster_size: n}`. |

## Application config — capability release

| Key | Default | Consumed by / meaning |
| --- | --- | --- |
| `:capability_release_closure` | `nil` | `AshA2A.CapabilityRelease` / `AshA2A.CommandBus` / `AshA2A.Dispatcher` — the frozen released closure (`freeze/2` builds a `%Closure{digest, portable_digest, capabilities}` from released capabilities only, and since 1ad83d9 additionally replays and re-admits each member's durable standing evidence (`AshA2A.StandingBinding.verify_durable/2`) at the closure boundary, refusing `:standing_release_digest_mismatch` when the release digest differs from the binding's portable identity). In strict mode, execution requires exact skill-id membership in this closure; passing a closure in `CommandBus` opts implies `:strict` for that call unless a mode is explicitly supplied. The gate reads the closure from call opts first, then the global env — so with a global `:capability_release_mode` of `:strict` and no global closure, the compiled skill-index expansion itself (`AshA2A.Info`, which filters the index through `AshA2A.CapabilityRelease.filter_skills/2`) refuses `:capability_release_closure_missing` before any dispatch: the closure is a boot prerequisite of a strict build, not only a dispatch-time input. |
| `:capability_release_mode` | `:legacy` | `AshA2A.CapabilityRelease.guard/2` release-gate mode. `:legacy` preserves pre-v26.9.26 behavior (gate inert). `:strict` requires a frozen closure and exact skill-id membership: strict + absent closure refuses `:capability_release_closure_missing` (S42 `:refused_provenance`); a capability outside the closure refuses `:capability_release_refused` (S42 `:refused_capability`). Any other value refuses `{:invalid_capability_release_mode, mode}`. |

## Application config — other security-relevant defaults

| Key | Default | Consumed by / meaning |
| --- | --- | --- |
| `:security_profile` | `:strict` (compile-time) | `AshA2A.SecurityProfile` / `AshA2A.SecurityProfile.Boot` (RFC-SA2A-007). Read with `Application.compile_env`, so it is fixed at compile time: `config/config.exs` selects `:dev_bypass` in the `:test`/`:dev` envs and `:strict` in `:prod`/`:conformance`; requesting `:dev_bypass` in a `:prod` build is a `CompileError`. `:legacy_compat` remains host-facing machinery but is deprecable: zero in-repo consumers boot under it and no documented host path recommends it (`docs/jira/v26.10.2/LEGACY-COMPAT-AUDIT.md` states the retirement criterion). |
| `:production` | `false` | `AshA2A.SecurityProfile.Boot` production-posture input. |
| `:strict_observe_generic_actions` | `false` | `AshA2A.Agent`. When `true` (or per-agent opt `strict_observe_generic_actions: true`), a generic `:action` skill with no explicit `consequence:` is refused `:consequence_unclassified` unless listed in `observe_generic_actions`. Default `false` keeps the legacy behavior. Opt-in until fixtures declare their generic actions. |
| `:require_authenticated_caller` | `true` | `AshA2A.Agent` / `AshA2A.Transport.Plug`. Fail closed: unauthenticated callers are refused. |
| `:expose_error_detail` | `false` | `AshA2A.Transport.SafeError` — include exception detail in transport error payloads. Keep off in production. |
| `:kill_switch_class` | `nil` | `CommandBus` kill-switch class consulted at admission and again immediately before DO. Unset = no kill-switch gate. `:kill_switch_path` (default `nil`) gives `AshA2A.KillSwitch` a durable dets path so trip state survives a restart. |
| `:health_kill_switch_classes`, `:health_ocel_failed_max` | `[]`, — | `AshA2A.Health` readiness components: classes whose trip degrades readiness, and the OCEL forwarder failure ceiling. |
| `:dispatch_timeout_ms` | `30_000` | `CommandBus` dispatch timeout. |

## Application config — LLM roles, telemetry, planning

| Key | Default | Consumed by / meaning |
| --- | --- | --- |
| `:llm_profiles` | `[]` | `AshA2A.LLMProfiles` — role (e.g. `:semantic_reasoner`) to `provider/model` + options. Misconfigured roles raise at use. |
| `:principal_claims` | — | `AshA2A.Transport.Principal` — claim-extraction mapping from the verified transport identity. |
| `:execution` | `[]` | `AshA2A.Transport.Runtime` — execution adapter wiring. |
| `:ocel_ingest_url` | `nil` (silent no-op) | `AshA2A.Telemetry.OcelForwarder` — POSTs OCEL v2 events to `"<url>/ocel/events"`. |
| `:ocel_ingest_timeout_ms` | `2_000` | Forwarder HTTP timeout. |
| `:ocel_max_in_flight` | `256` | Hard ceiling of concurrent forwarded POSTs (`Task.Supervisor max_children`); excess events are shed and counted. |
| `:ocel_task_supervisor` | `AshA2A.Telemetry.TaskSupervisor` | Override the forwarder's supervisor name. |
| `:ocel_log_body` | `false` | Forwarder diagnostic logging of forwarded event bodies. |
| `:ocel_log_interval_ms` | `60_000` | Forwarder diagnostic log cadence. |
| `:ocel_egress_policy` | — (default: HTTPS + public addresses only; `:test` admits loopback HTTP) | `AshA2A.Egress.EndpointPolicy` SSRF admission options for forwarded URLs (CWE-918); e.g. `allow_http: true, allow_cidrs: [...]` for a trusted internal collector. |
| `:telemetry_raw_errors` | `false` | `AshA2A.Telemetry.Redact` — emit raw error payloads instead of redacted ones. |
| `:hddl_cli_path` | source-relative | `AshA2A.Planning.HddlSolver` — path to the built `native/hddl_cli` binary. **The computed default only resolves inside a source checkout of this repo, never inside an installed Hex dependency** — production users of the planning path must build the binary and set this key. |
| `:hddl_timeout_ms` | `30_000` | `AshA2A.Planning.HddlSolver` subprocess timeout. |
| `:hddl_max_output_bytes` | `8_000_000` | `AshA2A.Planning.HddlSolver` output cap. |

## Application config — semantic engine / GraphLaw (opt-in surfaces)

| Key | Default | Notes |
| --- | --- | --- |
| `:evidence_class` | `AshA2A.Evidence.LocalTest` | Evidence classification module. |
| `:graph_law` | `AshA2A.Semantic.GraphLaw.WasmexHost` while it serves the same wasm bytes the node runner resolves, else `AshA2A.Semantic.GraphLaw.Wasm` | Semantic-pipeline law engine (`AshA2A.Semantic.GraphLaw.impl/1`). Select explicitly with the per-module form below. |
| `:planning_bounds` | `[]` | Planning bound guards (`AshA2A.Semantic.Conformance`). |
| `:semantic_max_text_bytes`, `:semantic_max_batch` | `—`, `100` | `AshA2A.Semantic.Compiler` input bounds (`Compiler.max_text_bytes/1`, `Compiler.max_batch/1`). |
| `:semantic_engine`, `:admitted_vocabulary`, `:root_manifest` | `nil`, `nil`, `nil` | `AshA2A.Semantic.Conformance` engine/vocabulary/manifest overrides — `nil` = unset (no engine/vocabulary/manifest is compiled in). |
| `:semantic_package_store_max_entries`, `:semantic_package_store_ttl_ms` | — | `AshA2A.Semantic.PackageStore` fingerprint→package correlation bounds. |
| `:graphlaw_wasm_path` | vendored `priv/graphlaw/praxis_graphlaw.wasm` | WASM artifact path — read by **seven** modules (`AshA2A.GraphLaw.Wasm`, `.Runtime`, `.WasmDriver`, `.WasmtimeRuntime`, `.WasmexHost`, `AshA2A.Semantic.GraphLawBridge`, `AshA2A.Semantic.RootManifest.EngineProbe`); prefer this app-env key over env vars. |
| `:graphlaw_wasm_sha256` | — | Expected wasm digest, checked by `AshA2A.GraphLaw.EngineLoad`. |
| `:graphlaw_pool_size`, `:graphlaw_max_queue` | `—`, `64` | `AshA2A.GraphLaw.WasmexHost`/`WasmexPool` sizing (warm instances, queue ceiling). |
| `:graphlaw_subprocess_timeout_ms`, `:graphlaw_subprocess_max_concurrency` | `30_000`, — | `AshA2A.GraphLaw.Subprocess` bounds. |
| `:graphlaw_host_path`, `:graphlaw_probe_host_path`, `:graphlaw_node_path`, `:node_executable`, `:graphlaw_host_script`, `:graphlaw_runtime_b_executable`, `:graphlaw_conformance_vectors_path` | — (vectors default to the vendored `priv/graphlaw/conformance_vectors.json`) | Runtime-B host/node/executable overrides; see the respective modules under `lib/ash_a2a/graph_law/` (runtimes) and `lib/ash_a2a/graphlaw/` (vendoring, manifest, JS host). |
| `:sa2a_corpus_dir`, `:sa2a_graphlaw_wasm` | — | SA2A conformance corpus location and wasm override (`AshA2A.SA2A.Graphlaw`). |
| `:chicago_topology_root` | — (unset refuses `:chicago_topology_root_unset`; `config/test.exs` pins the checkout) | Root the Chicago topology court walks for its fixture tree (`AshA2A.Chicago` `sa2a_v26_9_17_topology` court); the court self-skips when the sibling repos are absent under it. |

Per-module form is also supported where noted, e.g.
`config :ash_a2a, AshA2A.Semantic.GraphLaw.Wasm, [...]`.

## Environment variables

| Variable | Read by | Purpose |
| --- | --- | --- |
| `GRAPHLAW_WASM_PATH` | `AshA2A.GraphLaw.WasmDriver` | WASM path (after `:graphlaw_wasm_path`). |
| `PRAXIS_GRAPHLAW_WASM` | `AshA2A.GraphLaw.Runtime` | WASM path (runtime A). |
| `GRAPHLAW_WASM` | `AshA2A.Semantic.GraphLaw.Wasm`, `AshA2A.Semantic.RootManifest.EngineProbe` | WASM path fallback. |
| `ASH_A2A_GRAPHLAW_WASM` | `AshA2A.Semantic.GraphLawBridge` | WASM path (bridge). |
| `SA2A_GRAPHLAW_WASM` | `AshA2A.SA2A.Graphlaw` | WASM path (conformance court). |
| `GRAPHLAW_HOST_EXECUTABLE` | `AshA2A.GraphLaw.RuntimeB` | Host executable; else first `node`/`bun` on PATH. |
| `ASH_A2A_NODE` | `AshA2A.GraphLaw.WasmHost` | Node binary for the JS WASM host. |
| `ASH_A2A_B3SUM` | `AshA2A.GraphLaw.Manifest` | `b3sum` binary for BLAKE3 digests. |
| `PRAXIS_ROOT`, `WASM_PACK` | `AshA2A.GraphLaw.Vendor` | Vendoring toolchain only (`mix ash_a2a.vendor_graphlaw`). |
| `SWARM_K8S_SERVICE` | `swarm/config/runtime.exs` | Gates the libcluster topology in the swarm host app. **Unset, the node runs unclustered** (no libcluster topology is configured, `Node.list/0` stays empty). |
| `SWARM_K8S_NAMESPACE` | `swarm/config/runtime.exs` | With `SWARM_K8S_SERVICE`, selects `Cluster.Strategy.Kubernetes.DNSSRV` (stable StatefulSet pod hostnames); without it, `Kubernetes.DNS` (pod IPs). |

> **Precedence warning**: there are *five* different WASM-path env vars
> above, each read by a different runtime. In production pick the app-env
> key `:graphlaw_wasm_path` (or the per-module form) over env vars, and set
> exactly one source — the fallback chains are per-module, not global.

## Swarm release variables (the `swarm/` host app, not the library)

Consumed by the `swarm/` release (`swarm/config/runtime.exs`,
`swarm/rel/env.sh.eex`) and set by `k8s/deployment.yaml`. In the `:prod`
release every `ASH_A2A_*` variable below is **required**: a missing or
malformed value raises while `config/runtime.exs` is evaluated, so the node
refuses to boot instead of falling back to the library's dev defaults.

| Variable | Purpose |
| --- | --- |
| `RELEASE_DISTRIBUTION`, `RELEASE_NODE`, `RELEASE_COOKIE`, `RELEASE_TMP`, `POD_NAME`, `POD_NAMESPACE` | BEAM distribution identity (`swarm_node@<pod>.ash-a2a-swarm-headless.<ns>.svc.cluster.local`). |
| `ASH_A2A_EKV_CLUSTER_SIZE` | EKV `cluster_size` for both the receipt store and the broker (= replica count). |
| `ASH_A2A_RECEIPT_DATA_DIR`, `ASH_A2A_BROKER_DATA_DIR`, `ASH_A2A_OUTBOX_DIR` | Absolute persistent directories (the StatefulSet PVC at `/var/lib/ash_a2a`). |
| `ASH_A2A_CAPABILITY_RELEASE_MANIFEST`, `ASH_A2A_CAPABILITY_RELEASE_DIGEST` | Frozen release closure (JSON manifest, `SwarmNode.ReleaseClosure`) and its pinned digest; mismatch refuses boot. |
| `ASH_A2A_RECEIPT_BINDING_KEY` | Base64, 32..1024 bytes -> `:receipt_binding_key`. |
| `ASH_A2A_STANDING_LEDGER_KEY` | Base64, exactly 32 bytes -> `:standing_ledger_key`. |
| `SWARM_DIST_TLS` | `true` (default): distribution over `-proto_dist inet_tls` with `ssl_dist.conf` (certs at `/etc/ash_a2a/dist`). `false` is cleartext, local development only. |
| `SWARM_DIST_TLS_OPTFILE` | Override the ssl_dist optfile path. |
| `SWARM_SCHEDULERS` | `+S N:N`, match the pod CPU limit. |
| `SWARM_REQUIRE_GRAPHLAW` | `true` (prod default): boot fails if the GraphLaw WASM is not loaded; readiness also requires it. |
| `SWARM_MIN_PEERS`, `SWARM_DRAIN_MS`, `SWARM_ADMIN_PORT` | Readiness peer floor (default and minimum `div(ASH_A2A_EKV_CLUSTER_SIZE, 2)`, the EKV write-quorum peers; a lower value refuses boot), preStop drain window (a fixed time window, not an in-flight tracker), admin HTTP port (4001: `/healthz`, `/readyz`, `/drain`). |
| `SWARM_A2A_HTTP`, `SWARM_A2A_PORT`, `SWARM_A2A_BASE_URL` | Opt-in A2A JSON-RPC surface (`AshA2A.Transport.Plug` at `/a2a`, port 4000). Off by default. |
| `SWARM_LOG_LEVEL` | Logger level; prod logs are JSON lines (`SwarmNode.JsonLogFormatter`). |

## Production checklist

Every item below has an unsafe dev default in the library; a production host
must set all of them (the `swarm/` prod release enforces this at boot):

1. `:receipt_store` = `AshA2A.ReceiptStore.Ekv` with a persistent
   `:receipt_store_ekv_opts[:data_dir]` and `:cluster_size` = replica count.
2. `:authority_broker` = `{AshA2A.Authority.Broker.Ekv, data_dir: <persistent>,
   cluster_size: n}` (unset refuses every consequential dispatch).
3. `:receipt_outbox_dir` on persistent storage.
4. `:receipt_binding_key` (secret, same on every node).
5. `:standing_ledger_key` (exactly 32 bytes, same on every node).
6. `:capability_release_mode` = `:strict` plus a frozen
   `:capability_release_closure`.
7. The GraphLaw WASM shipped in the release (`priv/graphlaw/`) and verified
   loaded at boot (`AshA2A.GraphLaw.WasmexHost.available?/0`).
8. `AshA2A.ReceiptOutbox.Reconciler` running (started by default by
   `AshA2A.Application`; do not set `config :ash_a2a, :outbox_reconciler,
   false` unless the host supervises its own instance).
9. Erlang distribution over TLS with a dedicated CA; distribution ports
   reachable only from peer pods.
10. A2A HTTP (if exposed) behind an HTTPS-only ingress (HSTS); TLS terminates
    at the ingress.
