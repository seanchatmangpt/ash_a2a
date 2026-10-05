# Enterprise Reference

The v26.10.4 enterprise surface (`docs/jira/v26.10.4/PRD.md`, FR-01 through
FR-06): a config-gated layer of hardening subsystems around the A2A wire
surface. Every child of the enterprise supervisor is default-OFF; a child
starts only when its `config :ash_a2a, ...` key is set. `nil` and `false`
both mean OFF, so dev and test boots are unchanged. Every gate is
fail-closed: an unavailable capability is a typed refusal, never a silent
pass.

## composition-root

`AshA2A.Enterprise.Supervisor` (court:
`test/ash_a2a/enterprise/supervisor_test.exs`) is an optional supervision
subtree under the application root. Gate keys read from
`config :ash_a2a, ...`:

| Gate key | Child | Value shape |
| --- | --- | --- |
| `:spiffe_socket` | `AshA2A.SPIFFE.WorkloadWatcher` | SPIRE UDS path |
| `:authzen_pdp_url` | `AshA2A.AuthZEN.DecisionPool` | presence gates the pool; URL is per-call |
| `:kms` | `AshA2A.Security.KeyManager` | `[client: module(), kek_id: String.t()]` |
| `:finops` | `AshA2A.FinOps.BudgetStore` | quota keyword list |
| `:drain` | `AshA2A.Cluster.DrainManager` + drained `Task.Supervisor` | `true` or opts |
| `:affidavit` | affidavit pool child (landed, court pending) | `[wasm_path: String.t()]` |
| `:siem` | OCEL broadcaster child (landed, court pending) | `[endpoints: [String.t()]]` |

The `:drain` key gates two children: the drain manager plus the
`Task.Supervisor` it drains, so one key gates exactly the pair it governs.

A gated-on child whose module is not compiled in is a typed skip
(`{:module_unavailable, module}` or `{:not_startable, module}`), logged,
never silent: the capability is ABSENT and its enforcement points refuse
fail-closed on their own surfaces. The `:kms` binding is still applied even
while no process child is startable: `kms: [client: mod, ...]` is projected
onto `config :ash_a2a, :cmek_kms_client` at supervisor start (explicit host
config wins). The `:affidavit` and `:siem` gate children (affidavit pool,
OCEL broadcaster) are landed as gate keys and typed skips; the pool and
broadcaster child modules themselves are court pending — until they land,
configuring those keys logs the typed skip and the enforcement points
(`AshA2A.Evidence.Affidavit`, `AshA2A.Telemetry.SIEM`) stay the direct
call-in surfaces.

Options: `:name` (supervisor registered name), `:overrides` (per-module
child opts, test seam for unique registered names).

## fr-01-zero-trust-identity-and-policy

### spiffe-workload-identity

What it guards: workload authentication. `AshA2A.SPIFFE.WorkloadWatcher`
(court: `test/ash_a2a/enterprise/spiffe_workload_watcher_test.exs`) holds a
streaming connection to a SPIRE agent's Workload API UNIX socket and
rotates X.509 SVIDs into an `AshA2A.SPIFFE.TrustBundle` cache before
expiry. `AshA2A.SPIFFE.SvidValidator` (court:
`test/ash_a2a/enterprise/svid_validator_test.exs`) is a Plug that
authenticates the caller from the TLS peer certificate and stamps the
verified `AshA2A.SPIFFE.AttestedIdentity` into `conn.assigns`
(`:spiffe_identity` by default).

Fail-closed refusals: `{:error, :trust_bundle_expired}` once the
last-known-good bundle passes `:expires_at` (watcher);
typed 401 JSON bodies for missing/malformed/expired/untrusted SVIDs and
503 for a faulting bundle source (validator);
`AshA2A.SPIFFE.Identity.parse/1` refuses query/fragment confusion
(`:spiffe_query_fragment_forbidden`).

Config:

```elixir
config :ash_a2a,
  spiffe_socket: "/run/spire/sockets/agent.sock",
  spiffe_trust_domain: "example.org"
```

Watcher opts (per child spec): `:socket_path` (default
`/run/spire/sockets/agent.sock`), `:trust_domain` (falls back to
`:spiffe_trust_domain`), `:rotation_lead_ms` (default `30_000`),
`:reconnect_backoff_ms` (default `500`). Validator opts: `:trust_domain`
(required), `:bundle_source` (module exporting `bundle/0`; default the
watcher), `:assign` (default `:spiffe_identity`).

### authzen-access-evaluation

What it guards: policy decisions are observed, never trusted as authority.
`AshA2A.AuthZEN.Client` (court:
`test/ash_a2a/enterprise/authzen_client_test.exs`) posts OpenID AuthZEN
evaluation requests through `AshA2A.AuthZEN.DecisionPool` (real Finch pool
plus local TTL decision cache). `AshA2A.AuthZEN.DecisionGate.admit/3`
re-checks the observed evidence against the exact `AshA2A.C2.PreparedEffect`
(decision, expected PDP, effect digest, principal must all hold).

Fail-closed refusals: `:pdp_unreachable`, `{:pdp_error, status}`,
`:invalid_decision` (client); `:denied`, `:pdp_mixup`,
`:effect_digest_mismatch`, `:principal_mismatch` (gate); a PDP outage can
never become an allow.

Config: `config :ash_a2a, :authzen_pdp_url` gates the pool child under the
enterprise supervisor; the URL itself is passed per call.

### monotonic-delegation-narrowing

What it guards: delegation blast radius. `AshA2A.AuthZEN.Monotonic`
(court: `test/ash_a2a/enterprise/monotonic_grant_test.exs`) enforces
`C_child ⊆ C_parent` at every hop. `AshA2A.AuthZEN.DecisionGate
.admit_delegated/4` composes evidence admission with the chain check.

Fail-closed refusal: `:refused_non_monotonic_grant` as a typed
`AshA2A.AuthZEN.Monotonic` refusal receipt (canonical digest, excess set,
chain depth) before any downstream dispatch. Single-parent `delegate/2`
refuses expansion; the multi-parent clause clamps to the intersection by
construction.

## fr-02-dlp-and-data-residency

### inline-dlp

What it guards: sensitive spans in A2A payloads, both directions.
`AshA2A.Security.DLPFilter` (court:
`test/ash_a2a/enterprise/dlp_filter_test.exs`) detects PCI-DSS PAN (Luhn),
US SSN, high-entropy API keys (Shannon entropy), and configurable PHI
patterns, replacing each with a deterministic reversible pseudonym.
`AshA2A.Security.DLPFilter.Plug` wraps any inner transport plug for
bidirectional redaction.

Config:

```elixir
config :ash_a2a, AshA2A.Security.DLPFilter,
  key: <at least 16 bytes of secret>,
  entropy_floor: 3.5,
  phi_patterns: [%{id: :mrn, pattern: ~r/.../}],
  enabled: true
```

`:key` falls back to an ephemeral per-VM key (warning logged once; the key
is never logged); ephemeral-key pseudonyms are stable within the VM
lifetime only. Findings carry type, token, and span — never plaintext.
Redaction is idempotent over the filter's own `dlt1_` tokens.

### data-residency

What it guards: data-jurisdiction locality. `AshA2A.Security.DataResidency`
(court: `test/ash_a2a/enterprise/data_residency_test.exs`) compares a
workload's `data_jurisdiction` tag against the node's region at dispatch
time.

Fail-closed refusals: `:refused_data_residency_violation` (tag outside the
node region or group) and `:refused_data_residency_unknown_region` (tagged
workload on a node of unknown region — never passed).

Config:

```elixir
config :ash_a2a,
  node_region: "europe-west1"
  # or:
  node_region_provider: MyApp.RegionProvider  # region/0 callback
```

Tag precedence: call opts, then workload `data_jurisdiction` (top level or
`metadata`), then untagged (always passes). Region groups (`EU`, `US`,
`APAC`) use documented provider prefix rules, extendable via
`opts[:region_groups]`.

## fr-03-cmek-envelope-encryption

What it guards: payload confidentiality with customer-held key material.
`AshA2A.Security.KeyManager` composes `AshA2A.Security.CMEK` (AES-256-GCM
payload layer, envelope `{ciphertext, wrapped_dek, iv, tag, kek_version_id}`)
with an `AshA2A.Security.KMS.Client` binding for KEK wrap/unwrap. Rotation
re-wraps the DEK without decrypting the payload. Courts:
`test/ash_a2a/enterprise/cmek_test.exs`, and the KMS binding projection in
`test/ash_a2a/enterprise/supervisor_test.exs`.

Fail-closed refusals: `:refused_cmek_kms_unavailable` (no KMS client or KMS
unreachable), `:refused_cmek_unwrap_failed`, `:refused_cmek_tamper_detected`
(AEAD auth failure), `:refused_cmek_invalid_envelope`. There is no
plaintext fallback and no locally-held key material.

Config:

```elixir
config :ash_a2a,
  kms: [client: MyApp.CloudKMS, kek_id: "my-kms-key"],
  # or the direct binding:
  cmek_kms_client: MyApp.CloudKMS,
  cmek_kek_id: "my-kms-key"
```

Resolution order: `opts[:kms_client]`, then
`config :ash_a2a, :cmek_kms_client`, then fail closed.
`AshA2A.Security.KMS.Local` is the local KMS harness for tests.

## fr-04-two-phase-drain

What it guards: live workload evacuation inside the Kubernetes 30s grace
period. `AshA2A.Cluster.DrainManager` (court:
`test/ash_a2a/enterprise/drain_test.exs`, which also covers
`AshA2A.Cluster.HealthPlug`, `AshA2A.Cluster.Checkpoint`, and
`AshA2A.Cluster.Handover`) traps the real OS `SIGTERM`
(`:os.set_signal(:sigterm, :handle)`), cordons (503 + `Retry-After` on the
health surface, `{:error, :cordoned}` on new work), gives tracked tasks
until the drain deadline, checkpoints unfinished execution frames to the
durable task store, emits handover events for peer rehydration, then exits
clean.

Fail-closed refusals: `{:error, :cordoned}` for `track/3` after cordon.

Config:

```elixir
config :ash_a2a, :drain,
  drain_timeout_ms: 25_000,
  retry_after_s: 30,
  exit_grace_ms: 2_000,
  halt_after_drain: true,
  install_signal_handler: false  # when another component owns SIGTERM
```

The `:drain` gate starts the drained `Task.Supervisor` alongside the
manager, so one key gates exactly the pair it governs.

## fr-05-finops-budget-ceilings

What it guards: downstream LLM spend. `AshA2A.FinOps.BudgetEnforcer
.authorize/3` runs before dispatch (court:
`test/ash_a2a/enterprise/finops_test.exs`): resolves `cost_center` and
`budget_account_id` from request metadata or configured defaults, reserves
the estimated token cost against the account's hard ceiling via
`AshA2A.FinOps.BudgetStore.record/3`, and emits
`[:ash_a2a, :finops, :chargeback]` on every verdict.
`AshA2A.FinOps.Chargeback` carries the billing metadata. `settle/3` records
post-dispatch actual consumption.

Fail-closed refusals: `:budget_exceeded` (a breach consumes zero downstream
tokens), `:missing_evidence` (no configured ceiling is not unlimited),
`:invalid_request` (unresolvable attribution).

Config:

```elixir
config :ash_a2a, :finops,
  default_cost_center: "cc-42",
  default_budget_account_id: "ba-7"
  # plus per-account quota keys consumed by BudgetStore
```

## fr-06-affidavit-trust-plane-and-siem-egress

### affidavit-receipts

What it guards: tamper-evident, post-quantum-capable evidence over
lifecycle events. `AshA2A.Evidence.Affidavit` bridges receipts, traces, and
identity claims to the `AshAffidavit` WASM engine (authority NONE, pure
evidence). `AshA2A.Evidence.Ocel2` serializes IEEE OCEL v2 event logs.
Courts: `test/ash_a2a/evidence/affidavit_test.exs` (real WASM engine) and
`test/ash_a2a/enterprise/affidavit_ocel2_test.exs`.

Fail-closed refusals: `{:error, :ash_affidavit_unavailable}` when the
engine is not loaded; `{:refused_affidavit, ref}`, `{:affidavit_trap,
trap}`, `{:unsupported_affidavit, unsup}` from the engine.

Config: `config :ash_a2a, affidavit: [wasm_path: ...]` gates the affidavit
pool child under the enterprise supervisor (typed skip until the pool child
lands; the direct call-in surface is available today).

### siem-egress

What it guards: audit egress of IEEE OCEL v2 events to enterprise SIEM
platforms. `AshA2A.Telemetry.SIEM` (court:
`test/ash_a2a/enterprise/siem_test.exs`) provides `deliver/3` adapters for
Splunk HEC (`AshA2A.Telemetry.SIEM.SplunkHEC`), Google Chronicle
(`AshA2A.Telemetry.SIEM.Chronicle`), and Datadog Logs
(`AshA2A.Telemetry.SIEM.DatadogLogs`). Payloads are the event maps already
produced by `AshA2A.Telemetry.OcelForwarder` and
`AshA2A.SemanticProjection.ocel_event/1`, validated fail-closed before any
connection.

Fail-closed behavior: every exhaustion collapses into
`{:error, {:siem_delivery_failed, platform, reason}}`; delivery never
crashes the dispatch path it observes. Endpoints are admitted by
`AshA2A.Egress.EndpointPolicy` (CWE-918: https-only and public addresses by
default in prod, connection pinned, no redirects).

Config:

```elixir
config :ash_a2a,
  siem: [endpoints: ["https://hec.example.com"]],
  siem_egress_policy: [allow_http: false],
  ocel_ingest_url: "https://ingest.example.com"
```

`deliver/3` options: `:batch_size` (default `500`), `:max_retries`
(default `2`), `:backoff_base_ms` (default `50`), `:max_backoff_ms`
(default `2_000`), `:transport_opts` (standard `:ssl` mTLS options; each
configured file must exist). `config :ash_a2a, siem: [endpoints: [...]]`
gates the OCEL broadcaster child under the enterprise supervisor (typed
skip until the broadcaster child lands).

## inbound-pipeline

`AshA2A.Enterprise.Pipeline` (court:
`test/ash_a2a/enterprise/pipeline_test.exs`) is one ordered plug composing
the gates around any inner transport plug. Fixed structural order (ARD
v26.10.4 §2): SVID validation, AuthZEN gate (with monotonic narrowing for
delegated tasks), DLP inbound, residency, budget, dispatch, DLP outbound,
CMEK envelope, affidavit receipt, OCEL forward. Config toggles stages,
never reorders them.

Fail-closed: any enabled stage's refusal halts with that stage's typed wire
error; later stages and dispatch never run; a refused outbound stage
replaces the response with its typed 500.

Config (plug opts win over app env):

```elixir
config :ash_a2a, AshA2A.Enterprise.Pipeline,
  svid: [trust_domain: "example.org"],
  authzen: [client: AshA2A.AuthZEN.Client],
  dlp: true,
  residency: true,
  budget: [store: AshA2A.FinOps.BudgetStore],
  cmek: true,
  affidavit: true,
  ocel: true
```

Each stage key takes `false`/absent (off), `true` (defaults), or its
options. `:inner` is the wrapped transport plug (default
`AshA2A.A2ATransport.Plug`).

## adjacent-surfaces

Landed alongside the FR-01..06 hardening (not PRD FR areas; each names its
court):

* `AshA2A.Passport` — signed, portable agent identity document: agent card
  plus capability attestations plus evidence chain under one RFC 6962-style
  Merkle root (`AshA2A.Passport.Merkle`) and one detached JWS
  (`AshA2A.Protocol.CardSigning` scheme). `verify/2` refuses malformed
  documents, bad signatures, and digest mismatches. Plug surface
  `AshA2A.Passport.Plug`, revocation via `AshA2A.Passport.Revocation`.
  Court: `test/ash_a2a_passport_test.exs`.
* `AshA2A.Trace` — TRACE-compliant, OTLP/JSON-exportable trace export of a
  task saga, recorded observationally by `AshA2A.Trace.Recorder`;
  deterministic trace/span ids derived from the task id. Court:
  `test/ash_a2a_trace_test.exs`.
* `AshA2A.Bidi` — bidirectional streaming over the existing SSE transport
  via a per-stream HTTP-POST input endpoint (`bidi/input`, `bidi/close`)
  carried as JSON-RPC envelopes; consumer-driven pull through
  `AshA2A.Bidi.Stream` and `AshA2A.Bidi.Channel`; plug surface
  `AshA2A.Bidi.Plug`. Court: `test/ash_a2a_v1_bidi_test.exs`.
* `AshA2A.Elicitation` — typed, schema-constrained input requests over the
  A2A `INPUT_REQUIRED` park/resume lifecycle (MCP `elicitation/create`
  form-mode subset; fails closed outside it). Court:
  `test/ash_a2a_v1_elicitation_test.exs`.

## boundaries

Non-goals and formal boundary classes are defined once in PRD §7
([docs/jira/v26.10.4/PRD.md](../jira/v26.10.4/PRD.md), "Formal Boundary
Classes, Engineering Posture & Non-Goals") and imported here by reference:
the refinement gap (sampled refinement courts, not universal guarantees),
open-world axioms (fail-closed admission, typed refusals, never silent
passes), semantic oracle failure (gate-admittance is not authority;
monotonic narrowing bounds injection), and cryptographic epsilon-lambda
(CMEK/BYOK keeps the KEK off the node; hybrid PQ receipts; the honest
residuals named there hold here).
