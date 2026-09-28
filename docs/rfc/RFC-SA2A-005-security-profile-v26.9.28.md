# RFC-SA2A-005-security-profile-v26.9.28

## Status

- **Title**: SA2A Consequence Kernel Security Profile
- **Milestone**: v26.9.28
- **Status**: DRAFT (candidate specification; no claim in this document is a release claim)
- **Subject**: `/Users/sac/ash_a2a` at HEAD `8af12616314c12c58dfa6cd03c83c0c8ad657eb6`
- **Tree state**: the working tree carries about 40 modified files and untracked files
  (RFC-004 convergence edits, in flight, uncommitted). Every "current status" below is
  OBSERVED on that dirty tree by read-only inspection. No test was executed for this RFC.
- **In-flight labels**: statements about the tree carry one of two states. **HEAD 8af1261**
  is the committed state. **In-flight** is the uncommitted dirty tree observed on 2026-09-28.
  Where they differ (for example the anchor durability check, section 12 G2) both are given.
- **Court status meaning**: in the matrix, EXISTS means a test exists whose
  removal-of-protection failure was verified by reading it. It does not mean the test was
  run, and it is not release-receipt qualification (section 13).
- **Companion**: `RFC-SA2A-005-cwe-court-matrix-v26.9.28.md` (court specification)
- **Last Updated**: 2026-09-28

## Abstract

SA2A does not make all vulnerabilities impossible. It minimizes the trusted consequence
kernel, removes dangerous representations and alternate effect paths from that kernel, and
requires exact identity, admission, live bounded authority, a unique effect claim, durable
preparation and final mediation for every protected consequence. The security posture moves
from "secure the agent" to "make vulnerability classes unable to produce consequence".

The formal target is `Compromise(untrusted component)` does not imply `UnauthorizedDO`. For
a weakness class `CWE_i`, the claim `Reach(UnauthorizedDO | CWE_i) = empty` is admitted only
where a falsifier court demonstrates it on an exact subject. This RFC lists candidate
class-elimination claims, each requiring an executable falsification court before release.
It does not assert that any class is eliminated today. Section 12 records the measured gap
between this profile and the tree.

## 1. Terms

- **Consequence**: an effect that crosses the DO boundary (RFC-004 section 8).
- **Kernel**: the Consequence Kernel defined in section 3.
- **Candidate producer**: any component whose output is a candidate or evidence and never an
  authority (LLM, planner, remote agent, MCP or A2A peer, RAG, ontology, GraphLaw, generated
  code, memory, workflow engine, provider).
- **UnauthorizedDO**: a consequence for which no live, exact, per-effect authority existed.
- **Court**: an executable falsifier with a typed expected outcome (matrix file).
- **Standing vocabulary**: ABSENT, PRESENT_GUARDED, PRESENT_UNGUARDED, UNKNOWN (section 10).

## 2. Threat model and trust planes

| Plane | Contents | Trust |
|---|---|---|
| Candidate | LLM, planners, peers, RAG, ontologies, GraphLaw, memory | none |
| Transport | HTTP/JSON-RPC, SSE, push webhooks, queues | identity carrier only |
| Kernel | identity, authority, claims, journal, fence, broker | trusted (TCB) |
| Effectors | code that performs the protected effect | trusted, isolated |
| Authority source | grant broker, policy epoch, revocation epoch | trusted, external |

Adversary: controls every candidate-plane output and every transport byte. May compromise
any candidate producer completely. Does not (in the base profile) hold kernel code
execution, effector host access, or the authority source.

Out of scope for the base profile: VM, crypto and native zero-days; volumetric DoS;
disclosure by an authorized reader; UI rendering. See section 8.

## 3. Trusted computing base

The TCB MUST be exactly:

1. canonical identity,
2. authority decision,
3. request and effect claim store,
4. prepared receipt journal,
5. consequence fence,
6. minimal effector broker,
7. receipt verifier.

Anything else MUST NOT hold credentials to a protected target, MUST NOT call an effector,
and MUST NOT mint authority. Growth of the TCB requires a release event (section 7).

Current tree (OBSERVED by grep, in-flight): the named files `command_bus.ex`,
`brce_anchor.ex`, `dispatcher.ex`, `authority.ex` and `receipt_outbox.ex` contain no
`System.cmd`, `Port.open`, `Code.eval*`, SQL or HTML primitive. `lib/ash_a2a/receipt/
offline_replay.ex` (the receipt verifier, TCB item 7) is excluded from that claim: it
contains `Port.open` (line 1173) and `System.cmd` (line 1211), use not examined (UNKNOWN).
The single dynamic dispatch among the named kernel files is `lib/ash_a2a/receipt_outbox.ex:431`
(`apply` on the configured store); `lib/ash_a2a/agent.ex:1244` (`on_cancel`) is another
dynamic `apply` on the request path outside that file set (gap G5). The kernel is not
process-isolated from the candidate plane: one BEAM release holds both.

## 4. No generic execution primitive (normative)

A conforming kernel MUST NOT contain, expose or accept as input:

- **M1** a shell or arbitrary command string; execution MUST go through a closed
  `ExecCapability` set of pre-admitted argv templates with typed slots.
- **M2** an attacker-chosen filesystem path; file access MUST use opaque `FileObject`
  handles minted by the kernel.
- **M3** an arbitrary URL or host; network egress MUST use an admitted `EndpointCapability`.
- **M4** raw SQL or query text; persistence MUST use typed relational operations.
- **M5** an unsafe render operation; output MUST be a render tree with no raw-HTML node.
- **M6** arbitrary deserialization; input MUST pass a canonical schema codec. Erlang term
  decoding of externally writable bytes MUST NOT occur without a keyed integrity check.
- **M7** dynamic module or function selection from data; capability lookup MUST resolve by
  string id against the compiled or released index without atom creation.
- **M8** runtime dependency acquisition or code loading.

Current status of each rule is in section 10 and the Evidence appendix. For M1, M4 and M5 no
such primitive was found in the listed kernel files by grep (a file-content observation, not
proof of the input-reachability rule; `System.cmd` and `Port.open` occur in about 20 other
`lib/` files, for example `planning/hddl_solver.ex:100`). For M8 the grep is in the appendix:
no runtime dependency acquisition was found; `:code.load_binary` occurs in test tooling
(`chicago/mutation.ex:494`). M6 is partial (`[:safe]` decoding, no integrity key by
default). M2, M3 and M7 hold only by convention.

## 5. Prepared-receipt boundary (normative)

The effector broker MUST accept exactly one caller-supplied value: a `PreparedReceiptID`.
On presentation the kernel MUST, in this order:

1. fetch authoritative state from the journal (never from the caller),
2. verify journal entry integrity (keyed MAC or signature),
3. verify request ownership (principal bound at preparation),
4. verify effect ownership (effect claim held by this execution id),
5. verify the exact subject digest,
6. re-evaluate live authority against the policy and revocation epochs,
7. issue a one-shot effector capability bound to that receipt and effect.

The capability MUST expire on use or on epoch change. A second presentation of the same
ID MUST return the stored outcome and MUST NOT cause a second effect.

Current tree (in-flight): `CommandBus.run/4` (`command_bus.ex:190`) implements a sequence
(admit, kill switch, claim, actuation claim, anchor, `confirm_claim`, pre-DO gate), not this
seven-step protocol. Step status, by reading only:

| Step | Status | Basis |
|---|---|---|
| 1 fetch from journal | PARTIAL | anchor is a caller-process value, `brce_anchor.ex:33-38` |
| 2 entry integrity | MISSING by default | no key by default (G3) |
| 3 request ownership | PARTIAL | claim by id and fingerprint, `command_bus.ex:203-223` |
| 4 effect ownership | PARTIAL | `confirm_claim/3` optional, `command_bus.ex:471` |
| 5 exact subject digest | UNVERIFIED | not traced to a check in this RFC |
| 6 live authority | PARTIAL | expiry-only without a broker, `command_bus.ex:1019-1025` |
| 7 one-shot capability | MISSING | no capability is issued; anchor is process-local |

The broker's `PreparedReceiptID`-only interface (one caller-supplied value) is not
implemented. `CommandBus.run/4` is public and takes the whole `Command` from the caller.

## 6. Per-effect authority (normative)

An authority decision MUST bind: principal, exact subject, capability, allowed
transformation, effect identity, resource envelope, validity interval, policy epoch and
revocation epoch. It MUST be re-evaluated at DO, not only at admission. Authority MUST be
minted only by the authority source; a locally constructed value MUST NOT be admissible.
Admission MUST be an allowlist over provenance, not a denylist over `source`.

Current tree: grants are per (principal, capability), and the agent path yields
`constraints %{}` (`authority.ex:75-90`). The only provenance check is a denylist on
`source: :model` (`command_bus.ex:952-955`); all other admission is a principal and
capability match (`Authority.admits?`, `command_bus.ex:957-961`) or refusal of absent
authority (`command_bus.ex:964-966`). The forgery path is `Authority.new/3`
(`authority.ex:60`), an open constructor. With no broker configured, revalidation reduces to
an expiry check (`command_bus.ex:1022-1025`). See gaps G1, G4.

## 7. Supply-chain wall (normative)

A conforming release MUST provide signed provenance, locked dependencies, an SBOM, signed
artifacts, no runtime dependency acquisition, hash-pinned runtime artifacts (including
WASM modules and native binaries), and a release closure naming every executable
dependency. A capability MUST be available only after an admitted release event.

Current tree (workflow inspected, not run; UNVERIFIED as executed): `release.yml` contains
`mix deps.get --check-locked` (lines 70, 80), `mix hex.audit` (71), `cargo ... --locked` for
`cargo-cyclonedx` only (95), SHA-pinned `uses:` (45, 60, 103, 107) and SBOM and provenance
attestation steps (92-110). `mix.lock:77,96` show hex entries for `rustler_precompiled` and
`wasmex`. That an SBOM or attestation step exists is not evidence that one was produced for
this subject. The runtime `CapabilityRelease` defaults to `:legacy`
unless strict mode is configured (`lib/ash_a2a/capability_release.ex:287-296`), so the
release event is not yet the availability gate by default. The precompiled `wasmex` NIF
artifact checksum and the `hddl_cli` and `graphlaw_host` binary digests are UNKNOWN.

## 8. Isolation requirements (normative for a conforming security profile)

- **I1** The candidate plane MUST have no network route and no credentials to protected
  targets.
- **I2** Effectors MUST run behind an OS, container or microVM boundary distinct from the
  candidate plane. A BEAM process is fault isolation and is not a hostile-code boundary.
- **I3** Candidate-plane subprocesses MUST receive a scrubbed environment (allowlist, not
  inheritance).
- **I4** Provider credentials (LLM keys, signing keys) MUST NOT be readable from candidate
  code paths.
- **I5** Native code that parses candidate input MUST run out of process with a wall-clock
  and memory bound.

Current tree: none of I1 to I4 holds as a mechanism. One release holds kernel and
candidate code in one VM; `req_llm` resolves provider keys in that VM; `Port.open` and
`System.cmd` sites other than `graph_law/subprocess.ex` pass no `env:` (OBSERVED). The
`wasmex` NIF runs inside the BEAM (dependency `mix.exs:400`; host GenServer child spec
`application.ex:140`; DERIVED from wasmex being a NIF); `graphlaw_host` and `hddl_cli`
are separate processes. The missing `env:` option is DERIVED from the `Port.open` option list
(`graph_law/wasmtime_runtime.ex:481`), not shown by a single line. I5 is met for
`graphlaw_host` (deadline plus `kill -9`) and not for `hddl_cli`
(`planning/hddl_solver.ex:100`, no timeout).

## 9. Residual risk (out of profile, stated so it is never assumed)

- VM, crypto and native zero-days (BEAM, `wasmex`, wasmtime, rustix, OpenSSL).
- Availability and volumetric denial of service. Section 10 rows for CWE-770 CONTAIN, not
  eliminate.
- Disclosure by authorized readers, log leakage, telemetry (CWE-200 CONTAIN).
- UI cross-site scripting: the library emits no HTML (OBSERVED), but a client can render
  candidate text unsafely (CWE-79 CONTAIN).
- Generic input validity (CWE-20 CONTAIN): bounds and shapes reduce, not remove, bad input.
- Host misconfiguration: strict opt-ins left off (gaps G6, G7, G11).
- Memory-safety classes: claimed only as absent from project-owned kernel code; the
  native and VM residual remains.

## 10. Per-CWE disposition

Code-state vocabulary (column "Code state"; not the same axis as the matrix's "Court
coverage" of EXISTS, PARTIAL, MISSING): **ABSENT** (dangerous representation not found by grep in
`lib/` and `native/`; grep-only, deps and
host apps not covered), **PRESENT_GUARDED**
(present, guard observed), **PRESENT_UNGUARDED** (present, no guard observed), **UNKNOWN**
(not established). Status is the worst observed status across kernel, adapter, transport
and tooling for that class. A status is an observation at the dirty tree, not a standing.

Targets: **ELIM** = unrepresentable in the kernel; **ABSENT-K** = absent from project-owned
kernel code with native residual; **CONTAIN** = bounded, not eliminated; **CLASS** = the
class is reduced to a kernel property.

### 10.1 Protocol-plane elimination candidates

| CWE | Target | Code state | Evidence (path:line) | Required court |
|---|---|---|---|---|
| 862 | ELIM | PRESENT_UNGUARDED | agent.ex:1244 on_cancel; agent.ex:829-857 | SEC-CWE-862 |
| 863 | ELIM | PRESENT_UNGUARDED | command_bus.ex:952-966; authority.ex:52-65 | SEC-CWE-863 |
| 284 | ELIM | PRESENT_GUARDED | dispatcher.ex:242-266; anchor.ex:135, 33-38 | SEC-CWE-284 |
| 306 | ELIM | PRESENT_GUARDED | agent.ex:385-407; command_bus.ex:947-968 | SEC-CWE-306 |
| 639 | ELIM | PRESENT_GUARDED | ownership.ex:44-50 (642: 52-66) | SEC-CWE-639 |
| 78 | ELIM | PRESENT_GUARDED | kernel files clean; hddl_solver.ex:100 | SEC-CWE-078 |
| 77 | ELIM | PRESENT_GUARDED | standing_ref.ex:467 argv form | SEC-CWE-078 |
| 94 | ELIM | PRESENT_UNGUARDED | agent.ex:1244 apply; :101 eval, no guard | SEC-CWE-094 |
| 89 | ELIM | ABSENT | grep only: no SQL or `fragment(` match in lib/ or native/ | SEC-CWE-089 |
| 22 | ELIM | PRESENT_UNGUARDED | research/erc.ex:100; receipt_outbox.ex:464 | SEC-CWE-022 |
| 434 | ELIM | ABSENT | grep only: no Plug.Upload or multipart in lib/ | SEC-CWE-434 |
| 502 | ELIM | PRESENT_GUARDED | receipt_outbox.ex:524; execution_snapshot.ex:289 | SEC-CWE-502 |
| 918 | ELIM | PRESENT_UNGUARDED | ocel_forwarder.ex:239; push_delivery.ex:105-135 | SEC-CWE-918 |
| 352 | ELIM | ABSENT | grep only, lib/ (host-app property, see note) | SEC-CWE-352 |

Notes: CWE-22 is UNGUARDED for `research/erc.ex` (tooling, id unsanitized) and UNKNOWN for
the outbox `receipt_id` segment (charset of `Identity.external` not read). CWE-918 is
GUARDED for push webhooks (`WebhookPolicy`, IP pin, no redirect) and UNGUARDED for the OCEL
forwarder, whose URL is config-only and which forwards receipt events; the `Req.post` at
`telemetry/ocel_forwarder.ex:239` sets no `redirect:` option, so redirect handling is Req's
default (UNVERIFIED in this repo). CWE-352 is a host-application property (session and cookie
state live in host apps and `Plug.Session`); `lib/` grep absence does not cover them.
CWE-502 also has two unsafe `binary_to_term` sites under `chicago/fixtures/` (test-only,
compiled into `lib/`), and an unkeyed outbox path (G3).

### 10.2 Memory-safety classes (project-owned kernel code only)

| CWE | Target | Code state | Evidence | Required court |
|---|---|---|---|---|
| 787 | ABSENT-K | PRESENT_GUARDED | wasmex NIF in VM (mix.exs:400) | SEC-CWE-787 |
| 416 | ABSENT-K | PRESENT_GUARDED | same; native/ crates: no unsafe | SEC-CWE-787 |
| 125 | ABSENT-K | UNKNOWN | wasmex_host.ex:988; bounds in wasmtime unexamined | SEC-CWE-787 |
| 120 | ABSENT-K | PRESENT_GUARDED | native/ crates: no unsafe (grep) | SEC-CWE-787 |
| 476 | ABSENT-K | PRESENT_GUARDED | graph_law/wasmex_session.ex:100 MatchError only | SEC-CWE-787 |
| 121 | ABSENT-K | UNKNOWN | not specifically examined | SEC-CWE-787 |
| 122 | ABSENT-K | UNKNOWN | not specifically examined | SEC-CWE-787 |

Native crates `native/graphlaw_host` and `native/hddl_cli`: grep for
`unsafe|unwrap()|expect(|panic!|extern |Command::new` over `native/**/*.rs` returns no match
(OBSERVED, in-flight; `unwrap_or*` variants do occur). Process-abort paths exist:
`std::process::exit` at `graphlaw_host/src/main.rs:442` and `hddl_cli/src/bin/hddl_analyze.rs:63`.
Absence of `unsafe` in these two binaries does not bound memory safety in their parsing
dependencies. Exposure is transitive
(wasmtime 48.0.1, cranelift, rustix, ferroplan). Advisory status is UNKNOWN (no
`cargo audit` run). A native crash in the in-VM NIF is a shared crash domain with the kernel.

### 10.3 CONTAIN classes

| CWE | Target | Code state | Evidence | Required court |
|---|---|---|---|---|
| 79 | CONTAIN | ABSENT | no HTML or template primitive in lib/ | SEC-CWE-079 |
| 20 | CONTAIN | PRESENT_GUARDED | plug.ex:383,389-390 `:more` refused, limit ? | SEC-CWE-020 |
| 200 | CONTAIN | PRESENT_UNGUARDED | safe_error.ex:46 logs; env inheritance | SEC-CWE-200 |
| 770 | CONTAIN | PRESENT_UNGUARDED | hddl_solver.ex:100; compiler.ex:148 | SEC-CWE-770 |

CWE-20 shape validation after `Jason.decode` in `gall/*` and `semantic/*` is UNKNOWN.
CWE-770 also lists: `ReceiptOutbox` has no growth cap (UNKNOWN); `TaskEvents` leaks state for
abandoned non-final tasks; caps live in per-runtime process state.

### 10.4 Extra classes

| CWE | Target | Code state | Evidence | Required court |
|---|---|---|---|---|
| 294 | CLASS | PRESENT_GUARDED | command_bus.ex:203-223 claim by id+fp | SEC-CWE-294 |
| 367 | CLASS | PRESENT_GUARDED | command_bus.ex:306-387,1003-1107 | SEC-CWE-367 |
| 441 | CLASS | PRESENT_GUARDED | agent.ex:960-967; identity.ex:41-59 | SEC-CWE-441 |
| 551 | CLASS | PRESENT_UNGUARDED | actuation.ex:75-91 raw input digest | SEC-CWE-551 |
| 642 | CLASS | PRESENT_GUARDED | agent.ex:1073-1081; plug.ex:221-226 | SEC-CWE-642 |
| 837 | CLASS | PRESENT_UNGUARDED | actuation.ex:75-91; command_bus.ex:749-753 | SEC-CWE-837 |
| 841 | CLASS | PRESENT_GUARDED | command_bus.ex:196-225,306-387 | SEC-CWE-841 |

Counts by code state over the 32 rows above: ABSENT 4, PRESENT_GUARDED 16,
PRESENT_UNGUARDED 9, UNKNOWN 3. Previous draft: 4, 17, 9, 2. Changes: 284 UNGUARDED to
GUARDED (in-flight anchor durability check), 94 GUARDED to UNGUARDED (`on_cancel` apply),
125 GUARDED to UNKNOWN (bounds delegated, unexamined). Code state and court coverage are
separate axes and no combined rating is defined.

### 10.5 Advertised claim count

The enumerated eliminate and absent-K rows (14 protocol, 7 memory, 7 extras) total 28. The
operator direction says 27. The counts do not reconcile from the enumerated list, so this RFC
does not fix a number in prose beyond: "candidate class-elimination claims, each requiring
an executable falsification court before release". The release receipt (section 13) carries
the actual count of courts that passed. SA2A MUST NOT advertise "eliminates N CWEs".

## 11. OWASP Agentic mapping

The claim is that most agentic risks stop being authority channels, not that all ten
disappear. "Smallest path" is the smallest OBSERVED route from a candidate-plane
compromise to DO on this tree.

| Class | Smallest candidate-to-DO path (OBSERVED) | Residual |
|---|---|---|
| Goal hijack | none found (UNVERIFIED); ends at `PackageStore.put` (agent.ex:596-652) | text only |
| Tool misuse | hijacked client with a grant sends any input to granted skill | G4 |
| Identity abuse | wire: per-capability grant; in-BEAM: `Authority.new/3` (authority.ex:60) | G1 |
| Supply chain | none from wire; legacy release mode default | G7 |
| Unexpected code exec | `on_cancel` MFA by task owner (agent.ex:1244) | G5 |
| Memory poisoning | none found (UNVERIFIED); `command_id` squatting: conflict only | DoS |
| Insecure inter-agent | none found (UNVERIFIED); peer.ex:531-533 returns `:none` | exfil via push |
| Cascading failure | kill switch off by default (command_bus.ex:980-1005) | G11 |
| Human-agent trust | HILT optional (command_bus.ex:1161-1195) | host policy |
| Rogue agent | bounded to its principal's broker grants | G4 |

## 12. Gaps against the current implementation

Ranked by reachability of UnauthorizedDO or of a second effect path. RFC-003 bypass ids are
cited where they apply.

1. **G1 (B4)**: authority is an open struct; admission is a denylist on `source: :model`;
   `CommandBus.run/4` is public; no broker means expiry-only revalidation.
2. **G2 (B1, B2)**: the sole-DO fence is a process-dictionary anchor; `Dispatcher.dispatch/6`
   is public. Two states: at HEAD 8af1261 (RFC-003 reading) the anchor check did not require
   an outbox entry; in-flight, `brce_anchor.ex:135` refuses `:anchor_not_durable` unless
   `ReceiptOutbox.anchored?/1` holds (moduledoc 30-32). The remaining gap is that the anchor
   is process-local (`brce_anchor.ex:33-38`): in-BEAM callers can bypass BRCE. In-flight
   `rfc004_fence_test.exs` is untracked and not run here.
3. **G3 (B3)**: the outbox journal is unkeyed by default; a local writer can plant a
   well-formed `%Receipt{}`; `ExecutionSnapshot` digests are unkeyed SHA-256.
4. **G4**: grants are per (principal, capability); constraints default to `%{}`; a goal-hijacked
   granted client can drive any input. Per-effect authority (section 6) is absent by default.
5. **G5 (B7)**: `on_cancel` applies a declared MFA with no grant, anchor or receipt.
6. **G6 (B6)**: a generic `:action` declared `:observe` dispatches unreceipted;
   `strict_observe_generic_actions` defaults off (agent.ex:842-844).
7. **G7**: `CapabilityRelease` defaults to `:legacy`; capability availability is not an
   admitted release event unless strict mode is set.
8. **G8**: effect identity hashes the raw input map before Ash casting, so representation
   variants can cross DO twice; `:strict` actuation silently degrades for stores lacking
   `claim_actuation/commit_actuation/release_actuation`; `confirm_claim/3` is optional.
9. **G9 (B8)**: `OcelForwarder` egress has no SSRF policy and sets no `redirect:` option
   (Req default, UNVERIFIED); provider
   credentials and process environment are shared with the kernel; children inherit env.
10. **G10**: CWE-770 gaps: `HddlSolver` no timeout (`planning/hddl_solver.ex:100`);
    `Task.async_stream` `timeout: :infinity` at `semantic/compiler.ex:148`; outbox growth
    unbounded; `a2a_transport/plug.ex:383` calls `read_body/1` with no explicit length.

Further: G11 kill switch and HILT are opt-in; G12 (B9) Oban authority reconstruction with no
broker; G13 (B11) chicago fixtures ship in `lib/` and use `authorize?: false`; G14 log
content (`safe_error.ex:46`); G15 `command_id` squatting via `continuation_fingerprint`.

## 13. Security release receipt

A security release MUST emit one receipt per release, validated by the schema below. A
missing field means the artifact is not a receipt.

```json
{
  "kind": "sa2a.security_release_receipt",
  "subject": {"repo": "ash_a2a", "sha": "<40 hex>", "release_closure_digest": "<hex>"},
  "profile": "RFC-SA2A-005",
  "authority": {"grantor": "<release event id>", "epoch": 0},
  "courts": [
    {"id": "SEC-CWE-862", "outcome": "PASS|FAIL|BLOCKED",
     "expected": "typed_refusal|zero_unauthorized_consequence",
     "anti_vacuity": {"mutation_reverted_fails": true},
     "command": "<argv>", "exit": 0, "evidence_digest": "<hex>"}
  ],
  "claims": {"advertised": 0, "courts_passed": 0, "courts_missing": []},
  "supply_chain": {"sbom_digest": "<hex>", "provenance": "<attestation ref>",
                   "native_digests": {"hddl_cli": "<hex>", "graphlaw_host": "<hex>"}},
  "replay": {"command": "<argv>", "byte_identical": true},
  "standing": "derived from courts, never stored"
}
```

Each field maps to the receipt terms: identity (subject), authority, consequence (courts),
replay, standing. A court with no anti-vacuity evidence carries no bits and MUST count as
missing.

## 14. Falsification

The profile is falsified by any of:

- a forged authority, exact-subject mutation, forged prepared receipt or direct effector
  call that produces a consequence;
- a second effect for one effect identity under any input representation;
- a court that still passes when its guard is reverted (vacuous court);
- a candidate-plane process that can read a provider or target credential;
- a capability executable without an admitted release event under the strict profile.

The 22 release attacks and the per-CWE courts are in the court matrix. Attempts made for
this RFC: only read-only inspection and grep. No court was run. EXISTS in the matrix means a
test exists whose removal-of-protection failure was verified by reading it, not that it ran. Every
status here is UNVERIFIED
as a standing until its court runs.

## 15. Relationship to RFC-003 and RFC-004

RFC-003 records the implementation-derived protocol and the bypass candidates B1 to B11.
RFC-004 states the core law, consequence protocol (section 11), security boundary
(section 21) and required implementation convergence (section 27). This RFC adds a
class-level security profile on top: it does not change the RFC-004 protocol, it states which
weakness classes must be unable to reach consequence and which courts prove it. Court
dependencies on RFC-004 sections are in the matrix. Where this RFC and RFC-004 differ,
RFC-004 governs the protocol and this RFC governs security claims.

## 16. Evidence appendix

| Claim | Classification | Evidence | Falsifier | Notes |
|---|---|---|---|---|
| 5 named kernel files: no exec primitive | OBSERVED | grep | SEC-CWE-078 | replay excl. |
| SQL and HTML representations absent | OBSERVED | grep lib/ native/ | SEC-CWE-089 | prose only |
| Kernel decode is [:safe] only | OBSERVED | receipt_outbox.ex:524 | SEC-CWE-502 | no MAC |
| Unsafe decode in fixtures | OBSERVED | chicago/fixtures:229,328 | SEC-CWE-502 | test-only |
| Admission is a denylist | OBSERVED | command_bus.ex:952-955 | SEC-CWE-863 | :model |
| Anchor local; durable check in-flight | OBSERVED | anchor.ex:33-38,135 | SEC-CWE-284 | HEAD no |
| on_cancel bypasses kernel | OBSERVED | agent.ex:1244 | SEC-CWE-862 | task owner |
| Generic observe skips anchor | OBSERVED | agent.ex:829-857 | SEC-CWE-862 | opt-in strict |
| Release mode defaults legacy | OBSERVED | capability_release.ex:294 | SEC-REL-19 | strict opt-in |
| OCEL egress has no SSRF policy | OBSERVED | ocel_forwarder.ex:239 | SEC-CWE-918 | Req redirects |
| Push webhook admitted, pinned | OBSERVED | push_delivery.ex:105-135 | SEC-CWE-918 | policy test |
| HDDL solver has no timeout | OBSERVED | hddl_solver.ex:100 | SEC-CWE-770 | candidate only |
| Semantic route never reaches DO | DERIVED | agent.ex:596-652 | SEC-REL-13 | callers ungrepped |
| Env inherited by children | DERIVED | wasmtime_runtime.ex:481 | SEC-REL-22 | no env: opt |
| Rust: no unsafe, Command::new | OBSERVED | grep native/**/*.rs | SEC-CWE-787 | exit :442 |
| wasmex NIF checksum pinned | UNKNOWN | mix.lock:77,96 | SEC-REL-19 | artifact file |
| Outbox receipt_id safe | UNKNOWN | receipt_outbox.ex:464,473 | SEC-CWE-022 | charset unread |
| No runtime code acquisition (M8) | OBSERVED | grep Mix.install | SEC-CWE-078 | tooling |

## 17. Audit record

An adversarial audit of the first draft (22 problems, 40 citations checked, 10 wrong) was
applied. Result per problem, in audit order:

| # | Problem | Change |
|---|---|---|
| 1 | G2 stale: anchor check requires outbox entry in-flight | G2 states HEAD and in-flight |
| 2 | CWE-94 GUARDED while citing unguarded apply | 94 set to PRESENT_UNGUARDED |
| 3 | CWE-20 cited wrong lines for a "1 MB cap" | cite plug.ex:383,389-390; limit unverified |
| 4 | ownership.ex range blended two mechanisms | 44-50 and 52-66 split |
| 5 | ocel_forwarder path and redirect claim | full path; redirects marked Req default |
| 6 | wasmex paths; 125 bounds unproven | paths fixed; 125 set to UNKNOWN |
| 7 | compiler.ex:143 has no timeout | real line semantic/compiler.ex:148 |
| 8 | application.ex:140 and wasmtime_runtime.ex:481 | cited mix.exs:400; env marked DERIVED |
| 9 | matrix: 367 and REL-08 over-credited as race | see matrix Table F, race MISSING |
| 10 | 837 coverage cited a negative control | see matrix; scoped to stores |
| 11 | EXISTS defined by criteria never met | EXISTS redefined (Status, matrix) |
| 12 | refusal codes described as existing | matrix marks PROPOSED, maps to real codes |
| 13 | ELIM/ABSENT stated on grep only | labeled grep-only; 352 host note |
| 14 | kernel glob included offline_replay.ex | narrowed; single-apply claim corrected |
| 15 | M1, M4, M5, M8 called OBSERVED absent | reworded; M8 grep added |
| 16 | "protocol steps exist" | step table added (section 5) |
| 17 | "refuses only" model source | reworded to denylist plus match |
| 18 | OWASP rows asserted "none" | marked UNVERIFIED; wire vs in-BEAM split |
| 19 | CWE 494 and 522 have no court | removed from matrix CWE column |
| 20 | "status" used for two axes | renamed Code state and Court coverage |
| 21 | supply-chain sub-claims uncited | release.yml lines cited, marked not run |
| 22 | native crate grep, 710 lines | exact grep, exit paths, Command::new grepped |

## See Also

- `docs/rfc/RFC-SA2A-005-cwe-court-matrix-v26.9.28.md`
- `docs/rfc/RFC-SA2A-004-v26.9.28.md`
- `docs/rfc/RFC-SA2A-003-v26.9.28.md`
- `docs/rfc/RFC-SA2A-002-v26.9.16.md`
