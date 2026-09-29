# RFC-SA2A-006-existing-substrate-map-v26.9.28

Requirement-to-existing-technology map for RFC-SA2A-006 (adversarial control plane), written
under the section 5 rule: search downward (BEAM, OTP, Ash, prior art under `~`) before any new
mechanism. Every requirement family gets a verdict (REUSE, COMPOSE, EXTEND, INVENT), the
constraints a reimplementation would lose (Chesterton), an integration path that keeps native
code out of the kernel (RFC-006 section 23), and a falsifier for the reuse itself.

**Status:** analysis, generated 2026-09-28 at ash_a2a HEAD 492af9e (plus untracked RFC-006),
revised after an independent audit (section 11). Counts below are the post-audit values.
**Scope:** docs only. No mix command, test run or build was executed for this map.

## Contents

1. Method, labels, verdict definitions
2. Substrate catalog
3. Summary table
4. Requirement-family map (17 families)
5. bcinr and CMCA
6. NoveltyRatio
7. Red flags
8. Reuse-first implementation order
9. Lane-claim spot-check ledger
10. Unverified and open
11. Audit record
12. See Also

## 1. Method, labels, verdict definitions

Evidence labels used on every catalog entry and row:

- **[V]** read in the tree by this author (path and line or symbol cited).
- **[R]** REPORTED by a search lane only; not re-read here. Treat as a lead, not a fact.
- **[D]** DERIVED from [V] material by inference; the inference is stated.
- **[X]** executed here: a read-only shell command whose output is quoted.
- **REPORTED / CONTRADICTED / CORRECTED / UNVERIFIABLE** are audit outcomes: REPORTED = lead
  only; CONTRADICTED = a claim in an earlier draft that the code refutes; CORRECTED = a claim
  narrowed or re-scoped by a re-read; UNVERIFIABLE = no file located that supports it.

Verdicts:

- **REUSE**: an existing artifact satisfies the clause as it stands.
- **COMPOSE**: combine existing artifacts or standards without changing them.
- **EXTEND**: modify an existing artifact (in ash_a2a or a sibling) to cover the clause.
- **INVENT**: no existing artifact under `~` implements the clause. New code is required.
  Well-known external design patterns may exist; they are named as design input and are
  [D], not [V].

"Atomic requirement" (Axx) is one testable clause inside a family; counts in section 6 use
these. Lane ids (Lnn) refer to `docs/jira/v26.9.28-kernel/_LANES.md`, which this map does
not edit.

## 2. Substrate catalog

Each entry: path, language, maturity signal, evidence label. Maturity signals are file and
test presence or commit dates, not passing runs.

- **T01** `ash_a2a/lib/ash_a2a/application.ex`, `kill_switch.ex`, `receipt_outbox.ex`,
  `receipt_outbox/reconciler.ex`, `receipt_store/ekv.ex`. Elixir. OTP supervisor tree, EKV
  stores, outbox. [V] KillSwitch child at application.ex:125; outbox HMAC at
  receipt_outbox.ex:81 (`:crypto.mac`), :105 (`hash_equals`); `[:safe]` decode at :524. Tree
  internals beyond that [R].
- **T02** `ash_a2a/swarm/rel/overlays/ssl_dist.conf`, `rel/env.sh.eex`. Erlang config.
  Dist over TLS, verify_peer, TLS 1.2/1.3. [V] SNI disabled on client side; env.sh.eex
  documents `SWARM_DIST_TLS=false` as "local dev ONLY". `dist_tls_test.exs` [R].
- **T03** `bcinr/crates/bcinr-cmca/src/cascade.rs`. Rust. Arbitrary-tree share cascade,
  `consequence_mass`, `consequence_mass_traced`. [V] doc at lines 486-514, signatures at
  516 and 606. Requires the `alloc` feature [R].
- **T04** `bcinr-cmca/src/allocator/mod.rs`, `allocation_receipt.rs`. Rust. Fixed-shape
  allocator; receipt seal and recompute-verify. [V] docs at allocation_receipt.rs:1-45 and
  allocator/mod.rs:2410-2420; `#![deny(unsafe_code)]` at lib.rs:132; version 26.9.15.
- **T05** `wasm4pm/crates/wasm4pm-cmca`. Rust to WASM. Boundary over
  `allocate_single_lens`. [V] `AUTHORITY = "CONSTRUCT_ONLY"`; pins bcinr rev b76dcb37,
  package version const 26.7.28; `find` found no built cmca `.wasm` [X].
- **T06** `bcinr-cmca/src/bin/cmca_rank_cli.rs`, `cmca_allocate_cli.rs`. Rust CLIs, stdin
  and stdout JSON. [V] rank CLI header (compile-time N=8, K=4, Q=4; CMCA-108). Request
  schema beyond the header [R].
- **T07** `bcinr/crates/bcinr-pddl/src/resource_ledger.rs`, `cmca_execution.rs`. Rust.
  [V] resource_ledger is an interval-lease conflict ledger with `f64` half-open intervals,
  not a budget ledger. cmca_execution seals and recomputes a CMCA-driven priority map.
- **T08** `ash_a2a/lib/ash_a2a/semantic/allocator.ex` (`Allocator`, `Allocator.Budget`).
  Elixir. [V] moduledoc lines 1-56: issuer-set ceilings and minimums, no ceiling-raising
  path, `reissue/3` requires non-model issuer. Function bodies [R].
- **T09** `gymact/src/gymact/explore_sequential_acquisition/cmca.py`. Python. [V] header
  and `CMCAPlan.__post_init__`: shares must sum to exactly `Fraction(1)`
  (`REFUSED_CMCA_SHARE_NOT_CLOSED`); allocated cost, latency and samples above the source
  budget refuse (`REFUSED_CMCA_COST_EXCEEDED`, `_LATENCY_`, `_SAMPLES_`); integer apportion
  for latency and samples. One level only, not recursive. `test_cmca.py` exists [R].
- **T10** `dteam/capabilities/dteam-kernel` (`quota.rs`, `ledger.rs`, `hash.rs`). Rust,
  std-only. [V] quota.rs header and `reserve` (line 711, atomic all-or-nothing, idempotent
  by request id and digest). `hash.rs` is a hand-rolled SHA-256: not endorsed for reuse;
  `:crypto` is available. Ledger chain and saga [R].
- **T11** `ash_a2a/lib/ash_a2a/capability_release.ex` and `mix.exs:376`. Elixir. [V]
  `portable_digest/1` at :336 uses `Jcs.encode` then sha256 (:355-356); `{:jcs, "~> 0.2"}`.
- **T12** `ash_a2a/priv/sa2a_conformance_vectors/v001..v009`. JSON and Turtle. [V] listing:
  nine RDF-graph vectors, no JCS or receipt-digest vectors.
- **T13** `ggen/crates/ggen-engine/src/portable_receipt.rs`, `pack.rs`; `ggen-config/src/
  receipt/envelope.rs`; `ggen-marketplace/.../pki.rs`. Rust. [V] portable_receipt.rs header: a
  separate portable envelope beside the BLAKE3 chain receipt (RFC-GPACK-001 s56); zero
  `Ed25519` hits in that file, so an Ed25519 envelope claim there is UNVERIFIABLE (earlier
  draft claim withdrawn). `pki.rs:37-39` `revoked_keys: Vec<String>`, no epoch [V]. The
  `envelope.rs` and `pack.rs` contents [R].
- **T14** `ash_a2a/native/graphlaw_host`. Rust, Wasmtime `=48.0.1`, sha2 `=0.10.9`.
  Pure-function WASM evaluator: argv job file, JSON out, `wasm_sha256` in every reply. [V]
  main.rs header and Cargo.toml. No claim store, signature check or authority. Offers a
  pattern (identity-in-reply, job file, out-of-process), not enforcement code. WASI
  capability setup not read, so "capability-less" is UNVERIFIED.
- **T15** `ash_a2a/k8s` (deployment, network-policy, verify_network_isolation.sh). YAML.
  [V] runAsNonRoot :63, seccompProfile :68, readOnlyRootFilesystem :100, drop ALL :102;
  network-policy.yaml header states default-deny. Hardening baseline for the existing
  single workload only: no separate authority or actuator pod, namespace or Secret
  custody is configured. The egress script was not run.
- **T16** `castle/src/v26_8_18/crypto.rs`. Rust. Real `ml-dsa 0.1.1` and `slh-dsa
  0.2.0-rc.5` signing and verifying, dual BLAKE3 and SHA-256 identity. [V] lines 3,
  108-172; Cargo.toml:23-26. slh-dsa is a release candidate crate.
- **T17** `affidavit` (`src/1000x_post_quantum_sealing.rs`, `chain.rs`, `verifier.rs`,
  `admission.rs`, `deny.toml`). Rust. [V] PQ file uses `mock_dilithium_sign` and
  `mock_kyber_encapsulate`; Cargo.toml:194 `pqc = []` (empty opt-in feature); lib.rs:138
  gates the module with `#[cfg(feature = "pqc")]`, so it is not compiled by default.
  Chain and verifier [R].
- **T18** OTP 28 `:crypto` on this host, OpenSSL 3.6.4. [X] `crypto:supports()` lists
  `mldsa44/65/87`, `eddsa` and `slh_dsa_*`. ML-DSA-65 sign, verify and tamper-refuse
  round trip succeeded (signature 3309 bytes).
- **T19** `praxis/crates/praxis-core/src/signing.rs`. Rust. Ed25519 over a chain hash. [V]
  header: key from `PRAXIS_SIGNING_KEY` or `PRAXIS_SIGNING_KEY_FILE`.
- **T20** `osx-clnr/src/domain/crypto.rs`, `integration/config.rs`. Rust. HMAC-SHA256 plan
  approval, constant-time verify. [V] `verify_hmac_sha256` at crypto.rs:93; key file
  `~/.oclnr/approval.key` at config.rs:32,68.
- **T21** `autofde-lab/src/autofde_lab/sa2a/brce/boundary.py`, `authority/broker.py`. Python.
  In-process reference boundary: PreparedReceipt before DO, idempotency-token replay with
  identity (action, target) checks. [V] boundary.py header and lines 53-77; it gives a
  design pattern, no independent enforcement. broker.py and AFDE-2604 findings [R].
- **T22** `xaas/lib/xaas/actuation.ex`. Elixir/Ash. [V] `prepare_external`, `checkpoint_
  external`, `seal_external` exist (lines 45, 88, 120). Each runs in a transaction and threads a
  required non-empty `idempotency_key` (refuses
  `:idempotency_key_required`, lines 110-188) [V]. Crash-window semantics [R]. A reference,
  not a fence enforced by an independent actuator.
- **T23** `ash_a2a/lib/ash_a2a/chicago/abstract_code.ex`, `chicago/collaborators.ex`,
  `semantic/conformance.ex`. Elixir. [V] abstract_code.ex `calls_by_function` and
  `reachable` (closure follows only `{:local, f, a}`); conformance.ex `dynamic_call_sites`
  (:1868-1935). collaborators `calls_into` [R].
- **T24** `ggen-marketplace/packs/{sa2a-bridge-pack,dfcm-pack,supply-chain-evidence-pack,
  receipt-provenance-unification-pack}`. RDF, SPARQL, templates. [V] directory listings
  only (sa2a-bridge gates 010-080 named). Contents [R].
- **T25** `engineering-standards/process/authority-and-actuation.md`. Markdown. [V] exists;
  content [R].
- **T26** `ash_a2a/.github/workflows/release.yml`. Actions YAML. [V] `mix hex.audit` :71,
  mix_sbom :93, cargo-cyclonedx :97, `attest-build-provenance` :103, `attest-sbom` :107.
- **T27** `beam4pm/lib/beam4pm_receipt_chain.ex`. Elixir. Lead only: reported as an
  unauthenticated sha256 chain; no `hmac` hit in the file, remainder unread. [V] exists;
  behavior [R], UNVERIFIABLE until the hash function is read.
- **T28** `bcinr/crates/bcinr-mfw-ir/src/digest.rs`, `bcinr-powl/src/receipt/chain.rs`,
  `bcinr-logic/src/ct.rs`. Rust. BLAKE3 Digest, fold chain, constant-time helpers. [R]
- **T29** `erlmcp`, `A2A` (Erlang), `a2a-rs` (Rust). Sibling A2A stacks. [R]
- **T30** `teleport/ggen/crates/ggen-core/src/pqc.rs`. Rust. `pqcrypto_mldsa` mldsa65
  keypair, sign, open (PQClean-backed; module doc says Dilithium3). [V] header; a second,
  independent ML-DSA implementation for cross-implementation vectors.
- **T31** `erlmcp/apps/swarmflow_pqchain.disabled` (`c_src/pqc_rust_nif.rs`, consensus
  modules). Rust NIF for ML-DSA keygen, sign, verify, batch_verify. [V] directory and
  `c_src` exist; app is disabled and Erlang sources reported broken [R]. A NIF: kernel
  ineligible (RFC-006 s23). Design input only.
- **T32** `ggen-broker/crates/{ggen-broker,ggen-law,ggen-rpc,ggen-state}`. Rust
  workspace, "Admission Engine Broker". [V] crate list only; a signing grep found none [R].
  Broker skeleton, no signing evidence.
- **T33** `teleport/knhk/rust/knhk-admission/src/lib.rs`. Rust. [V] stage 3 verifies an
  optional payload signature with `pqcrypto_dilithium` dilithium5 (lines ~399-454, length
  checks). Payload signature only: no exact-effect certificate, expiry or algorithm id in
  signed bytes [R]. Candidate reference for A23 and A25.
- **T34** `affidavit/docs/roadmap/W8-cryptography-trust.md`. Plan, not code. [V] a
  `SignatureSuite` enum (`Ed25519`, hybrid `Ed25519MlDsa65`, `MlDsa65`) with the note that
  every signature self-describes its suite (crypto-agility). Design reference for A25.
- **T35** `xaas/lib/xaas/gall/{checkpoint,checkpoint_binding}.ex`. Elixir. [V] exist; not
  read. Candidates for A18 and A30; grep found no generation or fencing-token check [R].
- **T36** `xaas/receipts/v26.9.23/R1-X-FENCE.gate`. [V] directory of CI logs
  (actionlint, compile); per report a GitHub Actions job-condition fence, unrelated to an
  execution-generation fence. Negative control only.
- **T37** `gymact/rust/crown`. Rust. [V] header: "powerless", models admission and standing,
  exposes no actuator (`BRCE_ONLY_DO_PATH`). Not an actuator reference.
- **T38** `chatman-ecosystem/crates/ecosystem-runtime`. Rust, sqlx over SQLite, `Conflict`
  error. [V] header lines only; whether it holds claim or fence logic is UNVERIFIED.

## 3. Summary table

| # | Family | Verdict | Primary substrate | Sections |
|---|---|---|---|---|
| F1 | BEAM/OTP fault containment | REUSE | T01 T02 | 4 8 23 |
| F2 | CMCA resource containment | EXTEND | T08 T03 | 8 28 |
| F3 | Exact identity, canonical encoding | EXTEND | T11 T12 | 9 10 |
| F4 | Effect instance and claim | EXTEND | T01 | 9 12 |
| F5 | PreparedEffect, durable store | EXTEND | T01 | 11 12 |
| F6 | External authority, certificate | INVENT | T18 (primitive) | 13 |
| F7 | Post-quantum signatures | REUSE | T18 | 14 |
| F8 | Multi-authority k-of-n | INVENT | T18 (primitive) | 15 |
| F9 | Final fence and actuator | INVENT | T14 (host) | 16 |
| F10 | No ambient credentials, isolation | COMPOSE | T15 | 3 17 |
| F11 | Mediation, closure court | EXTEND | T23 | 18 27 |
| F12 | Confused deputy | EXTEND | T01 | 19 |
| F13 | Replay, unknown outcome | EXTEND | T01 T22 | 20 21 |
| F14 | Dangerous primitives | EXTEND | T01 T14 | 22 23 |
| F15 | Receipts, verification | COMPOSE | T01 T18 | 25 |
| F16 | CWE, fault, resource courts | EXTEND | T23 | 26 28-30 |
| F17 | Supply chain | REUSE | T26 | RFC-005 s7 |

Family-level counts: REUSE 3, COMPOSE 2, EXTEND 9, INVENT 3 (total 17). Atomic counts are in
section 6.

## 4. Requirement-family map

Each family lists: found, verdict and reason, lost if reimplemented, integration path,
falsifier. "Kernel" means the trusted BEAM code of RFC-005 section 3.

### F1 BEAM/OTP fault containment (RFC-006 s4, s23)

- **Found:** T01 flat `one_for_one` tree, bounded `Task.Supervisor`, Oban delivery
  (`delivery/oban.ex` [R]), EKV stores, reconciler; T02 TLS distribution. [V] partial.
- **Verdict REUSE** (A01 A02 A03) and EXTEND for the kill switch (A04). RFC section 4 bans
  agent-specific supervision layers without a falsifier. `AshA2A.KillSwitch` is a custom
  halt primitive: it needs the section 4 falsifier (OTP `terminate_child` or app stop is
  insufficient because trip must be authority-free and reset authority-gated, per its
  moduledoc [R]).
- **Lost if reimplemented:** boot-time refusal when durability is required, the shed-not-
  fan-out egress bound, ledger-key seeding before the first seal [R, T01].
- **Integration:** in-VM; no new dependency. Restart-intensity per child is configuration.
  T02 options move into the release the actuator and authority ship in.
- **Falsifier:** a fault-injection run (L20 courts) where a killed child causes a second
  consequence, or where dist TLS can be bypassed via `SWARM_DIST_TLS=false` in a profile
  that claims C2. Note T02 hardening lives only in `swarm/`, not in the library.

### F2 CMCA resource containment (s8, s28)

- **Found:** T08 flat budget with issuer-set limits; T03 share cascade with one-sided
  floor conservation; T04 receipts; T05 and T06 cross-runtime entry points; T07 and T10 as
  lease and quota references; T09 a flat checked budget split. See section 5.
- **Verdict EXTEND** (A06 A07) with COMPOSE for the optional share kernel (A05 A08).
  No recursive tree budget split exists under `~`. `gymact` cmca.py (T09) is a flat,
  one-level checked split: exact rationals, integer apportion, refusal on overflow. It is
  Python, so it serves as a reference oracle or differential test for `Budget.split/2`, not
  as reusable kernel code. The smallest correct move is `Budget.split/2` in T08 using
  integer floor arithmetic (`floor(share * B_parent)`), with the conservation asserted in
  Elixir, outside CMCA. L17 already says to reuse `Semantic.Allocator.Budget`.
- **Lost if reimplemented:** Q16.16 one-sided truncation (never manufactures mass), the
  refusal taxonomy, mutant-kill and Lean-correspondence tests in T04 [R]; in T08 the
  structural absence of a ceiling-raising path and issuer-set minimums [V].
- **Integration:** T08 in-VM. If CMCA share selection is wanted, run T06 as a short-lived
  OS process from a non-kernel caller (not a kernel `Port`), or a T05 export via the T14
  host pattern. Never in the kernel.
- **Falsifier:** a StreamData property (dependency present, mix.exs:312) over random spawn
  trees where `sum(child limits) > parent limit` after `split/2`, or where recursion
  raises total admitted allocation. Also: a T06 differential run showing Elixir splits
  exceed the cascade `child_sum` for the same tree, and a T09 differential run on a
  one-level tree where the Elixir split violates a T09 refusal condition.

### F3 Exact identity and canonical encoding (s9, s10)

- **Found:** T11 RFC 8785 JCS plus SHA-256 in `portable_digest`; `rdf ~> 3.0.1` RDFC-1.0
  per mix.exs comments [R]; T12 vector layout. Ten or more sites still digest
  `:erlang.term_to_binary` (49 grep hits in `lib/`; spg_conformance.ex:465, command.ex:117,
  actuation.ex:112, execution_snapshot.ex:283/319 and others use `[:deterministic]`);
  authority.ex:130, planning.ex:26, receipt_outbox.ex:130 use non-deterministic
  term_to_binary [R].
- **Verdict EXTEND** (A09 A10 A11) and COMPOSE for an independent verifier (A12). The
  encoder already exists; the gap is coverage and cross-runtime vectors. L01 and L02 own
  this.
- **Lost if reimplemented:** the strings-only payload in T11 never exercises JCS number
  rules (ES6 float serialization, UTF-16 key order), so a new scheme would inherit that
  blind spot; generalizing must add the RFC 8785 appendix vectors, not a new encoding.
- **Integration:** `AshA2A.Wire.Jcs` (L18 already names `wire/jcs.ex`) over the `jcs` hex
  package. Independent check in Rust with `serde_json_canonicalizer` in a test-only crate
  under `native/`. That crate is external and not found under `~` [D].
- **Falsifier:** any RFC 8785 vector (non-BMP key, exponent floats) where `Jcs.encode`
  output differs from the Rust canonicalizer, or a PreparedEffect digest that changes when
  atom vs string keys are swapped.

### F4 Effect instance and claim (s9, s12)

- **Found:** request claim by id and fingerprint (`command_bus.ex:203-223`) and optional
  `confirm_claim/3` (:471) per RFC-005 G8 [R]; optional store callbacks `claim_actuation`,
  `commit_actuation`, `release_actuation` [R]; T22 idempotency-key pattern [V]; T35 gall checkpoint
  modules unread; T21
  token-to-(action,target) refusal [R]; `zcode-cli/src/gall-work.ts` lease with
  idempotency key and epoch [R].
- **Verdict EXTEND** (A13 A14) and **INVENT** (A15 fencing token checked by the actuator,
  A16 revocation and policy-epoch state). No artifact under `~` has an actuator-checked
  execution generation; `ggen pki.rs:37-39` revoked-key list [V] covers keys only, not epochs.
  L10 owns `receipt_store/generation.ex` and `effect_claim.ex` on the control-plane side.
- **Lost if reimplemented:** RFC-004 order REQUEST_CLAIMED before EFFECT_CLAIMED; the
  "request claim is a non-authoritative index" rule (L10 rules) [V].
- **Integration:** control-plane half in-VM (L10). The actuator half is a separate store
  (see F9). The generation token is a monotonic integer minted by the claim store and
  carried inside PreparedEffect.
- **Falsifier:** two attempts with different request ids and one `effect_instance_id`
  yield two DOs; or a stale-generation attempt is accepted by the actuator.

### F5 PreparedEffect and durable store (s11, s12)

- **Found:** durable journal and outbox with `[:safe]` decode (T01); ExecutionSnapshot and
  ConditionalCommitment digests [R]; T21 and T22 prepared-before-DO protocols [R].
- **Verdict EXTEND** (A17 A18 A19). RFC-005 G2/G3 (process-local anchor, unkeyed default
  journal) are the gap [V, RFC-005 s12]. L04 owns `PreparedEffect` and `PreparedEffectStore`.
- **Lost if reimplemented:** crash-window reconciliation (`maybe_reconcile_outbox`) and
  the unknown-outcome outer-seal recovery of T22 [R]; `[:safe]` decode still admits atoms
  that already exist, so it is not an untrusted-data guarantee [D].
- **Integration:** in-VM over EKV; wire form JCS (F3), never ETF, for anything the
  actuator reads.
- **Falsifier:** kill the node between prepare and DO; restart produces a second DO or a
  PreparedEffect the actuator accepts that is absent from the store.

### F6 External authority and ActuationCertificate (s13, 7.4)

- **Found:** no independent authority service under `~` (lane report [R]; T32 broker has no
  signing, T33 verifies a payload signature only). In-process BRCE: T21 (in-process
  reference boundary), T22, `gymact/src/gymact/brce.py` (import-time
  seal constant, a convention, [R]). Signing primitives exist: T18 [X], T19 and T20 [V] as
  counterexamples (env key, same-user key file).
- **Verdict INVENT** for A21 (certificate schema over the PreparedEffect digest with
  algorithm id inside the signed bytes) and A22 (issue-only process outside the control
  plane), REUSE for A20 (Ed25519 via `:crypto`), EXTEND for A23 (Elixir `AuthorityClient`
  over the `authority/broker` behaviour that L11 already reshapes). The design input is
  "sign a digest" plus in-toto or COSE style envelopes [D, external, unread].
- **Lost if reimplemented:** T25 vocabulary (typed REFUSED, UNSUPPORTED, BLOCKED; hooks
  never manufacture authority) [R]; T21 replay-mismatch refusals [R].
- **Integration:** AuthorityService is its own OS process and release, holding keys the
  control plane cannot read. The control plane holds only a public-key set and a client.
  Elixir on OTP 28 suffices (T18); no NIF, no `Port` from the kernel. Transport: mTLS
  over a Unix socket or pod network, request body JCS bytes.
- **Falsifier:** a control-plane process with full env and filesystem access obtains a
  certificate for a mutated field of an admitted PreparedEffect; or the certificate
  verifies after any single field of E changes.

### F7 Post-quantum signatures (s14)

- **Found:** T18 [X]: ML-DSA-44/65/87 and SLH-DSA through OTP `:crypto` on OTP 28 with
  OpenSSL 3.6.4; round trip verified. T16 [V] real FIPS 204/205 crates as a Rust option; T30 [V]
  `pqcrypto_mldsa` as a second
  independent implementation; T31 a disabled NIF (not eligible). T17 [V] PQ sealing is a
  mock, behind the empty opt-in `pqc` feature. SLH-DSA and `eddsa` support in T18 were not
  re-executed by the audit, so those parts of T18 are UNVERIFIED here.
- **Verdict REUSE** (A24) plus EXTEND for the algorithm registry bound into the signed
  object (A25); T34 supplies a suite-enum design reference (plan only). This supersedes the search
  lane's "no NIF-free PQ path": on this host
  none is needed. The RFC forbids a proprietary scheme; using OpenSSL's implementations
  honors that.
- **Lost if reimplemented:** FIPS 204/205 correctness and side-channel work sits in
  OpenSSL; T16's rule that the trust root is never inferred and suites are qualified by
  an explicit gate [R].
- **Integration:** `:crypto.sign/verify` inside the authority and actuator processes and
  the verifier library. Deployment image must be OTP 28 with OpenSSL 3.5 or later.
- **Falsifier:** the release image (swarm/Dockerfile, digest-pinned bases) lacks
  `mldsa65` in `crypto:supports()`; or a Rust-side verifier (T16) rejects a signature
  produced by `:crypto` for the same message (cross-implementation vector; T16 and T30 are
  two independent verifiers to try).

### F8 Multi-authority k-of-n (s15)

- **Found:** no cryptographic k-of-n signature verifier located; keyword hits (multisig,
  threshold, quorum, FROST, Shamir) were not inspected beyond one sample (castle
  `board.rs` `threshold` is a materiality threshold, unrelated). erlmcp consensus material
  (`docs/BYZANTINE_FAULT_TOLERANCE_ANALYSIS.md`, T31) is design docs and disabled code.
  This is NOT a verified negative and is not counted as one in section 6. T16 has
  single-signer suites.
- **Verdict INVENT** (A26 verifier requiring at least k valid signatures from distinct
  admitted signers; A27 signer-independence court). RFC-006 section 15 itself prefers
  plain multiple standardized signatures over threshold cryptography, which reduces this
  to a bounded verify loop over T18 primitives plus a registry of independent key
  holders.
- **Lost if reimplemented:** nothing from `~`; the constraint to keep is "algorithm
  identity is bound into the signed object" (F7) and distinct-signer counting.
- **Integration:** library used by the actuator process; signer registry is signed
  configuration owned by the actuator, not the control plane.
- **Falsifier:** one signer submitting k signatures under aliases, or k-1 valid
  signatures plus one malformed accepted by a lenient decoder.

### F9 Final fence and actuator (s16, 7.5)

- **Found:** T14 shows a minimal out-of-process pattern (Wasmtime, job file, identity in
  reply) [V]; it contains no enforcement code, and T37 gymact crown is explicitly
  powerless. T36 is not a fencing token. Recompute-and-refuse verification pattern in T04
  (`verify_allocation_receipt`) [V]. `dteam-kernel` quota `reserve` and ledger `by_intent`
  as claim-store references [V/R]. oclnr plan-approved actuation is a precedent, same-user
  key [V].
- **Verdict INVENT** for A29 (the sixteen section 16 checks as one fail-closed
  function, including prior-completion and execution-generation), INVENT for A28 (actuator host:
  the T14 pattern is copied, no T14 code is extended; or an Elixir release with a single
  effector), COMPOSE for A30
  (actuator-local transactional claim and completion store; a mature embedded database,
  not found under `~`, external [D]).
- **Lost if reimplemented:** T14's artifact-identity-in-every-reply and job-file pattern;
  T04's one-typed-refusal-per-check and cycle-rejection-before-table-build [V].
- **Integration:** separate OS process, ideally its own pod (T15 profile), with no LLM,
  no planner, no dynamic code and one narrow effector per capability. Control plane can
  submit only `(PreparedEffect bytes, certificate bytes)`.
- **Falsifier:** any of the sixteen checks removed and the corresponding forged input
  still produces DO (mutation per check); or the actuator accepts a certificate it can
  only validate by calling back into the control plane.

### F10 No ambient credentials and isolation (s3, s17)

Label: baseline reuse, isolation topology new.

- **Found:** T15 hardening baseline for the existing single workload (not authority or
  actuator isolation) and default-deny NetworkPolicy [V]; verify script [R];
  clnrm and ggen gVisor material is design-only (network isolation marked pending in
  clnrm; ggen `Dockerfile.gvisor` can skip building runsc) [R]. No Firecracker, Extism or
  macOS sandbox profile found. Counterexamples of ambient credentials: T19, T20,
  `zcode-cli` `XAAS_MCP_TOKEN` env [R].
- **Verdict COMPOSE** (A31 A32) and EXTEND (A33: `authority/security_preflight.ex` [R]
  gains a check that no protected key material is readable in the control-plane
  environment or filesystem).
- **Lost if reimplemented:** the egress falsifier script and per-destination overlay
  convention; seccomp and capability-drop baseline [V/R].
- **Integration:** deployment only: authority and actuator pods in a separate namespace;
  key Secrets mounted only there; control-plane service accounts have no read on them.
- **Falsifier:** from a shell inside the control-plane pod, read any signing key or reach
  the actuator's key store; or `verify_network_isolation.sh` fails its negative control.

### F11 Complete mediation and architecture closure court (s18, s27)

- **Found:** T23 reads BEAM debug_info and classifies calls including dynamic ones, fails
  closed on `:no_debug_info` [V]; `reachable/2` stops at module boundaries [V]. Current
  architecture check is regex over source (`architecture_verifier/adapters.ex:248-256`
  [R]); no `:xref` use in `lib/` or `mix.exs` [R]. L20 already specifies `mix xref graph
  --sink` plus alias/import/apply literal resolution [V, _LANES.md:416].
- **Verdict EXTEND** (A34 A35 A36). Two independent extractors (T23 closure and `:xref`)
  give an anti-vacuity cross-check. Dynamic sites are unresolved edges and must refuse.
- **Lost if reimplemented:** the "reads the loaded BEAM" property and fail-closed
  treatment of dynamic sites; the regression test documenting a vacuous `:met`
  (`semantic_conformance_dynamic_call_sites_test.exs`) [R].
- **Integration:** mix task in the courts lane (L20); no runtime dependency.
- **Falsifier:** a scratch module that calls `Ash.create` or `Req.post` outside the
  kernel does not fail the court; or a dynamic `apply` to an effector is not reported.

### F12 Confused-deputy resistance (s19)

- **Found:** `transport/principal.ex`, `ownership.ex`, `identity.ex` per RFC-005 CWE table
  [R]; `Authority.new/3` in-BEAM open constructor is RFC-005 G1 [V, RFC-005 s12].
- **Verdict EXTEND** (A37 carry principal unchanged into PreparedEffect and certificate)
  and **INVENT** (A38 bounded, provenance-preserving delegation that cannot amplify).
  Capability attenuation is a known design pattern [D, external]; no implementation
  under `~`.
- **Lost if reimplemented:** per-capability grants and ownership refusals (CWE-639/642
  rows in RFC-005, PRESENT_GUARDED) [R].
- **Integration:** in-VM; principal identity is a field of the JCS-encoded PreparedEffect
  and is re-checked by the actuator against the certificate.
- **Falsifier:** an intermediary service identity substituted for the initiating
  principal still yields a valid certificate and DO.

### F13 Replay and unknown outcome (s20, s21)

- **Found:** `ReceiptOutbox.Reconciler` and crash-window tests [R]; T22 three-commit
  external protocol [V names]; `ggen` `receipt_chain_own_history_replay` test [R]; L10
  defines `replay_evidence.ex` and `effect_outcome.ex` [V].
- **Verdict EXTEND** (A39 A40). Replay as evidence retrieval and the `:unknown_outcome`
  terminal state with no automatic retry are L10 scope.
- **Lost if reimplemented:** compensation-under-separate-authority shape (ggen_igniter
  receipt compensation record [R]) and T21 "Mutation E" crash window [R].
- **Integration:** in-VM; the actuator also refuses a second DO for a completed effect
  instance, so replay safety does not rest on the control plane alone.
- **Falsifier:** crash during uncertain DO, restart, and the same effect instance is
  retried automatically; or replay returns a fresh execution instead of prior evidence.

### F14 Dangerous-primitive elimination (s22, s23)

- **Found (all [V] at the line):** `apply(module, function, ...)` on a DSL MFA at
  agent.ex:1258 guarded by `is_atom` only; literal-module applies at planning.ex:121,
  extended_card.ex:90, semantic_projection.ex:70, conformance.ex:217; `{:wasmex, "~>
  0.15.1"}` Rustler NIF at mix.exs:400; `System.cmd` sites and `String.to_atom` sites per
  RFC-005 [R]. T14 already hosts Wasmtime outside the VM [V].
- **Verdict EXTEND** (A41 A42 A43 A44 A45) and COMPOSE (A46: move the wasmex host out of
  the kernel boundary or document it as non-kernel). L13, L14, L15 own these.
- **Lost if reimplemented:** `GraphLaw` isolation limits (fuel, memory, 1 s deadline
  [R]); argv-form `System.cmd` (no shell) [R].
- **Integration:** closed registry of `{module, function}` declared at compile time;
  typed capability structs; no runtime protocol value names a module or path.
- **Falsifier:** a protocol-reachable value causes `apply/3` on an attacker-chosen module,
  or an atom is created from wire input (L20 per-site allowlist court).

### F15 Receipts and verification (s25)

- **Found:** HMAC-SHA256 keyed receipts, constant-time compare (T01 [V]); predecessor
  chains without MAC in T27 [R] and T28 [R]; T13 envelope is BLAKE3-chain adjacent, Ed25519
  UNVERIFIABLE; read-only
  validator pack (`receipt-provenance-unification-pack`, four allowed argv prefixes) [R];
  affidavit verifier [R, unread]. No Elixir receipt was found with both predecessor and
  authenticated
  integrity: a lead (UNVERIFIABLE), since no repo-wide sweep of receipt types was run.
- **Verdict COMPOSE** (A47 signed receipts across boundaries via T18, A49 independent
  verifier) and EXTEND (A48 predecessor field, A50 standing derived not stored; L18, L19).
- **Lost if reimplemented:** chain scope and torn-write handling in T27 [R]; the
  "canonical bytes exclude prior hash and hash" rule of T28 [R]; validator's double
  refusal (gate time and run time) [R].
- **Integration:** signing in the actuator and authority; the control-plane store keeps
  bytes it cannot forge. Verification by a separate CLI (Elixir escript or T17) reading
  JCS receipts.
- **Falsifier:** a receipt edited by a control-plane writer verifies; or a receipt whose
  predecessor is omitted or reordered verifies.

### F16 CWE, fault-injection and resource courts (s26-s30)

- **Found:** `priv/sa2a/chicago_mandatory_corpus.json` and courts (T23 neighbors) [R];
  `command_bus_crash_window_chicago` and real `:peer` multinode tests [R]; `stream_data`
  dependency [V mix.exs:312]; RFC-005 CWE table with code state per row [V]; mutation
  task `mix ash_a2a.chicago.mutate` [R].
- **Verdict EXTEND** (A51 A52 A54), COMPOSE (A53), REUSE (A55, [R]).
- **Lost if reimplemented:** anti-vacuity discipline (revert-mutation must fail
  acceptance) and named positive controls.
- **Integration:** mix tasks and corpus entries (L20); each section 26 attack is one
  corpus entry with an expected refusal code from L03.
- **Falsifier:** a corpus entry that passes with its mutation applied (vacuous court).

### F17 Supply chain (RFC-005 s7; RFC-006 s30 scope)

- **Found:** T26 hex.audit, CycloneDX for Hex and native crates, SLSA provenance and SBOM
  attestation, SHA-pinned actions [V]. `.github/cargo-deny.toml` [V] denies yanked crates and
  allowlists licenses and sources; ci.yml:41-51 [V] installs cargo-deny 0.20.2 and runs
  `check advisories bans licenses sources` for `native/hddl_cli` and
  `native/graphlaw_host`. Gaps [R]: no sobelow or mix_audit, no attestation verification
  step, no secrets scanner (grep found no gitleaks or trufflehog), no consumer of
  `supply-chain-evidence-pack`. The earlier "no deny.toml" gap is CONTRADICTED.
- **Verdict REUSE** (A56 A57) with COMPOSE for the gaps (A58 A59).
- **Lost if reimplemented:** attested-subject checksum equality refusal before publish
  [R]; the pack's data-only, no-authority rule on court mutations [R].
- **Integration:** CI only.
- **Falsifier:** a tampered dependency or SBOM entry passes CI; an attestation is never
  verified by any consumer.

## 5. bcinr and CMCA

### 5.1 What CMCA is in code

`bcinr/crates/bcinr-cmca` v26.9.15 [V Cargo.toml]. Rust, `#![deny(unsafe_code)]`
(lib.rs:132) [V]. Acronym in the crate docs: "Chatman Multifractal Consequence
Allocation" (lib.rs:1). The older "Covariance Monitoring and Calibration Assessment"
expansion is marked superseded in `bcinr/docs/CMCA_EXPLANATION.md` (repo-root relative
link, file exists) [V]. The earlier "dangling doc link" claim was wrong and is deleted.

It is a deterministic Q16.16 fixed-point kernel that distributes unit-normalised mass over
an object tree under lens exponents. Two entry points matter:

- `allocator::allocate` and `allocate_single_lens`: compile-time shape N=8, K=4, Q=4
  (CMCA-108, stated in the rank CLI header) [V]. Output components sum "approximately" to
  ONE; a documented fallback regime returns a subnormalized vector (allocator/mod.rs:2410-
  2420) [V].
- `cascade::consequence_mass(tree, lenses)` and `consequence_mass_traced`: arbitrary
  tree, `alloc` feature, per-node trace `AllocationStep` with `input_share`,
  `child_shares`, `child_sum` [V].

### 5.2 How `sum(children) <= parent` is enforced

Only in `cascade.rs`, and only for flows, not budgets. The doc (lines 486-514) claims
`child_sum(v) <= input_share(v)` "always", argued from truncating `saturating_div` and
`saturating_mul` on an exact partition of 1, plus a test corpus (18 fixtures and a
stress corpus at arities 2..=20, `tests/cascade_residual_classification.rs`). The
residual is one-sided and bounded by `2 * children.len()` "empirically-robust" and
explicitly "not a tight closed-form bound" [V doc; test not run]. It is neither a
type-level invariant nor a runtime check: nothing in `consequence_mass` refuses on
violation. The allocator path has no such guarantee (5.1).

### 5.3 API, receipts, certificates

- Receipts: `seal_allocation_receipt` and `verify_allocation_receipt` (allocation_
  receipt.rs). Verify recomputes the share from bindings and refuses on
  `InputsDigestMismatch`, `ShareMismatch` or a cyclic parent [V doc]. The digest is
  `mix64`, a 64-bit splitmix-style finalizer; the docs say "not a cryptographic
  tamper-evidence guarantee" and "an audit aid, not a security boundary" [V].
- Certificates: `certification.rs` and `proposal.rs` (learning permission, dwell time).
  The seven authority-named types are `#[deprecated]` and `#[doc(hidden)]` pending
  CMCA-102 [R]. They govern adaptive-state mutation, not effects.
- Cross-runtime: T05 (single lens only, pinned to 26.7.28, no built `.wasm` found) and
  T06 (CLIs; rank CLI reinterprets the four measure slots as caller axes, max 8
  candidates) [V headers]. No Elixir, NIF or Port binding exists [R].
- Elixir side: `Semantic.Allocator.Budget` (T08) already carries limits, minimums,
  consumed, issuer and fingerprint; `chicago/courts/unknown.ex` has a `cmca_result`
  hook (lines 451, 510-513) [V grep], with no bcinr call behind it [R].

### 5.4 Does it satisfy RFC-006 section 8

No, not by itself. It satisfies the allocation and replay clauses partially and none of
the budget-cap clauses. Verdict split: COMPOSE for the share kernel (optional), EXTEND for
the budget ledger in T08 (required).

### 5.5 CONTRADICTED: RFC-006 section 8 (and section 6, 10, 28) versus the code

1. **`sum(B_children) <= B_p` as a budget law.** Code conserves normalised shares in
   Q16.16, not budgets; `allocate` sums only approximately to ONE, with a subnormalized
   fallback. [V]
2. **`Cost(effect) <= B_admitted`.** No such check anywhere in bcinr-cmca. The only
   ceiling and consumption accounting is T08 in ash_a2a. [V moduledoc; bcinr grep by lane R]
3. **Arbitrary recursion, delegation, spawn (section 28).** `allocate` is fixed to N=8,
   K=4, Q=4. Only `cascade` takes an arbitrary tree, and it needs `alloc`. [V]
4. **Conservation as a MUST with refusal (section 28: "MUST refuse or normalize").** The
   cascade property is a documented, tested truncation effect; there is no refusal path
   for a violation, and the bound on the residual is empirical. [V]
5. **FIPS-approved digest (section 10).** CMCA receipts use `mix64`; BLAKE3 appears only
   as a dev-dependency (artifact.rs:13) and is not on the FIPS list [V for mix64 and
   dev-dep; the FIPS status of BLAKE3 is general knowledge, [D]].
6. **Replayable from admitted inputs and configuration identity.** Partly true:
   recompute-verify exists, but the digest is non-cryptographic and the fixed-shape
   generator identity (`GENERATOR_SOURCE_DIGEST`, `RDF_INPUT_DIGEST`, imported in T05)
   binds only the fixture. [V import list]
7. **CMCA "MUST NOT issue actuation authority".** bcinr-cmca contains types named
   authority (CertifiedLearning and others). They are deprecated and hidden and concern
   learning permission; they do not issue actuation authority, but the naming collides
   with RFC vocabulary. [R]
8. **Version identity.** T05 reports `BCINR_CMCA_VERSION = "26.7.28"` and pins rev
   b76dcb37 while the tree is 26.9.15. Any replay identity taken from T05 refers to the
   older kernel. [V]
9. **Name (downgraded).** The crate's own explanation doc marks the older expansion as
   superseded and reconciles it; this is not a contradiction. Cite the canonical
   expansion only. [V]

### 5.6 Nearest budget-side prior art (corrected)

The search lane suggested `bcinr-pddl/resource_ledger.rs` as the likely budget ledger.
Read: it is an interval-lease conflict ledger (exclusive or shared capacity over
half-open `f64` time intervals, `request_lease`, `release_lease`) [V]. It does not subtract
budgets. `cmca_execution.rs` maps PDDL actions to CMCA priorities and seals an
`execution` receipt with independent recomputation, and explicitly excludes signatures
and remote verification [V header]. `dteam-kernel/quota.rs` has atomic multi-resource
`reserve` with leases and refill [V header, line 711]; it is std-only Rust and
reference-only for an Elixir ledger. `gymact/cmca.py` (T09) enforces exact-rational shares summing
to 1 and
`allocated_* <= source_budget.*` with typed refusals, read in `__post_init__` [V]. It is
the nearest checked budget split: flat (one level), Python, not recursive.

## 6. NoveltyRatio

Definition (RFC-006 section 36): novel security-critical mechanisms divided by satisfied
security requirements. This map counts new-build mechanisms (INVENT) over atomic
requirements. It does not claim any INVENT item is scientifically novel; each names an
external design pattern as [D].

Atomic ledger (id verdict clause):

```text
A01 REUSE   supervision, restart, monitoring (OTP)
A02 REUSE   durable retry: Oban, outbox, reconciler
A03 REUSE   distribution TLS (swarm release)
A04 EXTEND  kill switch wired into admission, cluster-wide
A05 COMPOSE CMCA share kernel via separate process or wasm
A06 EXTEND  integer parent-child budget split over Allocator.Budget
A07 EXTEND  spawn, delegate, tier raise are requests until admitted
A08 COMPOSE CMCA has no actuator contact (CONSTRUCT_ONLY host)
A09 EXTEND  JCS plus SHA-256 for every security identity
A10 EXTEND  replace term_to_binary identity sites
A11 EXTEND  cross-runtime canonical vectors
A12 COMPOSE independent non-Elixir canonicalization check
A13 EXTEND  effect_instance_id derivation and explicit new id
A14 EXTEND  mandatory effect claim store
A15 INVENT  actuator-checked execution generation (fencing token)
A16 INVENT  revocation and policy-epoch state at authority and actuator
A17 EXTEND  PreparedEffect structure and digest
A18 EXTEND  PreparedEffectStore over outbox and EKV
A19 EXTEND  journal integrity keyed by default
A20 REUSE   Ed25519 sign and verify (OTP crypto)
A21 INVENT  ActuationCertificate schema bound to PreparedEffect digest
A22 INVENT  issue-only AuthorityService in a separate domain
A23 EXTEND  AuthorityClient over the broker behaviour
A24 REUSE   ML-DSA and SLH-DSA sign and verify (OTP crypto)
A25 EXTEND  algorithm registry, identity inside signed bytes
A26 INVENT  k-of-n distinct-signer verifier
A27 INVENT  signer-independence court
A28 INVENT  actuator host (graphlaw_host is a pattern only)
A29 INVENT  sixteen-check fail-closed actuator fence
A30 COMPOSE actuator-local transactional claim and completion store
A31 COMPOSE OS and pod isolation of authority and actuator
A32 COMPOSE credential custody outside the control plane
A33 EXTEND  ambient-credential preflight and court
A34 EXTEND  effector call-graph closure court
A35 EXTEND  single actuation interface (dispatch behind kernel)
A36 EXTEND  unresolved dynamic edges refuse
A37 EXTEND  principal preserved to actuator
A38 INVENT  bounded non-amplifying delegation
A39 EXTEND  replay returns prior evidence, never second DO
A40 EXTEND  UNKNOWN_OUTCOME with no automatic retry
A41 EXTEND  closed callback registry (no MFA from data)
A42 EXTEND  DeclaredExecutable and typed args
A43 EXTEND  EndpointCapability and egress policy
A44 EXTEND  FileObject
A45 EXTEND  atom hygiene
A46 COMPOSE wasmex host outside the kernel boundary
A47 COMPOSE asymmetric signed receipts across boundaries
A48 EXTEND  receipt predecessor chain
A49 COMPOSE independent receipt verifier
A50 EXTEND  standing derived, not stored
A51 EXTEND  control-plane compromise court
A52 EXTEND  fault-injection court
A53 COMPOSE resource-conservation property court
A54 EXTEND  CWE classification reports
A55 REUSE   anti-vacuity mutation harness ([R])
A56 REUSE   SBOM and provenance attestation
A57 REUSE   native-crate dependency policy (.github/cargo-deny.toml, CI)
A58 COMPOSE attestation verification court
A59 COMPOSE secrets scanning
```

Counts (recomputed with awk over the block above, post-audit):

```text
REUSE 8   COMPOSE 12   EXTEND 30   INVENT 9   total 59
NoveltyRatio (INVENT / total), upper bound     = 9 / 59 = 0.153
  of which A26, A27 rest on an unverified negative (keyword hits not inspected)
NoveltyRatio, verified negatives only          = 7 / 59 = 0.119
Non-kernel-new share ((REUSE + COMPOSE) / 59)  = 20 / 59 = 0.339
```

Pre-audit values were REUSE 7, COMPOSE 13, EXTEND 31, INVENT 8 (0.136). Changes: A57
COMPOSE to REUSE (cargo-deny exists); A28 EXTEND to INVENT (graphlaw_host offers a pattern,
no code to extend).

The ratio is a bound, not a measurement: an INVENT verdict is a negative over the
searched set, and coverage of the 316 top-level directories under `~` is partial. Another
directory can only lower INVENT, so 0.153 is an upper bound on the true ratio given the
searched set is a subset. Coverage:

- **Read by this author at some depth (path level):** ash_a2a, bcinr, wasm4pm, gymact,
  dteam, ggen, castle, affidavit, praxis, osx-clnr, autofde-lab, xaas, teleport, erlmcp,
  ggen-broker, chatman-ecosystem, swarm (inside ash_a2a).
- **Keyword-grep or listing only, or reported by lanes:** ggen-marketplace,
  engineering-standards, beam4pm, A2A, a2a-rs, zcode-cli, ggen_igniter, clnrm,
  five-layer-agents, chicago-tdd-tools, gitvan, star-toml, ggen-ecosystem, jotp.
- **Not searched (about 285 of 316):** every other top-level directory. One broad grep
  over `~` timed out.

Genuinely new (INVENT), and why nothing existing covers each:

- **A15 fencing token:** no actuator in the searched set checks an execution generation;
  gall-work epochs [R] gate work claims, not effects; T35 and T36 are not fences.
- **A16 revocation and policy epoch:** ggen `pki.rs` revokes keys only [V]; no epoch
  check at any actuator.
- **A21 ActuationCertificate:** no type binds an exact-effect digest, algorithm id and
  expiry under an independent signature; praxis signs a chain hash [V], oclnr HMACs a plan
  [V], autofde grants are unsigned records [R].
- **A22 AuthorityService:** every BRCE implementation found is in-process or same-node
  [R]; ggen_igniter documents the external broker as PLANNED [R].
- **A26 k-of-n verifier and A27 independence court:** no k-of-n verifier located; keyword
  hits not inspected; UNVERIFIED negative, excluded from the verified-negative ratio.
- **A28 actuator host:** T14 is a pattern, T37 is powerless, T38 unread; no code to extend.
- **A29 actuator fence:** no verifier of the section 16 list exists; nearest patterns are
  recompute-verify (T04) and prepared-before-DO (T21) [V/R].
- **A38 bounded delegation:** no delegation-with-attenuation code found [R].

Seven of the nine (A15, A16, A21, A22, A26, A28, A29) are the section 13-16 authority and
actuator chain, which has no lane in `_LANES.md` yet (section 8). A27 belongs to the same
chain; A38 is separate.

## 7. Red flags

Paths only; no secret value was read or printed.

1. **Mock post-quantum crypto** [V]: `affidavit/src/1000x_post_quantum_sealing.rs`
   (`mock_dilithium_sign`, `mock_kyber_encapsulate`), behind the empty opt-in feature
   `pqc` (`Cargo.toml:194`, `lib.rs:138` cfg gate), not compiled by default. Must not be
   cited as PQ evidence.
2. **Committed signing keys, history not rewritten** [V]:
   `bcinr/docs/security/signing-key-rotation-v26.9.24.md` records revoked keys at
   `.ggen/keys/`, `playground/.ggen/keys/`, `crates/chess-factory/.ggen/keys/` and states
   the branches keep the blobs. Current tree tracks only `.ggen/keys/.gitignore` [X].
3. **Ambient or same-principal key custody** [V]: `praxis/crates/praxis-core/src/
   signing.rs` (key from env, embedded verifying key); `osx-clnr/src/integration/
   config.rs` and `~/.oclnr/approval.key` (symmetric, same user signs and verifies).
4. **Non-cryptographic receipt digest** [V]: `bcinr-cmca/src/allocation_receipt.rs`
   `mix64`; its own docs say not a security boundary.
5. **Kernel-adjacent dynamic dispatch and NIF** [V]: `ash_a2a/lib/ash_a2a/agent.ex:1258`
   `apply/3` on a DSL MFA; `ash_a2a/mix.exs:400` wasmex Rustler NIF in the VM.
6. **Dist TLS caveats** [V]: `swarm/rel/overlays/ssl_dist.conf` disables SNI (peer
   identity is CA chain only; needs a dedicated CA); `swarm/rel/env.sh.eex` allows
   `SWARM_DIST_TLS=false`.
7. **Private-key files on disk, tracking unverified** [R]: `ggen/.ggen/keys/`,
   `affidavit/.ggen/keys/`, `chicago-tdd-tools/.ggen/keys/` (one tracked path under it,
   not identified), `gitvan/.gitvan/keys/`, `star-toml/.ggen/keys/`. Also tracked keypair
   in history of `five-layer-agents` per its last commit message [R].
8. **Plain-file private key** [R]: `ggen/crates/ggen-cli/src/receipt_manager.rs`
   (`.ggen/keys/private.pem`, no encryption at rest observed).
9. **Silent isolation skip** [R]: `ggen/Dockerfile.gvisor` continues without runsc when
   the vendored source is absent.
10. **`panic = "abort"` in bcinr release profile** [R]: a panic in a verifier is a DoS.
11. **Resolved:** `ash_a2a/erl_crash.dump` and `ash_a2a-26.9.12.tar` are gitignored
    (`.gitignore:21,27`) and no key, pem or secret path is tracked in ash_a2a [X].

## 8. Reuse-first implementation order

Ground truth: the lane map (`_LANES.md`) already covers canonical identity (L01, L02),
refusals (L03), PreparedEffect (L04), kernel (L05, L06), claims and fencing (L10),
in-process authority broker (L11), profile (L12), closed primitives (L13-L16), budgets
(L17), receipts (L18), standing (L19) and courts including the xref graph (L20). It has
no lane for an external authority, certificate, actuator, PQ or k-of-n. Proposed order,
by nearest-reachable first; new lanes are labeled X and would need their own ownership
entries (this map does not edit the lane file).

1. **W1 L01 with A09 A11:** JCS as the only identity encoding; add RFC 8785 vectors in
   the T12 layout. Add the Rust canonicalizer cross-check as X5 (test-only crate).
2. **W1 L02, L03 with A10:** mechanical digest conversion; add refusal codes for
   certificate, quorum, epoch, generation and prior-completion (needed by X1-X3).
3. **W2 L04 with A17 A18 A19:** PreparedEffect carries generation, epoch, expiry,
   algorithm id.
4. **W3 L05 with A35 and the effector graph task (A34 A36):** wire `mix xref` first, then
   T23 closure as the second extractor.
5. **W4 L06 and L09 with A41 A45:** removals and consequence class.
6. **W5 L10 with A13 A14 A39 A40:** claim, generation counter (control-plane half of
   A15), unknown outcome.
7. **W5 L11 plus X1 (AuthorityClient, certificate schema, A21 A23 A20 A24 A25):**
   certificate verification library in Elixir over `:crypto` (T18); no external process
   yet, so C2 is not claimed at this step.
8. **W6 L12 with A19 A33:** profile pins the accepted algorithm set and the authority
   public keys.
9. **W7 L13, L14, L15, L16 with A41-A46;** **L17 with A06 A07:** `Budget.split/2`,
   property court A53. CMCA share kernel (A05) stays optional and outside the kernel.
10. **X2 (after L11, in parallel with W7):** AuthorityService as its own release (A22),
    then X3 signer registry, k-of-n and independence court (A26 A27, INVENT).
11. **X4 Actuator (after X2 and W8 L18):** host copies the T14 pattern, own claim store,
    fence (A28 A29 A30 A15 A16). This is the step that first supports SA2A-C2.
12. **W8 L18 with A47 A48 A49:** signed receipts, predecessor chain, external verifier.
13. **W8 L19 with A50; W9 L20 with A51-A55:** section 26 attacks as corpus entries;
    fault-injection points from section 29.
14. **Any wave, disjoint files (CI and native/):** A58-A59 supply-chain gaps (A56, A57
    already satisfied).

Critical path additions: L11 -> X1 -> X2 -> X3 -> X4 -> L20. C1 is reachable at L12; C2 at
X4; C3 at X3 plus X4.

## 9. Lane-claim spot-check ledger

Twenty-nine claims re-read or re-executed by this author. Result: CONFIRMED, CORRECTED, or
CONTRADICTED (post-audit).

```text
SC01 cascade.rs 486-514 conservation doc        CORRECTED (doc says provable AND tested)
SC02 allocation_receipt.rs mix64 non-crypto     CONFIRMED
SC03 lib.rs points to missing CMCA_EXPLANATION  CORRECTED (file exists at bcinr/docs)
SC04 lib.rs deny(unsafe_code)                   CONFIRMED (line 132)
SC05 allocator fallback subnormalized vector    CONFIRMED (2410-2420)
SC06 wasm4pm-cmca CONSTRUCT_ONLY, pin 26.7.28   CONFIRMED; no built wasm found
SC07 affidavit PQ is mock, pqc = []             CORRECTED (behind opt-in pqc feature)
SC08 castle crypto.rs real ml-dsa, slh-dsa      CONFIRMED
SC09 agent.ex:1258 apply on MFA, is_atom guards CONFIRMED
SC10 receipt_outbox HMAC, hash_equals, [:safe]  CONFIRMED (81, 105, 524 re-read)
SC11 capability_release Jcs.encode + sha256     CONFIRMED
SC12 KillSwitch not consulted by CommandBus     CONTRADICTED (command_bus.ex:973-996, opt-in)
SC13 graphlaw_host wasmtime =48.0.1 job file    CORRECTED (pattern only, no enforcement)
SC14 Allocator.Budget no ceiling-raise path     CONFIRMED (spender only; reissue/4 is gated)
SC15 bcinr-pddl resource_ledger is budget-side  CONTRADICTED (interval lease ledger)
SC16 cmca_rank_cli fixed N=8 K=4 Q=4            CONFIRMED
SC17 osx-clnr HMAC verify_slice, key file       CONFIRMED
SC18 praxis key from env                        CONFIRMED (header)
SC19 bcinr key rotation doc, tree tracks none   CONFIRMED (only .gitignore tracked)
SC20 ssl_dist SNI disabled; SWARM_DIST_TLS      CONFIRMED
SC21 AbstractCode.reachable local-only          CONFIRMED
SC22 k8s hardened pod profile                   CORRECTED (baseline only, no isolation)
SC23 dteam-kernel quota reserve, sha256         CORRECTED (reserve ok; hand-rolled sha256
                                                not endorsed)
SC24 :crypto ML-DSA availability unchecked      CORRECTED (available; round trip run)
SC25 erl_crash.dump / tarball tracked?          CORRECTED (gitignored, not tracked)
SC26 stream_data / hex.audit / attest present   CONFIRMED (mix.exs:312; release.yml)
SC27 no deny.toml for native/ (map gap)         CONTRADICTED (.github/cargo-deny.toml, CI)
SC28 no checked budget split under ~ (map F2)   CORRECTED (gymact cmca.py flat split)
SC29 portable_receipt.rs Ed25519 envelope       CONTRADICTED (no Ed25519 in file; UNVERIFIABLE)
```

Counts: CONFIRMED 16, CORRECTED 9, CONTRADICTED 4.

## 10. Unverified and open

- **REPORTED, not re-read:** everything labeled [R], including autofde-lab broker, xaas
  gall checkpoint modules, ggen envelope, beam4pm chain, affidavit chain and verifier,
  erlmcp, A2A, a2a-rs, dteam ledger, all pack contents beyond listings,
  command_bus lines other than 973-996, and the test counts for bcinr-cmca.
- **Not run:** any mix task, cargo build or test, `verify_network_isolation.sh`. A
  passing state of any cited test is UNVERIFIED.
- **ML-DSA in the release image:** proven on this host only. The digest-pinned swarm base
  image was not inspected.
- **Cross-implementation PQ vectors:** `:crypto` vs castle (`ml-dsa 0.1.1`) untested.
- **`jcs` hex 0.2.0 conformance:** no RFC 8785 appendix vectors exist in the repo; the
  Rust cross-check is external and not under `~`.
- **RDFC-1.0 for the vendored GraphLaw wasm:** the v006 vector documents instability in
  the older vendored build [R]; not re-run.
- **wasmex kernel classification:** whether the GraphLaw host is inside the kernel is an
  undecided boundary (A46).
- **CMCA shape generalization:** whether `cascade::consequence_mass` can be exported
  through T05 or T06 for arbitrary trees is unknown; the rank CLI request schema was not
  read past its header.
- **UNVERIFIABLE leads:** beam4pm chain unauthenticated (T27); no Elixir receipt with both
  predecessor and MAC (A48); Ed25519 in ggen `portable_receipt.rs`; k-of-n absence (A26).
- **Unread candidates:** `bcinr-guarded`, `bcinr-cmca/src/certification.rs`,
  `bcinr-logic/src/SAFETY.md`, `erlmcp` consensus modules, `ecosystem-runtime`
  internals, `ggen-ecosystem/tests/autonomics_contracts/test_011_idempotent.py`, `engineering-
  standards/scripts/check-rfc-standing.py`, `~/A2A/security`, `chatmangpt` A2A reports.
- **Secret scan:** no repository-wide scan was run; red flag 7 rests on lane listings.
- **FIPS status of BLAKE3** is stated from general knowledge, not from a document here.
- **Search coverage:** partial; see the coverage list in section 6. Lumen semantic search
  was reported unhealthy.

## 11. Audit record

Independent audit applied 2026-09-28. Each item, the cited code re-read here, and the change.

```text
1  bcinr-cmca dangling doc link          FALSE   deleted claim; SC03 CORRECTED; 5.5 item 9
                                                 downgraded (doc exists, marks superseded)
2  CMCA conservation only in cascade.rs  TRUE    no change (stale-doc caveat noted in 5.2)
3  mix64 non-crypto receipt digest       TRUE    no change
4  allocate fixed N=8 K=4 Q=4            TRUE    no change
5  wasm4pm-cmca CONSTRUCT_ONLY, 26.7.28  TRUE    no change (absent .wasm stays a find negative)
6  bcinr-pddl ledger is interval-lease   TRUE    no change
7  no checked budget split under ~ (F2)  OVERSTATED  F2, T09, 5.6 rewritten: gymact cmca.py is
                                                 a flat checked split (read); recursion
                                                 still absent; used as differential oracle
8  Budget has no ceiling-raise path      TRUE    caveat: reissue/4 is issuer-gated (SC14)
9  KillSwitch opt-in in CommandBus       TRUE    no change; application.ex comment is stale
10 OTP 28 ML-DSA round trip              TRUE    SLH-DSA and eddsa marked UNVERIFIED (F7)
11 castle real ml-dsa, slh-dsa           TRUE    no change
12 affidavit mock compiled unconditionally  OVERSTATED  phrase deleted; behind empty `pqc`
                                                 feature (T17, F7, red flag 1, SC07)
13 capability_release JCS strings-only   TRUE    F3 note: 49 hits, deterministic sites named
14 graphlaw_host as extendable actuator  OVERSTATED  T14, F9 reworded to pattern; A28 EXTEND
                                                 to INVENT; capability-less UNVERIFIED
15 k8s manifests isolate authority       OVERSTATED  T15, F10 relabelled: hardening baseline
                                                 only; isolation topology new (A31, A32 stay)
16 release attestations REUSE            TRUE    no change
17 no deny.toml for native/ (A57)        FALSE   gap deleted; A57 COMPOSE to REUSE; counts
                                                 recomputed; SC27 added
18 AbstractCode.reachable local-only     TRUE    no change
19 architecture check is regex           TRUE    no change
20 outbox HMAC citation                  TRUE    audit asked to fix lines; re-read shows
                                                 receipt_outbox.ex:81,105 are correct; kept
21 CommandBus claim, optional confirm    TRUE    no change
22 xaas Actuation three-commit protocol  TRUE    T22 adds idempotency_key; still a reference
23 autofde-lab BRCE boundary             OVERSTATED  T21, F6 reworded: in-process reference
24 pki.rs keys only; portable_receipt    OVERSTATED  pki claim now [V]; Ed25519 claim withdrawn
                                                 as UNVERIFIABLE (T13, F15, SC29)
25 no multisig/threshold anywhere        OVERSTATED  F8 restated: no verifier located, hits not
                                                 inspected; excluded from verified negatives
26 beam4pm unauthenticated chain         UNVERIFIABLE  labelled lead (T27)
27 osx-clnr HMAC, praxis Ed25519         TRUE    no change
28 dteam quota reserve, hand-rolled sha  OVERSTATED  reserve kept; sha256 endorsement dropped
29 ssl_dist SNI, SWARM_DIST_TLS          TRUE    no change
30 no Elixir receipt with chain and MAC  UNVERIFIABLE  labelled lead (F15, A48)
```

Missed prior art added (each path read briefly, verdicts unchanged):

```text
M1 teleport ggen-core pqc.rs mldsa65     READ header   T30; second ML-DSA implementation (F7)
M2 erlmcp swarmflow_pqchain.disabled     READ listing  T31; NIF, disabled, design input (F7 F8)
M3 xaas idempotency_key, gall checkpoint READ actuation.ex; gall files listed only  T22 T35
M4 ggen-broker crates                    READ listing  T32; no signing seen [R]; F6 stays INVENT
M5 teleport knhk-admission stage 3 PQC   READ code     T33; payload signature only; A23, A25
M6 affidavit W8 hybrid suite enum        READ excerpt  T34; A25 design reference
M7 xaas R1-X-FENCE gate                  READ listing  T36; CI logs, not a fence
M8 gymact rust/crown                     READ header   T37; powerless, no actuator
M9 chatman-ecosystem ecosystem-runtime   READ header   T38; unread beyond header (UNVERIFIED)
```

New candidates for cross-implementation checks: T30 and T16 as independent ML-DSA
verifiers (F7 falsifier); T33 as an A23/A25 reference; T34 as the A25 suite-enum reference;
T09 as the F2 differential oracle. No verdict flipped from INVENT to REUSE.

## 12. See Also

- `docs/rfc/RFC-SA2A-006-adversarial-control-plane-v26.9.28.md`: the requirement source
- `docs/rfc/RFC-SA2A-005-security-profile-v26.9.28.md`: current-code status and CWE table
- `docs/jira/v26.9.28-kernel/_LANES.md`: kernel lane map this order attaches to
- `docs/rfc/RFC-SA2A-004-v26.9.28.md`: normative consequence protocol
