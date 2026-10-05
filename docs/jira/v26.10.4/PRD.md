# PRD v26.10.4 — Fortune 5 Enterprise Hardening & Affidavit Cryptographic Trust Plane

**Status:** PROPOSED (2026-10-04, for v26.10.4 milestone)  
**Release:** v26.10.4  
**Repository:** `seanchatmangpt/ash_a2a`  
**Owner:** ash_a2a  
**Dependencies:** `ash_a2a` v26.10.3 (`mix.exs`), `affidavit` v0.1.0 WASM engine (`/Users/sac/affidavit`), `packs/aaif-vanilla-pack` (`/Users/sac/ggen-marketplace`)  
**Authority ceiling:** CONSTRUCT + verification only — architecture, schemas, and pipeline specifications; zero ambient DO authority.

---

## 1. Product Outcome

Transform `ash_a2a` into an enterprise-grade agent-to-agent communication and semantic computation runtime that satisfies the stringent non-functional, security, privacy, and compliance requirements of Fortune 5 financial and healthcare institutions. 

Specifically, `ash_a2a` v26.10.4 bridges:
1. **Zero-Trust Identity & Policy**: SPIFFE/SPIRE workload identity validation linked to external OpenID AuthZEN PDPs via continuous authorization and monotonic grant narrowing.
2. **Inline Privacy & Data Sovereignty**: Real-time bidirectional DLP (PII/PHI redaction) and strict cryptographic data-residency enforcement.
3. **Hardware-Anchored Key Management**: Cloud KMS and HSM Customer-Managed Encryption Keys (CMEK/BYOK) for envelope encryption of task parameters and agent state.
4. **Resilient Mission-Critical SRE Operations**: Two-phase graceful workload DRAIN protocol (`cordon` -> `drain`) with live execution state migration.
5. **Deterministic FinOps**: Token budget ceilings with hard compile/runtime circuit breakers and cost-center chargeback attribution.
6. **Cryptographic Provenance Plane**: Hardware and Post-Quantum Cryptography (ML-DSA-65, SLH-DSA, hybrid ES256) anchoring via `affidavit` WASM integration, emitting tamper-evident IEEE OCEL v2 audit streams to enterprise SIEMs (Splunk, Chronicle, Datadog).

---

## 2. Problem Statement

While `ash_a2a` provides mathematically rigorous action-to-skill dispatch, typed authority ceilings, and local verification courts, enterprise adoption across Fortune 5 regulated sectors (banking, healthcare, defense) is blocked by six missing enterprise guarantees:

1. **Identity & Authorization Drift**: Workload identity is often assumed or authenticated via static tokens rather than dynamic SPIFFE SVIDs, with no real-time PDP consultation conforming to OpenID AuthZEN specifications.
2. **Data Leakage & Compliance Exposure**: LLM tool calls and agent messages risk leaking sensitive PII/PHI across jurisdictional boundaries without inline tokenization and residency validation.
3. **Key Ownership & Regulatory Secrecy**: Enterprise customers cannot deploy on shared or cloud-managed keys; FIPS 140-3 Level 3 HSM and CMEK envelope encryption are table stakes.
4. **Node Disruption & Task Dropping**: SRE cluster updates (rolling reboots, Spot instance preemption) drop active long-running agent workflows without transactional two-phase drain and safe rehydration.
5. **Runaway Cost Risk**: Unbounded autonomous recursive loops create unpredictable cloud expenditure without hard budget ceilings and organizational chargeback metadata.
6. **Post-Quantum & Audit Vulnerability**: Audit logs are text-based or vulnerable to retroactive decryption ("Harvest Now, Decrypt Later") without post-quantum signatures and verifiable object-centric event logging.

---

## 3. Verified Gap Matrix (Fortune 5 Requirements)

| Identifier | Requirement Domain | Gap Description | Evidence & Prior Art | Target Resolution |
| :--- | :--- | :--- | :--- | :--- |
| **GAP-01** | **Zero-Trust SPIFFE & AuthZEN** | SVID parsing lacks dynamic bundle rotation; AuthZEN PDP lacks monotonic grant narrowing during recursive subtask delegation. | `lib/ash_a2a/spiffe/` & `lib/ash_a2a/authzen/` (v26.10.2) | Bind SPIRE Workload API to `AshA2A.SPIFFE.SVIDValidator` with streaming X.509 rotation; enforce subtask grant monotonicity in `AshA2A.AuthZEN.DecisionGate`. |
| **GAP-02** | **Inline DLP & Data Residency** | Agent payloads pass uninspected to LLMs; messages lack jurisdiction tag verification. | `lib/ash_a2a/transport/plug.ex` | Add `AshA2A.Security.DLPFilter` plug for regex/NER redaction and `AshA2A.Security.DataResidency` checking against tenant geographic policy. |
| **GAP-03** | **CMEK / BYOK Envelope Encryption** | Internal state and task bus payloads use ephemeral in-memory or database plaintext storage. | `lib/ash_a2a/command_bus/` | Integrate Google Cloud KMS / AWS KMS / Vault PKCS#11 HSM via `AshA2A.Security.CMEK` envelope encryption (AES-256-GCM + DEK wrapping). |
| **GAP-04** | **SRE Graceful DRAIN & Migration** | SIGTERM causes immediate socket termination or dropped execution threads. | `lib/ash_a2a/agent.ex`, `lib/ash_a2a/durable_server.ex` | Implement `AshA2A.Cluster.DrainManager`: Phase 1 HTTP 503 cordon; Phase 2 checkpoint active tasks to storage and notify peer nodes. |
| **GAP-05** | **FinOps Budget Ceilings & Chargeback** | Execution permits arbitrary token consumption; no cost-center tagging on action dispatch. | `lib/ash_a2a/dispatcher.ex` | Add `AshA2A.FinOps.BudgetCeiling` pre-dispatch gate; enforce hard ceiling refusal (`:REFUSED_BUDGET_EXCEEDED`) and chargeback metadata tagging. |
| **GAP-06** | **Affidavit PQC & OCEL v2 SIEM Stream** | Audit logging uses flat JSON/telemetry; lacks NIST PQC signatures and IEEE OCEL v2 graph structure. | `/Users/sac/affidavit`, `lib/ash_a2a/telemetry/ocel_forwarder.ex` | Call `AshAffidavit` WASM engine for `PQ-SEAL-v1` (ML-DSA-65) receipts; stream OCEL v2 ndjson events directly to SIEM webhooks. |

---

## 4. Functional Requirements

### 4.1. Zero-Trust Identity & Monotonic Policy (FR-01)
- **FR-01.1**: `AshA2A.SPIFFE.WorkloadWatcher` must maintain an active connection to `/run/spire/sockets/agent.sock`, stream X.509 SVIDs, and maintain an in-memory trust bundle cache rotated before certificate expiry.
- **FR-01.2**: All inbound HTTP requests to `/a2a/jsonrpc` must extract the SPIFFE client certificate SVID, validating trust domain, namespace, and service account.
- **FR-01.3**: `AshA2A.AuthZEN.Client` must evaluate authorization decisions against external PDPs (e.g., OpenFGA, Permit.io, Styra OPA) conforming to OpenID AuthZEN Draft 03.
- **FR-01.4**: Child subtasks initiated by an agent must compute an intersection of parent permissions, refusing any delegation that expands capability (`:REFUSED_NON_MONOTONIC_GRANT`).

### 4.2. Inline DLP & Sovereign Data Residency (FR-02)
- **FR-02.1**: Inbound task parameters and outbound result objects must pass through `AshA2A.Security.DLPFilter`.
- **FR-02.2**: High-entropy patterns (SSNs, credit cards, API keys) and PHI entities must be tokenized or redacted with reversible deterministic masks before hitting external LLM providers or audit sinks.
- **FR-02.3**: Workloads tagged with residency rules (e.g., `residency: "eu-central-1"`) must be refused (`:REFUSED_DATA_RESIDENCY_VIOLATION`) if dispatched on nodes outside the declared region.

### 4.3. CMEK Envelope Encryption & Key Versioning (FR-03)
- **FR-03.1**: Storage of task states, conversation histories, and cached artifacts must use envelope encryption.
- **FR-03.2**: A local Data Encryption Key (DEK) is generated via crypto-secure PRNG (`:crypto.strong_rand_bytes(32)`) and encrypted by a Key Encryption Key (KEK) via Cloud KMS / HSM.
- **FR-03.3**: Support automatic DEK re-wrapping and rotation upon KEK version updates without rewriting ciphertext.

### 4.4. Two-Phase DRAIN & Live Workload Evacuation (FR-04)
- **FR-04.1**: Trapping `SIGTERM` initiates Phase 1 (Cordon): The HTTP endpoint returns HTTP 503 (`Retry-After: 30`) to health checks and load balancers, rejecting new tasks while permitting existing tasks to continue.
- **FR-04.2**: Phase 2 (Drain): Workloads that cannot complete within the configured grace period (`drain_timeout_ms`, default 25,000ms) serialize their execution frame and transition state into durable storage.
- **FR-04.3**: Active workers broadcast a state handover event allowing surviving peer nodes in the cluster to rehydrate and resume the execution without data loss.

### 4.5. FinOps Hard Quotas & Chargeback Tracking (FR-05)
- **FR-05.1**: Every incoming request must provide or resolve an organizational `cost_center` and `budget_account_id`.
- **FR-05.2**: `AshA2A.FinOps.BudgetEnforcer` verifies that cumulative token/compute consumption for the billing window remains below the assigned hard ceiling.
- **FR-05.3**: When usage exceeds 100% of quota, dispatch is refused immediately with `:REFUSED_BUDGET_EXCEEDED` and zero downstream LLM tokens are consumed.

### 4.6. Affidavit Trust Plane & IEEE OCEL v2 Telemetry (FR-06)
- **FR-06.1**: Embed `/Users/sac/affidavit` WASM engine via Wasmex/Wasmtime inside `AshA2A.Evidence.Affidavit`.
- **FR-06.2**: Generate cryptographic receipts using algorithm `PQ-SEAL-v1` (NIST FIPS 204 ML-DSA-65 with hybrid ES256 and BLAKE3 rolling hash chains).
- **FR-06.3**: Structure all event telemetry as IEEE OCEL v2 compliant ndjson streams correlating `WorkOrder`, `Agent`, `EvidencePackage`, and `Resource` objects.
- **FR-06.4**: Provide direct, resilient HTTP/gRPC egress adapters to enterprise SIEM platforms (Splunk HEC, Google Chronicle, Datadog Logs).

---

## 5. Non-Functional Requirements & Enterprise SLOs

- **Performance & Latency Overhead**:
  - SPIFFE SVID validation + AuthZEN decision gate: $\le 1.8\text{ms}$ at p99.
  - Inline DLP inspection: $\le 2.5\text{ms}$ per 64KB payload.
  - Envelope encryption / decryption: $\le 0.8\text{ms}$ overhead.
  - `affidavit` WASM receipt generation: $\le 4.2\text{ms}$ for ML-DSA-65 signing.
- **Reliability & DRAIN**:
  - Zero dropped in-flight tasks during graceful node termination (`SIGTERM`).
  - DRAIN timeout guarantee: Complete clean shutdown within $28\text{s}$ (fitting standard Kubernetes 30s `terminationGracePeriodSeconds`).
- **Cryptographic Security**:
  - NIST Post-Quantum Level 3 assurance for long-lived receipts.
  - Fail-closed admission: Any failure in KMS, SPIFFE socket, or AuthZEN PDP halts dispatch.
- **Enterprise Compliance Framework Alignment**:
  - SOC 2 Type II (Trust Services Criteria: Security, Confidentiality).
  - HIPAA Security & Privacy Rule (45 CFR Part 160 and Part 164).
  - PCI-DSS v4.0 (Requirement 3: Protect Cardholder Data; Requirement 10: Log and Monitor).
  - ISO/IEC 27001:2022 (Annex A.8: Technological Controls).

---

## 6. Acceptance Criteria

1. **SPIFFE/AuthZEN Court**: `mix test test/ash_a2a/enterprise/spiffe_authzen_test.exs` passes with 100% real collaborator evaluation; non-monotonic child delegation is provably refused.
2. **DLP & Sovereignty Court**: Tests confirm that PII/PHI strings are never persisted in plaintext, and cross-region dispatches fail closed with `:REFUSED_DATA_RESIDENCY_VIOLATION`.
3. **CMEK Court**: Verification tests exercise DEK generation, Cloud KMS mock/harness key wrapping, and encrypted payload storage; tampering with ciphertext results in AEAD decryption failure.
4. **Drain Court**: Simulating `SIGTERM` verifies immediate HTTP 503 cordon, zero task drop, execution frame checkpointing, and safe resumption.
5. **FinOps Court**: Quota breach halts dispatch prior to action execution, recording a typed refusal receipt.
6. **Affidavit & OCEL v2 Court**: `mix test test/ash_a2a/evidence/affidavit_ocel2_test.exs` validates byte-identical replay, ML-DSA-65 signature verification, and schema validation of OCEL v2 ndjson payloads.
7. **Refinement & Counterfactual Courts (FR-07)**: the adversarial probe suite (`test/lane_x*_…` promoted to permanent courts) passes — every implementation-drift mutation fired by a named court; the spec-refinement sample (codec output vs vendored IDL, §FR-07) is green on the current tree.

---

## 7. Formal Boundary Classes, Engineering Posture & Non-Goals

Four boundary classes limit any architecture's guarantees — including this one. Each is stated formally, assessed for engineerability within the `ash_a2a` authority model, and mapped to mitigations and courts. The defensible claim is **bounded correctness within the stated threat model**; universal guarantees are out of scope and are not claimed.

### 7.1. Refinement Gap (`ℐ ≢ 𝒮`)

The abstract specification 𝒮 (ontology, SPARQL invariants, admission rules) and the concrete implementation ℐ (BEAM VM, x86/ARM, OS kernel) are not equivalent: ∃ σ ∈ Behaviors(ℐ) with σ ∉ Behaviors(𝒮) ∧ σ ⊭ φ.

**Engineering posture: PARTIAL.**
- *Sampled refinement checking*: the court suite is an implementation-conformance harness — mutation-tested, adversarially probed (counterfactual lanes X1–X10 caught implementation drift the abstract model does not capture). Promoted to permanent courts per FR-07.
- *Blast-radius containment*: process isolation, off-mailbox workers, and supervised trees bound the reach of any out-of-model behavior.
- *CMEK reduces the refinement-side key exposure*: a memory-scrape of BEAM memory exposes per-task DEKs only; the customer KEK is never resident.
- **Non-goals**: microarchitectural side channels (Spectre-class), memory corruption in native runtimes, OS kernel-level socket hijacking. These are operationally mitigated (isolation, CMEK) but not eliminated.

### 7.2. Open-World Axioms (Gödel / Bounded Verification)

Any consistent theory T expressive enough to model general computation admits ψ with T ⊬ ψ ∧ T ⊬ ¬ψ. The gates evaluate a closed world 𝒲_closed; deployments live in 𝒲_open. An adversarial condition α ∈ (𝒲_open ∖ 𝒲_closed) — clock skew, node partitions, unmodeled dependencies — invalidates the proof inapplicably.

**Engineering posture: MOSTLY — fail-closed admission is the open-world strategy.**
- Unmodeled conditions α produce **typed refusals, never silent passes** (Invariant 2).
- Clock skew → monotonic timestamp guards; partitions → durable store + typed refusals (the system degrades to refusals, not divergence — the multinode continuity court pins read-through semantics).
- New dependency classes → court-gated: unmodeled surface requires explicit modeled admission before dispatch (Invariants 2–3).
- **Residual**: genuinely novel attack classes reach the system before a court exists. Rice's theorem closes the "full verification" escape hatch for us and every competitor; sampled adversarial courts are the honest substitute (FR-07).

### 7.3. Semantic Oracle Failure (Adversarial Compliant Input)

An adversary finds x* such that f_gate(x*) = 1 (syntactically compliant, admitted) while SemanticEffect(x*) = ℳ (malicious payload): indirect prompt injection, adversarial token manipulation, or an authorized principal issuing lawful-but-catastrophic instructions.

**Engineering posture: SUBSTANTIAL — this is the architecture's design center.**
- *Gate-admittance ≠ authority*: actuation requires a broker-admitted `Grant.authorize/3` token; an admitted request carrying ℳ cannot actuate without a discrete grant (the authority courts pin proof-vs-authority).
- *Monotonic narrowing bounds injection blast radius*: even a successful injection acts only within the principal's already-narrowed capability set (`C_child ⊆ C_parent`, FR-01.4).
- *Inline DLP (FR-02)* tokenizes the semantic payload before external LLM providers or audit sinks see it.
- *PQ receipts (FR-06)* make post-hoc forensics complete and tamper-evident.
- **Non-goal**: an authorized principal lawfully issuing catastrophic business instructions. That is a governance surface; the system refuses it only by policy configuration, and the boundary is pinned by the authority courts rather than hidden.

### 7.4. Cryptographic ε(λ) and Key Boundaries

Cryptographic reductions (ML-DSA-65, BLAKE3, AES-256-GCM) provide computational bounds Pr[Forge] ≤ ε(λ) with ε(λ) > 0, conditioned on key confidentiality: Pr[Breach] = 1 − (1 − Pr[KeyExfiltration])(1 − Pr[AlgorithmicBreak]).

**Engineering posture: OPERATIONAL MAJORITY.**
- *CMEK/BYOK (FR-03)*: the customer holds the KEK; it is never resident in `ash_a2a` memory or config. HSM-backed KEKs move the exfiltration boundary onto the customer's hardware.
- *Rotation (FR-03.3)* bounds the exposure window of any wrapped DEK without payload rewrite.
- *Hybrid PQ (FR-06.2, ML-DSA-65 + ES256)* addresses Harvest-Now-Decrypt-Later for long-lived receipts; BLAKE3 chaining makes retroactive tampering evident.
- *Credential stripping (FR-02 + SEC-01)* minimizes key-material on the wire and in persistence.
- **Non-goals**: ε(λ) > 0 itself (accepted at the 256-bit security class); an insider with legitimate KEK access (governance/HSM boundary); a full algorithmic break of ML-DSA-65 (hybrid construction mitigates, does not eliminate).

### 7.5. Summary

| Boundary class | Engineerable | Primary mitigations | Pinning courts | Honest residual |
| :--- | :--- | :--- | :--- | :--- |
| Refinement gap (ℐ ≢ 𝒮) | Partial | Sampled refinement courts; process isolation; CMEK blast-radius | Full court suite; counterfactual probes (FR-07) | Side channels; native runtime; BEAM memory |
| Open-world axioms | Mostly | Fail-closed admission; typed refusals; durable-store degradation | Every gate court; multinode continuity court | Novel classes before a court exists |
| Semantic oracle failure | Substantial | Authority separation; monotonic narrowing; DLP; PQ receipts | Authority courts; monotonic court; DLP court; receipt courts | Authorized-principal governance surface |
| Crypto ε(λ) + key boundaries | Operational majority | CMEK/BYOK; rotation; hybrid PQ; BLAKE3 chains; stripping | CMEK court; affidavit/OCEL2 court | Insider KEK access; algorithmic break |

Claims of "unbeatable" are explicitly **not** made and are excluded from marketing use; the defensible statement is bounded correctness within this threat model, with the residual table above carried in every customer-facing commitment derived from this PRD.
