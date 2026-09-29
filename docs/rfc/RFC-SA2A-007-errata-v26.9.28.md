# RFC-SA2A-007-errata-v26.9.28

Errata and restatement of RFC-SA2A-004, RFC-SA2A-005 and RFC-SA2A-006 so that every
normative requirement is achievable, non-contradictory and testable. Nothing is silently
weakened: each change quotes the original text, gives the defect, and states the
replacement.

**Status:** PROPOSED NORMATIVE (errata; supersedes the quoted text where it conflicts)
**Version:** v26.9.28
**Subject at authoring:** `/Users/sac/ash_a2a` main at
`80b77e225814d7a10a724e5ac01318600c71ee4c` (OBSERVED by `git rev-parse HEAD`). No test,
build or mix command was run for this document. Every "current" statement is UNVERIFIED by
execution unless it says otherwise.
**Last Updated:** 2026-09-28
**Target claim:** SA2A-C3 (RFC-006 section 31), independence tier I2, 2-of-3 signers.

## Contents

1. Decisions this errata conforms to
2. Reading rules
3. Errata items E-A to E-Q
4. Conformance statement grammar
5. Traceability table
6. Rejected or narrowed items
7. See Also

## 1. Decisions this errata conforms to

The operator decided the following; each is treated as O* by testimony and is not
re-litigated here.

1. Requirements that are impossible or contradictory are restated (this file) and the
   implementation conforms to the restatement.
2. The target claim is C3: C2 plus k-of-n with a signer-independence court and a
   resource-conservation court. There is no post-quantum requirement at C3. Signers:
   MacBook Touch ID (Secure Enclave P-256), iPhone Face ID (Secure Enclave P-256), and an
   automated AuthorityService policy key; k=2, n=3.
3. An opt-in `:dev_bypass` profile exists and is guarded (E-L).
4. XaaS terminates in `ConsequenceKernel`; a trusted gateway mints `effect_instance_id`.
5. The toolchain moves to OTP 29.1.1 and Elixir 1.20.4-otp-29. ML-DSA and SLH-DSA exist in
   `:crypto` on OTP 28.3 and later; C3 does not need them; ES256 verification works on every
   supported OTP.

## 2. Reading rules

- Each item has five parts: **Original** (quoted, with section), **Defect**,
  **Restated** (normative), **Falsifier** (the court that makes it testable) and
  **Profile impact**.
- "Avatar" names the simulated standards reviewer whose reasoning supports the defect: NIST
  800-160 (systems security engineering), NIST 800-207/800-53 (zero trust and controls),
  SSDF/SLSA (supply chain), MITRE CWE, MITRE ATT&CK/OWASP, CISA Secure-by-Design,
  cryptography/key management, Erlang/OTP+Ash. These are simulated reviews, not official
  positions of those organizations.
- Court ids of the form `ERR7-<item>-<n>` are NEW and PLANNED. No court in this file exists
  or has run.
- Where this file and a quoted original differ, this file governs. Quoted RFC text is kept
  in place in the source RFC; it is not edited.

## 3. Errata items

### E-A Theorem premises, threat model, assumptions, hosting scope

**Original.** RFC-006 section 1: "`Compromise(ControlPlane)` does NOT imply
`UnauthorizedActuation`" and "The system MUST remain able to refuse unauthorized actuation
when the attacker controls the AshA2A application host, provided the independently
protected authority and actuation domains remain uncompromised." RFC-006 section 33:
"`Compromise(C)` does not imply `D(E)`."

**Defect.** The theorem has unstated premises, so it is unfalsifiable as written (NIST
800-160: a security claim without assumptions and a threat model is not a claim). It also
silently covers a co-hosted authority or actuator, where host root compromise defeats it
(NIST 800-207: trust is per-resource and per-host). Avatar reasoning: the theorem is true
only conditional on premises the RFC never lists.

**Restated.**
- The theorem MUST be stated with explicit premises. For subject S and effect E:
  - **P1** the authority domain is uncompromised beyond the tolerated count (fewer than k
    signers at C3);
  - **P2** the actuator domain is uncompromised;
  - **P3** private signing keys are in custody outside the control plane (E-C, E-E);
  - **P4** the verifier code (sa2a_wire Verifier and actuator fence) is correct for the
    stated suite;
  - **P5** there is no alternate effector path reachable without the actuator (complete
    mediation, graph property, RFC-006 section 18);
  - **P6** clock trust: the actuator's clock is within a stated skew of trusted time;
  - **P7** the crypto primitives (SHA-256, ECDSA P-256, Ed25519, `:crypto` and OpenSSL) hold;
  - **P8** revocation and policy views at the actuator are fresh within the bound of E-J.
  The theorem reads: under P1..P8, `D(E) => A(E)` and `Compromise(C)` alone does not imply
  `D(E)`.
- The assurance case (`docs/assurance/sa2a-assurance-case-v26.9.28.md`) MUST carry an
  assumptions register, a residual-risk register and a threat model with assets, actors and
  trust boundaries. A claim MUST NOT be made if any premise lacks a register entry.
- **Hosting scope.** A co-hosted authority or actuator does not survive compromise of the
  host root. Claims MUST be scoped by hosting evidence, ordered by strength: separate OS
  user < separate namespace or cluster < separate physical host. The conformance statement
  (section 4) MUST name the scope achieved. Same-host, separate-OS-user is the minimum for
  any C2 or C3 claim and MUST be labeled as such.

**Falsifier.** `ERR7-A-1`: a claim document lacking any of P1..P8, the two registers or the
hosting scope is refused by the claim validator. `ERR7-A-2`: a run where authority and
actuator share a host with the control plane and the statement asserts a scope stronger
than same-host is refused (scope derived from deployment evidence, never from a field the
control plane writes).

**Profile impact.** C0 and C1 are unaffected. C2 and C3 gain the premises and the scope
requirement. `:dev_bypass` and `:legacy_compat` cannot carry any theorem claim.

### E-B Exactly-once DO is impossible

**Original.** RFC-006 section 9: "`SameEffectInstance => AtMostOneAdmittedDO`" combined with
RFC-004 section 11 "Exactly one component owns the transition" and RFC-006 section 29:
"exactly one consequence occurred and is reconcilable".

**Defect.** Exactly-once across a crash between DO and commit is impossible without a
cooperating idempotent target (distributed-systems result; Erlang/OTP avatar: a worker can
die after the external call and before any local write). RFC-006 section 21 already implies
at-most-once plus unknown outcome, so the wording "exactly one" in section 29 contradicts
it. Framework retries (Oban `max_attempts`, Reactor compensation, FLAME re-run) turn an
unknown outcome into a duplicate consequence.

**Restated.**
- The protocol guarantees **at-most-once DO per `effect_instance_id`** (an admitted DO
  either has a durable terminal record or is `UNKNOWN_OUTCOME`).
- A crash or timeout after the actuator may have applied the effect MUST record
  `UNKNOWN_OUTCOME` and MUST keep the effect claim. The only exits are: observation,
  reconciliation against the target, compensation under separate authority, or explicit
  administrative resolution signed under E-C. The exit `reconcile-only` MUST NOT include
  re-execution.
- Oban, Reactor and FLAME retry of an effect job whose last state is `unknown_outcome` MUST
  NOT happen: such jobs MUST be configured `max_attempts: 1` for effect steps, MUST return a
  non-retryable discard on `UNKNOWN_OUTCOME`, and Reactor compensation MUST NOT invoke DO.
  "Exactly one consequence occurred" in RFC-006 section 29 is replaced by "at most one".

**Falsifier.** `ERR7-B-1`: kill the worker between actuator apply and commit (real process);
assert one target-side counter increment at most and state `UNKNOWN_OUTCOME`. `ERR7-B-2`:
restart Oban, Reactor and FLAME with the unknown effect queued; assert zero further DO.
`ERR7-B-3`: revert-mutation (allow retry) must fail `ERR7-B-1`.

**Profile impact.** Applies to C1, C2, C3 identically. `:legacy_compat` receipts state
"retry semantics unspecified".

### E-C Independence tiers and signer counting

**Original.** RFC-006 section 15: "independently held keys and an admitted k-of-n set of
valid signatures (`DO => ValidSigners >= k`)." RFC-006 section 31 C3: "signer independence
court".

**Defect.** "Independent" is undefined. Counting signatures, not custodians, lets one
person or device sign twice with two keys (cryptography avatar; NIST 800-53 separation of
duties). The current `SignerSet` counts unique signer labels and checks no independence
(_LANES_V3 C2 finding 3).

**Restated.**
- Independence tiers, each strictly stronger than the previous:
  - **I1** distinct key;
  - **I2** distinct device custody (each key is non-exportable in a different physical
    device or HSM);
  - **I3** distinct person;
  - **I4** distinct organization.
- The verifier MUST count a signature only if its `kid` is present in the registry
  (X3, integrity-sealed), the key is not revoked at the signed `revocation_epoch`, and the
  registry maps the `kid` to a `custodian_id`. Distinct signers are counted over distinct
  `custodian_id` values, never over `kid` or label. The independence tier of a set is the
  minimum tier over each pair of counted signers.
- The C3 claim MUST state its tier. This operator's tier is **I2**: MacBook Secure Enclave,
  iPhone Secure Enclave, and an AuthorityService policy key held by a separate OS user
  (custodian_id distinct per device and service). It is not I3, because the same person may
  hold both Apple devices; the claim MUST say so.

**Falsifier.** `ERR7-C-1`: two valid signatures from two `kid` values that map to one
`custodian_id` count as one signer and fail the 2-of-3 quorum. `ERR7-C-2`: an unregistered
`kid` with a valid signature counts zero. `ERR7-C-3`: a revoked `kid` counts zero.
`ERR7-C-4`: the statement generator refuses to print tier I3 when custodians map to one
person.

**Profile impact.** C3 only. C2 has one authority and reports tier I1 by default.

### E-D Node distribution across trust domains

**Original.** RFC-006 section 23: "The security kernel SHOULD remain ordinary memory-safe
BEAM code, avoiding ... unrestricted node distribution".

**Defect.** SHOULD NOT is not enforceable, and Erlang distribution gives any connected node
full remote-execution (`:erpc`, `:rpc`) once the cookie is known (Erlang/OTP avatar). A
distribution link between the control plane and the authority or actuator domain defeats
the trust boundary regardless of certificates.

**Restated.**
- Across trust domains (control plane to authority; control plane to actuator; authority to
  actuator), Erlang distribution MUST NOT be used. Release builds for the authority
  service and actuator MUST set `RELEASE_DISTRIBUTION=none`.
- Cross-domain traffic MUST use a typed wire over a Unix domain socket (same host) or mTLS
  (different host), with a schema-validated codec from sa2a_wire. Each domain MUST use a
  separate Erlang cookie and, where mTLS is used, a separate CA whose private key is not on
  the control plane.
- Within one trust domain, distribution MAY be used and SHOULD be restricted by cookie and
  TLS distribution.

**Falsifier.** `ERR7-D-1`: a release-artifact court inspects `env.sh`/`vm.args` for
`RELEASE_DISTRIBUTION=none` in authority_service and actuator releases and fails if absent.
`ERR7-D-2`: from a control-plane node, `Node.connect` to the actuator host with the control
plane cookie fails and no epmd port is reachable. `ERR7-D-3`: revert (enable distribution)
must fail `ERR7-D-1`.

**Profile impact.** C2 and C3 MUST. C0 and C1 SHOULD NOT (unchanged from RFC-006).

### E-E Signature algorithm registry and signed-message structure

**Original.** RFC-006 section 14: "The baseline suite MAY use NIST-standardized ML-DSA
(FIPS 204) or SLH-DSA (FIPS 205). The protocol remains algorithm-agile; algorithm identity
is bound into the signed object."

**Defect.** Underspecified and mismatched to the hardware. Secure Enclave keys are P-256
ECDSA, not ML-DSA; the actual signers cannot produce the "baseline" suite (cryptography
avatar). The RFC gives no message layout, so domain separation, replay keying and DER
strictness are unspecified. Secure Enclave ECDSA is not low-s normalized, so signature
bytes are malleable and cannot key replay protection.

**Restated.**
- **Algorithm registry.** Suite ids are registry entries, closed and versioned:
  - `ES256`: ECDSA on P-256 with SHA-256, signature X9.62 DER. MUST be supported. This is
    the classical profile and the C3 profile.
  - `EdDSA`: Ed25519. MAY be allowed (AuthorityService policy key).
  - `ML-DSA-44`, `ML-DSA-65`, `ML-DSA-87`, `SLH-DSA-*`: OPTIONAL. If enabled, only via OTP
    28.3 or later `:crypto` atoms (`mldsa44`, `mldsa65`, `mldsa87` for ML-DSA) after a
    runtime capability probe; absent atoms mean the suite is UNSUPPORTED (typed), never
    silently downgraded. Unregistered suites MUST be refused.
- **Signed message.** The signer signs exactly these bytes:

```text
"SA2A-C2-APPROVAL-v1" || 0x00 || JCS({
  v, alg, kid, effect_digest, principal, policy_epoch, revocation_epoch,
  generation, nonce, not_before, expires, audience })
```

  `JCS` is RFC 8785 under the E-F policy. `effect_digest` is `sha256:<64 hex>` of the JCS of
  the PreparedEffect. `audience` names the actuator. `alg` and `kid` are inside the signed
  bytes.
- **Verifier duties.** The verifier MUST (1) recompute `effect_digest` from durable state
  (never from the certificate body); (2) verify against the registry key for `kid` and the
  registry `alg` for that key (not the certificate's `alg` field alone); (3) enforce strict
  DER: single canonical encoding, no trailing bytes, r and s in range 1..n-1, no negative
  integers, minimal length; (4) not require low-s, and MUST NOT rely on signature bytes for
  uniqueness; (5) key replay protection on `(kid, nonce)`, retained at least until `expires`
  plus the E-J staleness bound.
- Verification on every supported OTP MUST use `:crypto.verify(:ecdsa, :sha256, msg, sig,
  [pub, :secp256r1])` semantics or an equivalent audited path.

**Falsifier.** `ERR7-E-1`: known-answer vectors, including one produced by a real Secure
Enclave key, verify. `ERR7-E-2`: flip each field of the signed structure (alg, kid, digest,
principal, epochs, generation, nonce, not_before, expires, audience) and each is refused.
`ERR7-E-3`: BER-nonstrict DER, trailing byte, and high-s and low-s variants: strict cases
refused; the low-s and high-s twins of one signature are both valid but the second use of
`(kid, nonce)` is refused as replay. `ERR7-E-4`: a certificate whose `alg` field is
downgraded is refused. `ERR7-E-5`: with an OTP lacking `mldsa44`, enabling ML-DSA yields
typed `unsupported_suite`.

**Profile impact.** C2 MUST ES256 (or EdDSA). C3 MUST ES256 for the two Secure Enclave
signers. PQ suites are OPTIONAL at every profile.

### E-F JCS policy

**Original.** RFC-004 section 5: "Protocol JSON objects are canonicalized with RFC 8785
(JCS) before hashing." RFC-006 section 10: "map key representation, atoms ... MUST NOT
change semantic identity."

**Defect.** RFC 8785 alone leaves floats, large integers and key collisions unresolved for
security use (I-JSON ambiguity). Elixir maps admit atom keys and string keys that collide
after normalization; JCS number serialization for floats is a portability hazard across
runtimes. Current code has a blanket rescue in `identity/canonical.ex` (_LANES_V3 L01).

**Restated.** For every signed or digested object the canonicalizer MUST:
- reject floats (all numbers are integers or strings);
- represent integers with absolute value above 2^53 - 1 as decimal strings, and reject a
  JSON number outside that range;
- reject duplicate keys, and reject an object where an atom key and a string key normalize
  to the same string;
- reject tuples, PIDs, refs, functions and other non-JSON terms with typed errors;
- cap total size and nesting depth (defaults: 1 MiB and depth 32, configured per profile
  and recorded in the release);
- normalize strings to NFC only where the schema says so; otherwise reject non-UTF-8;
- pass the RFC 8785 Appendix B number-formatting and sorting vectors, and the existing
  cross-runtime vectors, byte-equal in every runtime that verifies (Elixir kernel and
  sa2a_wire, and one runtime outside the BEAM per RFC-004 section 23).

**Falsifier.** `ERR7-F-1`: Appendix B vectors byte-equal, checked by an independent
recompute (python3 with a named skip). `ERR7-F-2`: each rejection class has a negative
vector that must return its typed error. `ERR7-F-3`: 2^53 integer as number is refused and
as string accepted. `ERR7-F-4`: oversize and over-deep inputs are refused before hashing.

**Profile impact.** C1 and above MUST. C0 SHOULD. `:legacy_compat` may read legacy digests
but MUST stamp them `legacy_digest`.

### E-G Vocabulary map, CWE rows, counts and elimination claims

**Original.** RFC-005 profile section 10 uses target labels `ELIM`, `ABSENT-K`, `CONTAIN`,
`CLASS`; RFC-006 section 30 uses `UNREPRESENTABLE`, `UNREACHABLE`, `CONTAINED`,
`RESIDUAL`. RFC-005 section 10.5: "The enumerated eliminate and absent-K rows (14 protocol,
7 memory, 7 extras) total 28. The operator direction says 27." Section 10.4 rows count 32.

**Defect.** Two vocabularies for one idea; missing CWE rows; mislabeled rows; three
different counts (27, 28, 32). CWE avatar: an elimination claim without a wired-path court,
a mutation revert and an independent oracle is an assertion. CWE-476 is placed in the
memory-corruption court although it is a null-dereference class (in BEAM it surfaces as a
`MatchError`/`ArgumentError`, contained by supervision, not eliminated). The CWE-94 row
describes the defect "data-selected module, function or eval" but the observed defect (an
`on_cancel` apply reachable by a task owner) is an authorization gap, CWE-862.

**Restated.**
- **Vocabulary map** (binding; use RFC-006 terms in new text):

| RFC-005 label | RFC-006 label | Meaning |
|---|---|---|
| ELIM | UNREPRESENTABLE | the primitive does not exist in reachable values |
| ABSENT-K | UNREACHABLE | absent from the kernel; state unreachable via admitted graph |
| CONTAIN | CONTAINED | defect cannot independently reach protected DO |
| CLASS | RESIDUAL unless a court upgrades it | still depends on this mechanism |

- **Missing rows to add** to the matrix, each with a court and target label:
  CWE-330 (insufficient randomness: nonces, effect_instance_id), CWE-345 and CWE-347
  (insufficient verification of data authenticity, improper signature verification),
  CWE-532 (sensitive information in logs), CWE-1188 (insecure default initialization of
  resource: unkeyed outbox, `:legacy` release mode, tmp-dir store).
- **Mislabeled rows.** The CWE-476 row moves from UNREACHABLE (ABSENT-K) to CONTAINED, court
  `SEC-CWE-476` (fault containment: a MatchError in the wasmex session leaves the kernel
  intact). The CWE-94 row keeps CWE-94 for the data-selected-apply class and adds CWE-862
  for the `on_cancel` defect; the observed defect is filed under CWE-862.
- **Counts.** The counts 27, 28 and 32 are retired. SA2A MUST NOT print a number of
  eliminated CWEs. The receipt carries `courts_passed` and `courts_missing` as measured.
- **Rule.** A UNREPRESENTABLE or UNREACHABLE claim is admitted only with all four: (1) a
  court on the wired production path, (2) a mutation-revert that makes the court fail,
  (3) an independent oracle (a check not derived from the code under test), (4) the default
  release configuration (not an opt-in mode). Otherwise the label is CONTAINED or RESIDUAL.

**Falsifier.** `ERR7-G-1`: the matrix generator fails if any UNREPRESENTABLE or UNREACHABLE
row lacks the four fields. `ERR7-G-2`: a count literal ("eliminates N") in any doc fails a
doc-lint. `ERR7-G-3`: each new CWE row has a court id that resolves to a file.

**Profile impact.** Claim-labeling only; applies to every profile.

### E-H Meaning of "EXISTS" and the 35 C2 courts

**Original.** RFC-005 matrix conventions: "EXISTS means a test exists whose
removal-of-protection failure was verified by reading it; it does not mean the test was
run." RFC-006 section 26 lists the control-plane compromise court; `test/ash_a2a/c2/
court_001..035.exs` were written toward it.

**Defect.** "Verified by reading" is a weak status that has already been over-credited
(the matrix audit re-rated 22 rows). The 35 C2 court files each assert one property, that
two `PreparedEffect` digests differ (_LANES_V3 C2 finding 5) and are not matched by
`_test.exs`. They carry no bits about certificates, quorum or actuation.

**Restated.**
- **EXISTS** for a court means: read-verified AND revert-fails (a recorded mutation run in
  which reverting the guarded code makes the court fail). Read-verified without a recorded
  revert-fail is PARTIAL. No status implies the court ran green on an exact subject; that is
  a separate field (`run_receipt`).
- The 35 `court_NNN.exs` files that assert only digest inequality are **void as conformance
  evidence** until each is replaced by a court that exercises the certificate, verifier,
  signer quorum, actuator fence or claim store it names. They MAY remain as regression
  tests for digest inequality only, renamed to reflect that.
- Evidence nodes in the assurance case use PLANNED and EXISTS-UNVERIFIED-BY-RUN; nothing is
  marked verified in a document.

**Falsifier.** `ERR7-H-1`: a court linter lists any court whose body contains only a
digest-inequality assertion and marks it void. `ERR7-H-2`: the status renderer refuses
EXISTS without a mutation record path. `ERR7-H-3`: `mix test` picks up every court (naming
or `test_pattern`), asserted by counting files versus tests run.

**Profile impact.** All. C2 and C3 require courts that satisfy the criteria in RFC-005
"Court entry criteria" (exact SHA, real collaborators, final-state assertions, revert-fail,
receipt).

### E-I What You See Is What You Sign (WYSIWYS)

**Original.** RFC-006 section 13: "`E = H(version, principal, subject, capability,
effectInstance, inputDigest, resourceBounds, policyEpoch, expiry)`; `Certificate =
Sign_Authority(E)`."

**Defect.** The RFC binds a signature to a digest but not to what the human approver saw.
If the control plane renders the approval screen, a compromised control plane shows one
effect and submits the digest of another (NIST 800-207; ATT&CK avatar: UI-spoofing of the
confirming factor). A control-plane-rendered UI cannot satisfy the human-approval intent.

**Restated.**
- For every human-approved signer (MacBook Touch ID, iPhone Face ID) the approval MUST be
  rendered by an **independent renderer**: a native approver application on the approver
  device that receives the canonical PreparedEffect bytes (not a digest alone and not
  control-plane HTML), recomputes `effect_digest` locally from those canonical bytes,
  displays a human-readable form derived from those bytes, and then asks the Secure Enclave
  to sign the E-E message. The renderer MUST NOT trust any display string supplied by the
  control plane.
- A web page served or proxied by the control plane MUST NOT be accepted as an approver UI
  for C2 or C3.
- The renderer receives the effect through a channel the control plane cannot rewrite
  undetected (the authority domain relays the canonical bytes; the app checks them against
  the digest the authority displays out of band).

**Falsifier.** `ERR7-I-1`: a mutation harness alters the display fields in transit while
keeping the digest; the native app refuses (digest recomputed from bytes differs).
`ERR7-I-2`: an approval submitted from a browser origin served by the control plane is
refused by the AuthorityService (signer class `native_approver` required for the human
signer). `ERR7-I-3`: revert (accept a supplied digest) must fail `ERR7-I-1`.

**Profile impact.** C3 for human signers MUST. C2 with a human approver MUST. The automated
AuthorityService signer has no renderer and instead evaluates a policy bound to the same
digest.

### E-J Revocation staleness bound

**Original.** RFC-006 section 16: "The actuator MUST independently verify, immediately
before DO: ... revocation state; ..." RFC-004 section 10: "authority MUST be checked ...
again immediately before DO ... against the authoritative source where the model supports
revocation."

**Defect.** "Revocation state" has no freshness bound. An actuator with a cached, arbitrarily
old revocation list satisfies the letter of the text (NIST 800-53 / 207: continuous
verification needs a staleness limit; CWE-367 avatar: time-of-check to time-of-use).

**Restated.**
- The release profile MUST declare `max_revocation_staleness_seconds` (default 300 for
  `:strict`; this value is a default, and is part of the pinned release configuration).
- The actuator MUST record the timestamp (trusted-time anchor per E-O) and epoch of its
  last successful revocation and policy refresh, and MUST refuse with a typed refusal
  `refused_authority:revocation_view_stale` when `now - last_refresh > N`.
- A signature made under `revocation_epoch` older than the actuator's known epoch MUST be
  refused; the signed `revocation_epoch` is compared for equality or greater-or-equal per
  the registry rule, never ignored.
- Refresh failure fails closed: the actuator does not act until refresh succeeds.

**Falsifier.** `ERR7-J-1`: freeze the revocation feed for N+1 seconds (injected clock) and
assert refusal `revocation_view_stale`. `ERR7-J-2`: revoke a `kid`, call within N seconds
with the refreshed view, assert refusal `key_revoked`. `ERR7-J-3`: revert (drop the
staleness check) must fail `ERR7-J-1`.

**Profile impact.** C2 and C3 MUST. C1 SHOULD apply the same bound to its broker.

### E-K Approval TTL bound into the signed message

**Original.** RFC-006 section 13: "`expiry`" appears inside `E`, and section 16 requires
"expiry" verification. It does not bound how long an approval may live.

**Defect.** An unbounded or very long TTL lets a stolen or leaked approval be replayed
long after the human intent (cryptography avatar; the current Certificate struct carries
`expiry` from the caller).

**Restated.**
- Approval TTL is **bound into the signed message** as `not_before` and `expires` (E-E).
  The profile declares `max_approval_ttl_seconds` (default 300 for human signers and 900
  for the automated signer; pinned in the release).
- The verifier MUST refuse when `expires - not_before` exceeds the profile maximum, when
  `now < not_before - skew`, or when `now >= expires + skew` with `skew` at most the
  profile's declared clock skew (default 5 seconds).
- The actuator MUST NOT extend a TTL; a longer window requires a new signature.

**Falsifier.** `ERR7-K-1`: certificates with TTL just under, at, and over the maximum;
over-max is refused. `ERR7-K-2`: expired, not-yet-valid, and skew-edge cases with an
injected clock. `ERR7-K-3`: mutate `expires` after signing; signature fails (E-E).

**Profile impact.** C2 and C3 MUST.

### E-L The dev_bypass profile (normative)

**Original.** RFC-004 section 24: "Legacy behavior MAY exist only through an explicit
compatibility profile that identifies itself in receipts and does not claim strict
conformance." There is no development profile, so local development either runs with the
full strict machinery (Secure Enclave, two devices) or drifts into an ad hoc unguarded mode.

**Defect.** Without a defined development profile, developers create silent bypasses that
survive into releases (CISA Secure-by-Design: secure by default, with unsafe modes explicit
and hard to enable in production). RFC-005 gap G7 shows `:legacy` release mode as a
default, which is exactly that failure.

**Restated.** A profile `:dev_bypass` MAY exist, opt-in, and MUST satisfy all of:
1. **Compiled out of prod.** The dev-bypass code is compiled only when the build profile is
   not a production release. Production release artifacts MUST NOT contain the dev-bypass
   modules (checked by inspecting the release beam list).
2. **Selection.** It is selected only by the release/build profile (E-M). It MUST NOT be
   selectable by call options, request data, environment variables read at runtime,
   application config changed at runtime, or any candidate-plane input.
3. **Boot banner.** At boot the system MUST log an unmissable banner on every boot and on
   `SecurityProfile` info that the profile is `:dev_bypass` and unsafe.
4. **Receipt stamp.** Every receipt, journal record and OCEL event created under it MUST
   carry `profile: :dev_bypass` inside the integrity-protected content.
5. **AuthorityService refuses.** The AuthorityService MUST refuse to sign anything while it
   detects `:dev_bypass` in the request context or its own build, and MUST NOT accept a
   dev_bypass-stamped effect for a production `kid`.
6. **Actuator refuses.** The Actuator MUST refuse to act on any effect stamped
   `:dev_bypass`, and MUST refuse if its own profile is `:dev_bypass` while any real
   effector credentials are configured.
7. **Verifier reports.** The conformance verifier MUST report NOT CONFORMANT while the
   profile is on (section 4).
8. **No promotion.** Evidence produced under `:dev_bypass` MUST NOT count toward any
   conformance claim, and MUST NOT be replayed into a `:strict` receipt chain.

**Falsifier.** `ERR7-L-1`: a production release (`MIX_ENV=prod` release) contains no
`SecurityProfile.DevBypass` beam. `ERR7-L-2`: setting the profile through call opts,
request data, env var or runtime config leaves the profile `:strict` (typed
`forbidden_opt`). `ERR7-L-3`: under dev_bypass, AuthorityService returns
`refused_profile:dev_bypass_no_sign` and the Actuator returns
`refused_profile:dev_bypass_no_act`, each with zero effect. `ERR7-L-4`: every receipt made
under it carries the stamp and a tampered stamp fails the seal. `ERR7-L-5`: the verifier
outputs NOT CONFORMANT. `ERR7-L-6`: boot log contains the banner.

**Profile impact.** Defines `:dev_bypass`. It is disqualifying for any claim.

### E-M Profile vocabulary and SecurityProfile selection

**Original.** RFC-004 section 24 (compatibility profile) and RFC-006 section 32: "Remove
... caller-selected security modes". RFC-005 profile refers to `:strict` in prose only.

**Defect.** The names `:strict`, `:legacy`, `:dev`, "compat", "release mode" and "profile"
name overlapping concepts, and `SecurityProfile` does not exist yet (_LANES_V3). A profile
selectable at runtime by config or options is a caller-selected security mode.

**Restated.**
- The **security profiles** are exactly: `:strict` (default), `:dev_bypass` (E-L, opt-in),
  `:legacy_compat` (explicit, stamped, per RFC-004 section 24, never claims conformance).
  The old names `:legacy` and `:dev` are retired as profile values; `:legacy` release mode
  becomes `:legacy_compat`.
- The **conformance profiles** C0, C1, C2, C3 are claims (section 4), not runtime modes.
  They are orthogonal: a `:strict` deployment MAY satisfy C0 through C3 depending on
  deployed components.
- `SecurityProfile` is selected only by the release/build profile (a value baked into the
  release at build time and pinned in `priv/security_profile/release.json`), never by call
  options, request data, runtime environment variables or runtime `Application.put_env`.
- `:legacy_compat` MUST be stamped in receipts, MUST NOT be the default, and MUST require an
  explicit build-time selection distinct from `:strict`.

**Falsifier.** `ERR7-M-1`: `SecurityProfile.current/0` ignores every runtime override
(options, env, `put_env`) and returns the baked value. `ERR7-M-2`: a release without a
baked profile refuses to boot. `ERR7-M-3`: receipts under `:legacy_compat` carry the stamp
and the verifier reports NOT CONFORMANT.

**Profile impact.** Defines the three profile values for every conformance claim.

### E-N Stale subject pins and duplicate numbering

**Original.** Subject pins and numbering in the RFC headers (listed below).

**Defect.** Subject pins name superseded commits, so no "exact SHA" claim is true of the
current tree. Two files carry the number 005 and two carry 006, so citations such as "RFC-005
section 10" are ambiguous.

**Restated.**
- Stale pins found at authoring (main is `80b77e2`):

| Document | Pin found | Status |
|---|---|---|
| `RFC-SA2A-004-v26.9.28.md` | none (no subject SHA) | MISSING pin |
| `RFC-SA2A-005-security-profile-v26.9.28.md` | `8af1261...` (plus dirty tree) | stale |
| `RFC-SA2A-005-cwe-court-matrix-v26.9.28.md` | `8af1261...` (plus dirty tree) | stale |
| `RFC-SA2A-006-adversarial-control-plane-v26.9.28.md` | none | MISSING pin |
| `RFC-SA2A-006-existing-substrate-map-v26.9.28.md` | `492af9e` (plus untracked) | stale |
| `docs/jira/v26.9.28-kernel/HANDOFF.md` | `9cda21c...` | stale |
| `docs/jira/v26.9.28-kernel/_LANES.md` | `8af1261...` | stale |
| `docs/jira/v26.9.28-kernel/_LANES_V2.md` | none (path shorthand at "HEAD") | MISSING pin |
| `docs/jira/v26.9.28-kernel/_LANES_V3.md` | `62cd548` (tree dirty) | stale |
| `RFC-SA2A-003-v26.9.28.md` | `84bbe18...` | stale |

- Every RFC, matrix, lane map and receipt MUST name the exact 40-hex subject SHA it was
  written against, in a `Subject:` header line, and a doc-lint MUST refuse a header whose
  SHA is not an ancestor of, or equal to, the release subject under claim without an
  explicit "written against" label. A pin is evidence of the authoring subject only; it does
  not certify later commits.
- **Suffix scheme.** RFC numbers are unique across the RFC set. Existing duplicates are
  disambiguated by suffix without renaming files in this errata: `RFC-SA2A-005a` is the
  security profile, `RFC-SA2A-005b` the CWE court matrix, `RFC-SA2A-006a` the adversarial
  control-plane RFC, `RFC-SA2A-006b` the existing-substrate map. New companion documents use
  the next letter of the same number, and this errata is `RFC-SA2A-007`. Citations from
  now on use the suffix form.

**Falsifier.** `ERR7-N-1`: doc-lint fails a doc header with no 40-hex `Subject:` SHA.
`ERR7-N-2`: doc-lint fails a duplicate RFC number without a letter suffix in its front
matter or title line. `ERR7-N-3`: every cited section is checked against the suffix set.

**Profile impact.** Documentation only; blocks the conformance statement if the cited
documents lack pins (section 4).

### E-O Receipts crossing trust boundaries

**Original.** RFC-004 section 12: "Receipt bindings crossing a trust boundary MUST use an
authenticated construction; ... An implementation SHOULD bind its exact software subject."
RFC-006 section 25: "Receipts crossing trust boundaries use authenticated integrity."

**Defect.** "Authenticated construction" is satisfied today by HMAC-SHA256 with a shared
key. A shared-key MAC gives no non-repudiation: any holder of the key, including a
compromised control plane, can forge a receipt (cryptography avatar; NIST 800-53 AU-10).
Receipts carry no git SHA (RFC-003 finding), so they do not identify the software that
produced them. Erasure obligations conflict with digests that bind personal data.

**Restated.**
- Receipts that cross a trust boundary (actuator to control plane; authority to control
  plane; anything an external verifier consumes) MUST carry an **asymmetric signature**
  (ES256 or EdDSA per E-E), with `kid` and key version, over the domain-separated JCS
  content. HMAC MAY protect a local journal inside one trust domain and MUST NOT be
  presented as cross-boundary authenticity.
- Every receipt MUST carry the **software subject**: the git SHA of the producing tree and
  the release digest (SBOM-bound), inside the signed content.
- **Key identity.** The signature record carries `kid`, `key_version` and the registry
  epoch; rotation and revocation follow E-C and E-J.
- **PII commitments.** Personal data MUST NOT be bound raw into signed digests. Receipts
  bind a salted hash commitment to personal fields; erasure deletes the salt and the
  plaintext, leaving the commitment and the signature intact and verifiable.
- **Trusted-time anchor.** Receipts and epochs carry a trusted-time anchor: a timestamp
  from a declared time source (authority or actuator local clock within the declared skew,
  or an external timestamp token), with the source named in the receipt.

**Falsifier.** `ERR7-O-1`: a receipt signed with the control-plane MAC key only is refused
as cross-boundary evidence. `ERR7-O-2`: a receipt without software subject is refused.
`ERR7-O-3`: mutate `kid` or `key_version`; verification fails. `ERR7-O-4`: erase a PII
field's salt; the receipt still verifies and the plaintext is unrecoverable. `ERR7-O-5`:
an anchor older than the declared bound relative to the actuator clock is refused.

**Profile impact.** C2 and C3 MUST. C1 receipts crossing a boundary SHOULD use the same.

### E-P Secure by default

**Original.** RFC-006 section 32: "Remove ... caller-selected security modes; permissive
effect dedup for consequential effects ...". RFC-005 gap G3 (unkeyed outbox), G7
(`:legacy` release default) and _LANES_V3 (outbox default in `System.tmp_dir`, kill-switch
DETS at caller path).

**Defect.** The requirements say what to remove but not what boot must enforce, so the
default configuration still starts with unsafe stores and options (CISA Secure-by-Design:
the default must be the secure configuration; there must be no security tax to be safe).

**Restated.**
- Boot MUST call `SecurityPreflight.check!` and `ReceiptStore.boot_check` before serving
  any request; failure aborts the boot with a typed reason.
- Under `:strict` the preflight MUST refuse boot on: an unkeyed receipt outbox; an outbox or
  kill-switch path under `System.tmp_dir` or any world-writable directory; the `Memory`
  receipt store for a consequential profile; `:legacy` capability release mode; and any
  option selecting effect deduplication mode or kill-switch mode at call time (those become
  constants of the profile).
- The default, with no configuration, is `:strict` (E-M). Weakening requires a different
  build profile, not a runtime option.

**Falsifier.** `ERR7-P-1`: boot with each refused condition and assert typed refusal and no
listener started. `ERR7-P-2`: boot with a fully correct configuration succeeds. `ERR7-P-3`:
call-time options naming a dedup or kill-switch mode return `forbidden_opt`.

**Profile impact.** `:strict` MUST. `:legacy_compat` and `:dev_bypass` are the only
profiles under which any of these conditions is tolerated, and both are disqualifying.

### E-Q Supply chain

**Original.** RFC-005 profile section 7: "A conforming release MUST provide signed
provenance, locked dependencies, an SBOM, signed artifacts, no runtime dependency
acquisition, hash-pinned runtime artifacts ..., and a release closure naming every
executable dependency."

**Defect.** The list has no anchor for who may cut a release, and "signed" and "attested"
are not tied to the subject. Current status is UNVERIFIED: `release.yml` steps exist but no
artifact for this subject was produced (SSDF/SLSA avatar). Bit-for-bit reproducibility is
demanded by some readings but is not established for an Erlang release with native crates.

**Restated.**
- **Protected main:** the release subject MUST be a commit on a protected `main` (required
  reviews or admitted-court status checks, no force push).
- **Signed tag:** the release tag MUST be signed by a registered release key, and the
  conformance statement names the tag object and the commit SHA.
- **Attested release:** the build MUST emit provenance (SLSA provenance or equivalent)
  bound to the subject SHA, and an SBOM (CycloneDX or SPDX) whose digest is in the receipt.
- **Reproducible build:** the build SHOULD be reproducible; when it is not, the
  non-reproducibility is recorded as a residual risk and the artifact digest is what is
  attested. (This is the one item narrowed from the operator request; see section 6.)
- **Single release path:** one workflow produces release artifacts; a release from any other
  path is non-conformant. Native binaries and WASM modules are digest-pinned in the release
  closure.

**Falsifier.** `ERR7-Q-1`: a release attempt from a non-protected branch is refused by the
release job. `ERR7-Q-2`: an unsigned tag is refused. `ERR7-Q-3`: the receipt's SBOM digest
must equal the digest of the emitted SBOM file. `ERR7-Q-4`: a second workflow that uploads
release assets is detected by a workflow inventory court. `ERR7-Q-5`: a rebuild-diff records
whether the build is reproducible and writes the result into the residual register.

**Profile impact.** C2 and C3 MUST for protected main, signed tag, attestation, SBOM and
single release path. Reproducibility is SHOULD at every profile.

## 4. Conformance statement grammar

A release MAY make exactly one form of claim:

```text
SA2A <version> conforms to profile <Cn> at independence tier <Ti>, hosting scope <S>,
on subject SHA <H>, verified by run <R>.
```

Field definitions:
- `<version>`: the release version string (for example `v26.9.28`).
- `<Cn>`: one of C0, C1, C2, C3 (RFC-006 section 31 as restated here). The claim is the
  highest profile whose entire prerequisite chain is verified; C3 requires C2 requires C1
  requires C0.
- `<Ti>`: independence tier I1..I4 (E-C). Required for C3; C0 to C2 state `I1`.
- `<S>`: hosting scope (E-A): one of `same-host-os-user`, `namespace-or-cluster`,
  `physical-host`.
- `<H>`: the 40-hex subject SHA of the released commit (E-N, E-Q).
- `<R>`: the identifier of a verification run whose receipt validates against the receipt
  schema, was executed on `<H>`, includes all courts of the claimed profile with
  mutation-revert results, and binds the release closure digest.

The statement is a computed output of the conformance verifier, never hand-written. It
MUST be refused (the verifier prints NOT CONFORMANT with a typed reason) when any of these
holds:
- the profile is `:dev_bypass` (E-L);
- the profile is `:legacy_compat` (E-M), or any legacy option is on;
- a prerequisite is unverified: any court of the claimed profile without a passing run on
  `<H>`, any evidence node that is PLANNED or EXISTS-UNVERIFIED-BY-RUN, a missing
  assumptions or residual-risk register, or a missing pin (E-N);
- the tier `<Ti>` or scope `<S>` exceeds what deployment evidence supports (E-A, E-C);
- the subject `<H>` is not the running or released artifact (a sibling build or a stale pin);
- the supply-chain predicates of E-Q fail.

**Current status at authoring:** no claim can be made. Per `_LANES_V3.md`, C0 is PARTIAL and
C1, C2 and C3 are UNSATISFIED, and no court has a recorded run receipt.

## 5. Traceability table

Lanes L01..L20 and X1..X4 are from `docs/jira/v26.9.28-kernel/_LANES_V3.md`. NEW means no
lane exists yet and one must be added (in a later `_LANES` revision, not here).

- **E-A theorem premises, scope**: NEW (claim validator), L12, L20; Court(s): ERR7-A-1, ERR7-A-2
- **E-B at-most-once, no retry**: L10, L05, X4, NEW (Oban/Reactor/FLAME config); Court(s):
  ERR7-B-1..3
- **E-C independence tiers**: X3, X2, NEW (claim generator); Court(s): ERR7-C-1..4
- **E-D no cross-domain distribution**: L12, X2, X4; Court(s): ERR7-D-1..3
- **E-E algorithm registry, signed message**: X1a, X2, X3, X4; Court(s): ERR7-E-1..5
- **E-F JCS policy**: L01, L02, X1a; Court(s): ERR7-F-1..4, SEC-M14-1..4
- **E-G vocabulary, CWE rows, counts**: L20, NEW (matrix rows); Court(s): ERR7-G-1..3,
  SEC-CWE-330, 345, 347, 532, 1188, 476
- **E-H EXISTS meaning, void C2 courts**: L20, L08, X1a, X4; Court(s): ERR7-H-1..3
- **E-I WYSIWYS native approver**: NEW (approver apps), X2; Court(s): ERR7-I-1..3
- **E-J revocation staleness**: X3, X4, L11; Court(s): ERR7-J-1..3
- **E-K approval TTL**: X1a, X2; Court(s): ERR7-K-1..3
- **E-L dev_bypass**: L12, X2, X4, L20; Court(s): ERR7-L-1..6
- **E-M profile vocabulary, selection**: L12; Court(s): ERR7-M-1..3, SEC-M16-1..7
- **E-N pins and numbering**: NEW (doc-lint); Court(s): ERR7-N-1..3
- **E-O cross-boundary receipts**: L18, L04, X2, L19; Court(s): ERR7-O-1..5
- **E-P secure by default**: L12, L04, L10; Court(s): ERR7-P-1..3, SEC-M16, SEC-M24
- **E-Q supply chain**: NEW (CI and release path); Court(s): ERR7-Q-1..5

## 6. Rejected or narrowed items

- **Rejected:** none. Every item was found achievable once restated.
- **Narrowed (recorded, not silent):** E-Q "reproducible build" is SHOULD, not MUST, because
  bit-for-bit reproducibility of an Erlang release containing precompiled NIFs and native
  crates is not established; the residual is recorded when it fails. All other E-Q predicates
  are MUST at C2 and C3.
- **Scope note:** E-C states tier I2 for this operator because both human signers use Apple
  devices possibly held by one person; tier I3 is not claimed.

## See Also

- `docs/rfc/RFC-SA2A-004-v26.9.28.md` — consequence protocol (sections 5, 10, 12, 24)
- `docs/rfc/RFC-SA2A-005-security-profile-v26.9.28.md` — CWE profile (005a)
- `docs/rfc/RFC-SA2A-005-cwe-court-matrix-v26.9.28.md` — court matrix (005b)
- `docs/rfc/RFC-SA2A-006-adversarial-control-plane-v26.9.28.md` — C0..C3 (006a)
- `docs/assurance/sa2a-assurance-case-v26.9.28.md` — claims, evidence, assumptions, risks
- `docs/jira/v26.9.28-kernel/_LANES_V3.md` — lane map and honest status
