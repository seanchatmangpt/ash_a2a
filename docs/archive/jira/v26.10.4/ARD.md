# ARD v26.10.4 — Fortune 5 Enterprise Hardening & Affidavit Cryptographic Trust Plane

**Status:** PROPOSED (2026-10-04, for v26.10.4 milestone)  
**Release:** v26.10.4  
**Repository:** `seanchatmangpt/ash_a2a`  
**Owner:** ash_a2a  
**Dependencies:** `ash_a2a` v26.10.3 (`mix.exs`), `affidavit` v0.1.0 WASM engine (`/Users/sac/affidavit`), `packs/aaif-vanilla-pack` (`/Users/sac/ggen-marketplace`)  
**Authority ceiling:** CONSTRUCT + verification only — architecture, pipeline specifications, OTP supervisor trees; zero ambient DO authority.

---

## 1. Architectural Objective

Deliver an enterprise-hardened, mathematically verified architecture for `ash_a2a` v26.10.4 that embeds zero-trust identity, external continuous authorization, inline data loss prevention, hardware-backed envelope encryption, graceful cluster-aware drain semantics, FinOps circuit breakers, and post-quantum cryptographic receipts via `affidavit`.

The architecture enforces strict separation of concerns:
- **`affidavit`**: The cryptographic provenance plane. Authority ceiling = `NONE`. Owns post-quantum algorithms (ML-DSA-65, SLH-DSA), JCS canonicalization, BLAKE3 hash chains, and WASM receipt generation.
- **`ash_a2a`**: The execution and policy admission kernel. Evaluates authority, coordinates SPIFFE/AuthZEN gates, enforces DLP/Residency boundaries, manages two-phase DRAIN, and generates execution packages.
- **`aaif-vanilla-pack`**: The declarative configuration and packaging layer. Projects these capabilities onto Kubernetes and Google Cloud Marketplace with fail-closed SPARQL validation gates.

---

## 2. System Architecture & OTP Supervision Tree

The following diagram illustrates the OTP supervision hierarchy and execution pipeline for `ash_a2a` v26.10.4:

```text
AshA2A.Supervisor
├── AshA2A.SPIFFE.WorkloadWatcher (GenServer, SPIRE socket /run/spire/sockets/agent.sock)
├── AshA2A.AuthZEN.DecisionPool (NimblePool / Finch connection pool to PDP)
├── AshA2A.Security.KeyManager (GenServer, DEK caching, Cloud KMS / HSM envelope client)
├── AshA2A.FinOps.BudgetStore (ETS / Distributed cache for token counters & hard quotas)
├── AshA2A.Cluster.DrainManager (GenServer, SIGTERM listener, connection cordoner)
├── AshA2A.Evidence.AffidavitPool (Poolboy / Wasmex instances running affidavit WASM)
├── AshA2A.Telemetry.OcelBroadcaster (GenStage / Broadway pipeline to SIEM endpoints)
└── AshA2A.TaskSupervisor (DynamicSupervisor for isolated agent workflows)
```

### Inbound Execution Pipeline
```text
HTTP / a2a wire request
   │
   ▼
[AshA2A.Transport.Plug]
   │ 1. Extract SPIFFE X.509 SVID from TLS peer cert
   ▼
[AshA2A.SPIFFE.SVIDValidator]
   │ 2. Validate Trust Domain & SAN against cached SPIRE bundle
   ▼
[AshA2A.AuthZEN.DecisionGate]
   │ 3. Evaluate context against external PDP (OpenID AuthZEN)
   │    Verify monotonic narrowing for delegated child tasks
   ▼
[AshA2A.Security.DLPFilter]
   │ 4. Inline NER/regex redaction & Data Residency validation
   ▼
[AshA2A.FinOps.BudgetCeiling]
   │ 5. Validate cost-center token budget and enforce hard quota
   ▼
[AshA2A.Dispatcher]
   │ 6. Dispatch to Ash Resource / Domain Action
   ▼
[AshA2A.Security.CMEK]
   │ 7. Envelope encrypt task payload & execution state
   ▼
[AshA2A.Evidence.Affidavit]
   │ 8. Call WASM engine -> generate PQ-SEAL-v1 receipt (ML-DSA-65)
   ▼
[AshA2A.Telemetry.OcelForwarder]
     9. Emit IEEE OCEL v2 event stream to Enterprise SIEM
```

---

## 3. Core Architectural Subsystems

### 3.1. Zero-Trust Identity & AuthZEN Continuous Authorization
- **Module:** `AshA2A.SPIFFE.WorkloadWatcher` & `AshA2A.SPIFFE.SVIDValidator`
  - Maintains persistent UNIX domain socket stream to SPIRE Agent.
  - Automatically reloads X.509 SVIDs and intermediate CA bundles without process restart.
  - Validates caller identity `spiffe://<trust-domain>/ns/<namespace>/sa/<serviceaccount>`.
- **Module:** `AshA2A.AuthZEN.DecisionGate`
  - Constructs AuthZEN evaluation context: `{"subject": {"id": spiffe_id}, "action": {"name": skill_name}, "resource": {"id": resource_id}, "context": {...}}`.
  - Enforces **monotonic grant narrowing**: When an agent spawns subagents, the child's effective capability set $C_{child}$ is constrained such that $C_{child} \subseteq C_{parent}$. Attempted privilege escalation results in immediate `:REFUSED_NON_MONOTONIC_GRANT`.

### 3.2. Inline DLP & Sovereign Data Residency Guard
- **Module:** `AshA2A.Security.DLPFilter`
  - Runs streaming inspection over request parameters and response outputs.
  - Redacts sensitive tokens (PCI-DSS PAN, SSN, confidential API keys) using HMAC-backed pseudonymization.
- **Module:** `AshA2A.Security.DataResidency`
  - Inspects the execution context's `data_jurisdiction` tag (e.g., `EU`, `US_FEDRAMP_HIGH`).
  - Cross-references host metadata and GCP/AWS region topology. Dispatches violating territorial constraints fail closed with `:REFUSED_DATA_RESIDENCY_VIOLATION`.

### 3.3. CMEK & Hardware-Anchored Envelope Encryption
- **Module:** `AshA2A.Security.KeyManager`
  - Implements the standard envelope encryption pattern:
    1. Generates ephemeral 256-bit DEK using `:crypto.strong_rand_bytes(32)`.
    2. Encrypts payload with `AES-256-GCM` using the DEK.
    3. Calls Cloud KMS (or Vault Transit / PKCS#11 HSM) to wrap the DEK with customer's KEK: `WrappedDEK = Encrypt_KEK(DEK)`.
    4. Persists `{ciphertext, wrapped_dek, iv, tag, kek_version_id}`.
  - Supports non-destructive key rotation by re-wrapping DEKs without payload decryption.

### 3.4. Two-Phase DRAIN & Execution State Evacuation
- **Module:** `AshA2A.Cluster.DrainManager`
  - Traps system `:sigterm` and orchestrates a graceful two-phase shutdown:
    - **Phase 1: Cordon (0s - 3s)**: Health check endpoint `/healthz` transitions to HTTP 503; load balancer evicts node.
    - **Phase 2: Drain (3s - 25s)**:
      - In-flight tasks under `AshA2A.TaskSupervisor` are given up to `drain_timeout_ms` to conclude.
      - Tasks exceeding threshold have their execution call frames and pending steps checkpointed into durable storage.
      - Emits cluster re-route event to allow neighboring nodes to adopt suspended tasks.
    - **Phase 3: Exit (25s - 28s)**: Clean OTP tree termination before Kubernetes `SIGKILL` at 30s.

### 3.5. FinOps Hard Budget Ceilings & Chargeback
- **Module:** `AshA2A.FinOps.BudgetStore` & `AshA2A.FinOps.BudgetCeiling`
  - Tracks real-time token and compute consumption partitioned by `cost_center` and `project_id`.
  - Evaluates pre-dispatch budget reservations against configured hard ceilings.
  - If requested quota exceeds limit, dispatch is rejected with `:REFUSED_BUDGET_EXCEEDED` and zero execution side effects occur.
  - Tags all outbound telemetry with billing metadata for FinOps chargeback ingestion.

### 3.6. Affidavit WASM Trust Plane & IEEE OCEL v2 Streaming
- **Module:** `AshA2A.Evidence.Affidavit`
  - Hosts the compiled `/Users/sac/affidavit` WASM binary via Wasmex.
  - Invokes cryptographic export functions:
    - `canonicalize_jcs(json)`: RFC 8785 deterministic JSON canonicalization.
    - `sign_pqc(canonical_bytes, key_pair)`: NIST FIPS 204 ML-DSA-65 post-quantum signing.
    - `blake3_chain(prev_hash, current_bytes)`: Tamper-evident rolling hash chain calculation.
- **Module:** `AshA2A.Telemetry.OcelForwarder`
  - Serializes execution traces into IEEE OCEL v2 objects (`WorkOrder`, `Agent`, `EvidencePackage`, `ActionResource`).
  - Streams ndjson events directly to enterprise SIEM platforms (Splunk HEC, Datadog Logs, Google Chronicle) over mTLS.

---

## 4. ERRC Matrix (Architecture Trade-offs)

| Quadrant | Actions |
| :--- | :--- |
| **ELIMINATE** | • Static API tokens and hard-coded service credentials.<br>• Unchecked cross-region data transfers.<br>• Plaintext persistence of task inputs/outputs.<br>• Dropped tasks on Kubernetes node preemption. |
| **REDUCE** | • Authorization latency overhead (cached SPIFFE SVIDs and local PDP decision caching).<br>• KMS API egress costs via envelope encryption DEK reuse within session scope.<br>• Uncontrolled LLM token expenditure via hard pre-dispatch quota checks. |
| **RAISE** | • Cryptographic assurance (elevate from classical RSA/ECDSA to NIST PQC ML-DSA-65).<br>• Audit fidelity (from flat unstructured logs to IEEE OCEL v2 graph traces).<br>• SRE reliability (deterministic 28s shutdown guarantees). |
| **CREATE** | • `AshA2A.SPIFFE.WorkloadWatcher` and streaming X.509 rotation.<br>• `AshA2A.Security.DLPFilter` inline redaction plug.<br>• `AshA2A.Security.KeyManager` KMS envelope encryption client.<br>• `AshA2A.Cluster.DrainManager` two-phase evacuation engine.<br>• `AshA2A.Evidence.Affidavit` WASM PQC integration bridge. |

---

## 5. Architectural Invariants

1. **Authority Separation**: `affidavit` possesses authority ceiling `NONE`. It never authorizes or dispatches actions; it certifies evidence and signs cryptographic receipts. `ash_a2a` is the sole policy admission and execution kernel.
2. **Fail-Closed Gate Admission**: Any failure or timeout in SPIFFE validation, AuthZEN PDP consultation, DLP scanning, or KMS envelope decryption halts execution with a typed refusal. Ambient DO authority is impossible.
3. **Monotonic Capability Narrowing**: Subtasks cannot possess greater privileges than their parent agent. Escalation triggers compile-time or runtime `:REFUSED_NON_MONOTONIC_GRANT`.
4. **Deterministic PQC Signatures**: Every action generating external side effects produces an immutable `affidavit` receipt signed with `PQ-SEAL-v1` (ML-DSA-65) and linked to the preceding event via BLAKE3 hash chaining.
5. **Zero Data Loss on Node Preemption**: Any process termination via `SIGTERM` guarantees that all uncompleted state machines are durably serialized and transferred before process shutdown.
