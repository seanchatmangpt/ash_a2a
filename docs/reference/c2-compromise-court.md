# C2 Compromise Court

The C2 compromise court is the executable form of RFC-SA2A-006 s26 for the separate
`authority_service/` and `actuator/` projects. It gives an attacker arbitrary control of the
control-plane node and asks one question of the actuator's append-only, hash-chained effect
ledger: did an effect happen that the authority's issuance journal did not authorize?

Milestone: v26.9.28 C2 (SA2A-C2 conformance evidence). Last Updated: 2026-09-29.

## Contents

1. Running it
2. Hosting scope and threat model
3. Pass rule
4. What the attacker holds, and the key-material scan
5. Attack catalog and standards mapping
6. Mutation court (anti-vacuity)
7. Fault injection
8. Report format
9. Known gaps and handoffs
10. See also

## Running it

```sh
cd /Users/sac/ash_a2a && source scripts/toolchain.sh
EKV_BUILD=1 mix ash_a2a.c2.court                       # N=20, mutation court on
EKV_BUILD=1 mix ash_a2a.c2.court --n 50 --report tmp/c2_court/full.json
EKV_BUILD=1 MIX_ENV=test mix test --include c2_court   # same court, through ExUnit
```

The court needs no database (no Repo, no Oban, no Postgres). It is tagged `:c2_court` plus
`:serial` and `:serial_solo`, so the default `mix test` (which runs `--exclude serial`)
excludes it and `mix test.all` (`--include serial`) includes it. `mix test` alone still runs
the two fast, process-free suites in the same directory (`oracle_test.exs`,
`catalog_integrity_test.exs`).

Environment (all set by the mix task): `C2_COURT_N` (fault-injection repetitions, default 20,
at most 50), `C2_COURT_MUTANT_N` (default 3), `C2_COURT_REPORT`, `C2_COURT_BUILD_ROOT`
(where the child projects build, one `MIX_BUILD_ROOT` each), `C2_COURT_ONLY` (attack ids),
`C2_COURT_MUTATION=0`.

## Hosting scope and threat model

Recorded verbatim in every report as `hosting_scope`:

> separate-process, same-host: keymaster, actuator and authority are distinct OS processes
> (own `MIX_BUILD_ROOT`, own state dir mode 0700, no Erlang distribution, UDS/mTLS wire) run
> as the SAME OS uid as the test process that plays the control plane.

A separate OS user or a cluster is an operator/infrastructure follow-up. An attacker that
ignores the attacker API and opens the state directories directly is outside what this court
can constrain; the court therefore never hands the attacker API a state directory or key file
path, and proves the control-plane environment holds none (see the scan below).

Processes (all started with `mix run --no-halt` from their own project directory):

| process | project / env | holds | wire |
|---|---|---|---|
| keymaster | `authority_service` test env, `test/support/c2_harness/keymaster_child.exs` | every private key, TLS PKI, issuance journal | UDS, court-only |
| actuator | `actuator` test env, `actuator_child.exs` (real `Actuator.Store`, UDS + mTLS listeners) | pinned public registry only, own state dir, ledger | UDS, mTLS 1.3 |
| authority | `authority_service` prod env (the release entrypoint, `Application` + `Runtime`) | its own policy key file (0600), approver registry, journal | UDS |

Distribution is disabled: no child is started with `--name`/`--sname`, `ERL_FLAGS=-start_epmd
false`, and each child prints `node_alive: false` in its READY line (the court refuses to
continue otherwise). A watchdog in every child halts it when the test VM's OS pid disappears.

## Pass rule

Per attack, with `before`/`after` ledger snapshots and `authorized` the effect digests the
issuance journal legitimately authorizes and that remain valid for that attack:

1. the `after` chain verifies (re-derived by `C2Harness.Oracle` from `:crypto` and `Jcs`, no
   shared code with `Actuator.Ledger`) and `before` is a prefix of it;
2. every NEW ledger entry's `effect_digest` is in `authorized` and occurs in the issuance
   journal;
3. for every digest that gained an entry, ledger entries do not exceed issuance-journal
   entries for that digest (one issuance buys at most one consequence).

Zero new entries always passes. An exception, crash, timeout or refusal code alone is never
evidence. Verdicts: `pass`, `fail` (rule violated), `vacuous` (rule holds but a required refusal
code was never observed, meaning the attack did not reach its target) and `error` (the attack
raised); everything except `pass` fails the court.

Authority-side attacks use the real AuthorityService journal: it may gain only authorized
`(effect_digest, generation)` pairs, no pair may appear twice, and the actuator ledger must
not change at all.

Cross-attack isolation: the duplicate check only considers digests that gained an entry in
this attack, so one violation is attributed to the attack that caused it.

## What the attacker holds, and the key-material scan

`C2Harness.ControlPlane` is everything the attacker API receives: socket paths, its own mTLS
client credential, an attacker-generated rogue credential, the public registry, protocol
constants and the private keys of the signers the threat model deliberately compromises:
signers `A` and `A2` (one custodian, `custA`, two keys) and approver `alice`, i.e. fewer than
k. Signers `B`, `C`, approvers `bob`/`carol`, the authority policy key and the actuator TLS
server key exist only in the keymaster and the service that owns them.

`C2Harness.Scan` sends the attacker's whole readable environment (`System.get_env/0`, the
application environment of every loaded application, the `ControlPlane` struct, the process
dictionary) to the keymaster, which searches it for every non-granted private key in raw,
base64url, base64 and hex forms, for the key file contents and for the key/state directory
paths, and returns only the names of leaks. Anti-vacuity: the same call with `selftest: true`
plants every needle in a haystack and the court fails unless each one fires.

Court controls (`Env.issue/3`, `Env.approve/4`, `Env.revoke/2`, kill and restart) are
operator-side and authority-side actions used to stage a scenario, not attacker powers. Two
issuance modes matter:

* `issue!`: an intended issuance, recorded in the hash-chained issuance journal before
  signing, `(digest, generation)` at most once (the AuthorityService.Issuer discipline);
* `misissue!`: a validly signed certificate that is NOT journaled, modelling an authority
  defect or a mis-signed artifact. The actuator is the independent second line, and any
  ledger entry a mis-issued certificate causes is unauthorized by definition.

## Attack catalog and standards mapping

ID scheme: `C2C-A<nn>` actuator (fence, wire, payloads), `C2C-F<nn>` fault injection,
`C2C-B<nn>` authority. The catalog lives in `test/support/c2_harness/catalog.ex`,
`faults.ex` and `authority_attacks.ex`; every attack declares the s26 items it covers, the
fence checks it reaches, and the refusal it must observe.

**Provenance of the mapping.** RFC-SA2A-007 cites its standards reviewers ("avatars") by
name but contains no ATT&CK, ATLAS or CAPEC identifier table. The identifiers below are
therefore assigned by this court (UNVERIFIED against a published avatar table): ATT&CK
technique ids and CAPEC ids follow the public catalogs' titles, ATLAS uses `AML.T0053`
(agent tool invocation) for agent-driven forged actuation and `AML.T0029` for
denial-of-service style amplification. Treat the mapping as a documented index for
traceability, not as an assurance claim.

| id | attack | RFC s26 item(s) | ATT&CK | CAPEC | ATLAS | fence checks | must observe |
|---|---|---|---|---|---|---|---|
| C2C-A01 | forged PreparedEffect under a valid certificate | forged PreparedEffect | T1565, T1550 | CAPEC-194, CAPEC-153 | AML.T0053 | 2 | effect_digest_mismatch |
| C2C-A02 | certificate signed by keys absent from the actuator's pinned registry | forged certificate | T1606, T1550 | CAPEC-196, CAPEC-151 | AML.T0053 | 10 | unknown_kid |
| C2C-A03 | kid spoofing: compromised signer signs while claiming another signer's kid | forged certificate | T1606 | CAPEC-196, CAPEC-151 | AML.T0053 | 10 | bad_signature, kid_key_mismatch |
| C2C-A04 | fake standing / smuggled public keys inside the certificate | fake standing | T1606 | CAPEC-194 | AML.T0053 | - | malformed_certificate |
| C2C-A05 | forged receipt and administrative operations over the wire | forged internal receipt; policy-option removal | T1562, T1190 | CAPEC-1, CAPEC-220 | AML.T0053 | - | malformed_request |
| C2C-A06 | mutated exact subject after signing | mutated exact subject | T1565 | CAPEC-153, CAPEC-194 | AML.T0053 | 2 | effect_digest_mismatch |
| C2C-A07 | signed effect whose subject is outside the actuator's allowed set | mutated exact subject | T1078 | CAPEC-1, CAPEC-153 | AML.T0053 | 4 | subject_not_allowed |
| C2C-A08 | mutated canonical input and non-canonical encodings | mutated canonical input | T1565 | CAPEC-153 | AML.T0053 | 2 | effect_digest_mismatch, non_canonical_effect |
| C2C-A09 | fresh request id for an existing effect instance | fresh request id for an existing effect instance | T1550 | CAPEC-60, CAPEC-21 | AML.T0053 | 2,15 | performed, effect_digest_mismatch |
| C2C-A10 | replay of a valid certificate after completion (also across actuator restart) | replay of a valid certificate; duplicated DO | T1550 | CAPEC-60 | AML.T0053 | 15 | performed, replayed |
| C2C-A22 | concurrent claim of one effect from twelve connections | duplicated DO | T1499, T1550 | CAPEC-26, CAPEC-29 | AML.T0053 | 14,15 | performed |
| C2C-A44 | one (kid, nonce) pair reused to authorize a second effect instance | duplicated DO; replay of a valid certificate | T1550 | CAPEC-60 | AML.T0053 | 14 | performed, nonce_replayed |
| C2C-A11 | expired certificate | expired certificate | T1550 | CAPEC-60 | AML.T0053 | 12 | expired |
| C2C-A12 | not-yet-valid certificate beyond the skew allowance | expired certificate | T1550 | CAPEC-29 | AML.T0053 | 12 | not_yet_valid |
| C2C-A13 | certificate with a lifetime above the actuator TTL ceiling | expired certificate | T1550 | CAPEC-29 | AML.T0053 | 12 | ttl_too_long |
| C2C-A14 | certificate whose window is malformed (expires <= not_before) | expired certificate | T1550 | CAPEC-153 | AML.T0053 | 10,12 | malformed_window, malformed_envelope |
| C2C-A15 | stale policy epoch on the certificate and on the effect | stale policy epoch | T1562 | CAPEC-176 | AML.T0053 | 9 | policy_epoch_stale |
| C2C-A16 | certificate older than the actuator's revocation epoch | revoked authority | T1550 | CAPEC-60 | AML.T0053 | 13 | revocation_epoch_stale |
| C2C-A17 | certificate signed by a key the actuator's revocation view lists as revoked | revoked authority | T1078, T1550 | CAPEC-60 | AML.T0053 | 13 | key_revoked |
| C2C-A18 | stale and missing revocation view (fail closed) | revoked authority | T1562 | CAPEC-176 | AML.T0053 | 13 | revocation_view_stale, revocation_view_missing |
| C2C-A19 | insufficient quorum (1 valid signature where 2 custodians are required) | insufficient quorum | T1078 | CAPEC-1 | AML.T0053 | 11 | quorum_not_met |
| C2C-A20 | single compromised signer below k, alone and with repeated nonces | single compromised signer below quorum | T1078, T1606 | CAPEC-196, CAPEC-151 | AML.T0053 | 11 | quorum_not_met |
| C2C-A21 | one custodian signing twice with two keys (independence tier I3) | single compromised signer below quorum | T1078 | CAPEC-151 | AML.T0053 | 11 | quorum_not_met |
| C2C-A37 | certificate for a generation the actuator does not hold | replay of a valid certificate | T1550 | CAPEC-60 | AML.T0053 | 16 | generation_stale |
| C2C-A38 | certificate minted for another audience | forged certificate | T1550 | CAPEC-21 | AML.T0053 | 10 | wrong_audience |
| C2C-A39 | certificate principal differs from the effect principal | forged capability | T1078 | CAPEC-151 | AML.T0053 | 3 | principal_mismatch |
| C2C-A40 | capability that is not the effector's own capability | forged capability | T1078 | CAPEC-1 | AML.T0053 | 5 | capability_mismatch |
| C2C-A41 | consequence class below the effector's registered class | forged capability | T1078 | CAPEC-1 | AML.T0053 | 6 | consequence_class_mismatch |
| C2C-A42 | unsupported protocol version on effect and certificate | forged PreparedEffect | T1565 | CAPEC-220 | AML.T0053 | 1 | unsupported_protocol_version |
| C2C-A43 | malformed effect-instance identity | fresh request id for an existing effect instance | T1059 | CAPEC-88, CAPEC-153 | AML.T0053 | 7 | bad_effect_instance |
| C2C-A28 | policy-option removal: required effect and certificate fields deleted | policy-option removal | T1562 | CAPEC-153 | AML.T0053 | - | malformed_effect, malformed_certificate |
| C2C-A34 | swapped or downgraded signature algorithm | forged certificate | T1606 | CAPEC-196 | AML.T0053 | 10 | unsupported_algorithm, malformed_envelope, alg_mismatch, unsupported_suite, profile_mismatch |
| C2C-A35 | truncated and oversized certificate and effect | arbitrary deserialization payload | T1499, T1190 | CAPEC-130, CAPEC-153 | AML.T0029 | - | malformed_certificate, malformed_effect |
| C2C-A36 | clock skew: within the allowance accepted, beyond it and after expiry refused | expired certificate | T1550 | CAPEC-29 | AML.T0053 | 12 | performed, not_yet_valid, expired |
| C2C-A33 | resource-budget amplification: declared bounds, oversized entries, frames and signature lists | resource-budget amplification | T1499 | CAPEC-130, CAPEC-125 | AML.T0029 | 8 | resource_bounds_exceeded, malformed_certificate, malformed_effect, transport_closed |
| C2C-A29 | path substitution in params, subject and effect type | path substitution | T1083, T1565 | CAPEC-126 | AML.T0053 | 4 | malformed_effect, unknown_effect_type, subject_not_allowed, performed |
| C2C-A30 | URL substitution in params and effect type | arbitrary URL substitution | T1090, T1071 | CAPEC-664 | AML.T0053 | - | malformed_effect, unknown_effect_type, performed |
| C2C-A31 | command injection in effect type, params, subject and entry | command injection | T1059 | CAPEC-88 | AML.T0053 | 4 | malformed_effect, unknown_effect_type, subject_not_allowed, performed |
| C2C-A32 | arbitrary deserialization payloads (external term format, struct keys, deep nesting) | arbitrary deserialization payload | T1190, T1203 | CAPEC-586 | AML.T0053 | - | malformed_request, malformed_effect |
| C2C-A27 | alternate wire path: mTLS port without / with rogue / with legitimate client credential | alternate adapter path | T1021, T1557 | CAPEC-115, CAPEC-220 | AML.T0053 | - | tls_plaintext_refused, tls_no_client_cert_refused, tls_rogue_client_refused, tls_legit_client_served |
| C2C-F01 | crash after the durable claim, before the DO (halt 137), N restarts | worker crash before DO | T1499, T1529 | CAPEC-125 | AML.T0029 | 14,16 | transport_closed, replayed, unknown_outcome |
| C2C-F02 | crash after the DO, before the completion is journaled (halt 137), N restarts | crash during uncertain DO | T1499, T1529 | CAPEC-125, CAPEC-26 | AML.T0029 | 14 | transport_closed, replayed, unknown_outcome |
| C2C-F03 | restart after unknown outcome: repeated kill -9 restarts with retries, reconcile not on the wire | restart after unknown outcome; duplicated DO | T1499, T1550 | CAPEC-60, CAPEC-26 | AML.T0029 | 14,15 | transport_closed, replayed, malformed_request |
| C2C-F04 | external SIGKILL at a random moment of an in-flight request, N restarts | worker crash before DO; crash during uncertain DO | T1499, T1529 | CAPEC-26, CAPEC-125 | AML.T0029 | 14,15 | - |
| C2C-B01 | forged approvals signed by keys outside the approver registry | forged capability; fake standing | T1606, T1550 | CAPEC-196, CAPEC-151 | AML.T0053 | - | insufficient_approvals |
| C2C-B02 | single compromised approver below k, alone and repeated with fresh nonces | single compromised signer below quorum; insufficient quorum | T1078, T1606 | CAPEC-151, CAPEC-196 | AML.T0053 | - | insufficient_approvals |
| C2C-B03 | effect mutated after human approval (approvals bind the original digest) | mutated canonical input; forged PreparedEffect | T1565 | CAPEC-153, CAPEC-194 | AML.T0053 | - | insufficient_approvals, issued |
| C2C-B04 | approval replay: same approvals re-presented for the same effect, another generation, another effect | replay of a valid certificate; duplicated DO | T1550 | CAPEC-60 | AML.T0053 | - | issued, already_issued, insufficient_approvals |
| C2C-B05 | stale-policy-epoch and expired approvals | stale policy epoch; expired certificate | T1550 | CAPEC-60, CAPEC-29 | AML.T0053 | - | insufficient_approvals |
| C2C-B06 | duplicated issuance: eight concurrent connections presenting one valid request | duplicated DO | T1499, T1550 | CAPEC-26 | AML.T0053 | - | issued, already_issued |
| C2C-B07 | malformed, oversized, wrong-op, external-term-format and lying-length frames | arbitrary deserialization payload; resource-budget amplification | T1190, T1499 | CAPEC-586, CAPEC-130 | AML.T0029 | - | unknown_op, malformed_request, request_too_large |
| C2C-B08 | authority SIGKILLed mid-issuance, restarted, request retried (N times) | crash during uncertain DO; duplicated DO | T1499, T1529 | CAPEC-26, CAPEC-125 | AML.T0029 | - | already_issued, issued |
| C2C-E01 | production entrypoint without ACTUATOR_CONFIG refuses to boot | policy-option removal | T1562 | CAPEC-176 | AML.T0053 | - | boot_refused |
| C2C-E02 | production entrypoint: one authorized effect performed, forged certificate refused, replay returns evidence | forged certificate; replay of a valid certificate | T1606, T1550 | CAPEC-196, CAPEC-60 | AML.T0053 | - | performed, unknown_kid, replayed |
| C2C-E03 | crash points are compiled out of the production build (ACTUATOR_TEST_CRASH is inert) | worker crash before DO | T1562 | CAPEC-176 | AML.T0053 | - | performed, crash_points_compiled_out |

RFC-SA2A-006 s26 items that are not meaningful against `authority_service`/`actuator` as
separate projects and are NOT exercised here: direct Dispatcher invocation, direct Ash
mutation, recursive agent spawning (control-plane internals; covered by the C1 courts),
fan-out amplification and kill-switch bypass (the actuator has no fan-out or kill-switch
surface; its resource ceiling is attack C2C-A33).

## Mutation court (anti-vacuity)

A court that cannot fail proves nothing. For every fence check a fresh fleet runs an
actuator whose `Actuator.Fence` was recompiled inside the child from its own source with
exactly that check force-skipped (`ACTUATOR_MUTANT_SKIP`, via the `opts[:skip]` seam of
`Fence.run/4` that `Actuator.Store` never passes). The patch asserts its needle occurs exactly
once in fence.ex, so a refactor cannot silently turn a mutant into a no-op (the child refuses
to boot, and `catalog_integrity_test.exs` checks the needles too). The attacks marked
`killers_for: [n]` run against the mutant and at least one must FAIL the ledger oracle.

* Checks 1-9 and 11-16: each killed by its mutant (table in the report, `mutation.per_check`).
* Check 10 (every presented signature verifies) has no isolating attack: an invalid
  signature is also not counted by check 11, so 10 alone is strictness. The court records the
  evidence rather than hiding it: mutant `{10}` survives the signature attacks (`check_10_alone`),
  mutant `{10, 11}` is killed by them (`check_10_and_11`). Check 10 is jointly necessary with
  check 11.
* The deliberately unfenced actuator (all 16 checks skipped, `mutation.allow_all`) must fail
  the court; parse-level strictness (`Effect.decode`, `Certificate.decode`) stays in place
  in that mutant, so attacks that die at parse pass by design and the rest fail.

## Fault injection

Each fault attack repeats N times (default 20, at most 50; `--n`). Each iteration uses a
fresh effect instance and a fresh journaled issuance.

* `C2C-F01`, `C2C-F02`: the instrumented `Actuator.Store` (compiled with its own
  `fault_hook` seam, patched in the child so the fault point parks instead of halting) parks
  at `after_write_ahead` / `after_perform`, and the harness delivers a real `kill -9` while the
  process sits at exactly that point. After restart the instance must be `unknown_outcome`,
  replay must return evidence without a DO, and a fresh-generation certificate must not open
  the claim.
* `C2C-F03`: repeated `kill -9` restarts of an unknown-outcome instance with a retry after each;
  `reconcile` is not reachable on the wire.
* `C2C-F04`: a burst of 24 in-flight requests with a real SIGKILL at a random microsecond offset
  (seeded), so the kill lands before, inside and after individual requests; every certificate is
  re-presented after restart and no effect may exceed one ledger entry.
* `C2C-B08`: the real AuthorityService is SIGKILLed mid-issuance, restarted, and the request is
  retried; two certificates for one `(digest, generation)` must never exist.

## Report format

`tmp/c2_court/report.json` (or `--report`): `commit_sha`, `working_tree_dirty`, `hosting_scope`,
`fault_repetitions`, `pass_rule`, `summary.overall` (`PASS`/`FAIL` plus `overall_checks`),
`attacks[]` (`id`, `title`, `s26`, `mapping.{attck,capec,atlas}`, `checks`, `verdict`, `reasons`,
`refusal_codes`, `ledger_before`, `ledger_after`, `ledger_diff[]`, `authorized`, `notes`,
`iterations`), `key_material_scan`, `compat[]`, `mutation.{per_check,check_10_alone,
check_10_and_11,allow_all}`.

## Measured result

One full run at N = 50 (`mix ash_a2a.c2.court --n 50`, HEAD `e2e02ebd` with the lane changes of
this working tree uncommitted, so `working_tree_dirty` is true in the report), 345 s wall clock:

* 55 attacks (40 actuator `A`, 8 authority `B`, 4 fault series `F`, 3 production-entrypoint
  checks `E`), 55 `pass`, 0 `fail`, 0 `vacuous`, 0 `error`.
* Fault series at N = 50: F01 50 restarts, 0 ledger entries, 150/150 replays returned evidence
  without a DO; F02 50 restarts, exactly 1 entry per effect, 150/150 replays without a second
  DO; F03 150 kill-9 restarts, 1 entry per effect; F04 1200 effects in-flight across 50 kills
  (kill landed after completion for 258, inside a request for 27 = `unknown_outcome`, before
  the durable claim for 915), maximum ledger entries for any one effect: 1; authority B08: in
  42 iterations the certificate arrived before the kill (retry `already_issued`), in 6 the
  response was lost after journaling (retry `already_issued`), in 2 the kill came before journaling (retry issued
  exactly once).
* Mutation court: 15 of 15 checks with an isolating attack killed by their mutant; `{10}` alone
  survives, `{10, 11}` killed by 6 attacks; the always-allow actuator failed 37 attacks.
* Key-material scan: 0 leaks over a 13 KB haystack; self-test planted and detected all 12 needles.

Numbers are copied from that run's `report.json`; re-run to refresh them.

## Known gaps and handoffs

* **AuthorityService cannot issue for the actuator today.** `AuthorityService.Issuer` parses
  effects requiring `effect_class` and `amount`; `Actuator.Effect` requires an exact key set
  without them. The authority emits `{envelope, message}` while the actuator wants
  `{..., signatures: [...]}` (the same signed message, mechanically convertible). Until one
  side maps
  `consequence_class`/`params` to the policy class and amount, actuator-shaped certificates in this
  court come from the keymaster stand-in, which journals intended issuances exactly like the real
  issuer; the real authority is attacked on its own terms (`C2C-B*`). The `compat` section of
  the report records both refusals (`BLOCKED`).
* Check 12's `malformed_window` branch is not reachable through the wire: the crypto boundary
  (check 10) refuses a certificate whose `expires <= not_before` first with `malformed_envelope`
  (attack `C2C-A14` accepts either code).
* Hosting scope is same-uid (see above).
* A tier with `k = 1` lets a single compromised approver obtain an issuance by policy; the
  claim "fewer than k" is per-class.
* ATT&CK/CAPEC/ATLAS ids are court-assigned (see above).

## See also

* `docs/rfc/RFC-SA2A-006-adversarial-control-plane-v26.9.28.md` s26, s29
* `docs/rfc/RFC-SA2A-007-errata-v26.9.28.md`
* `docs/assurance/sa2a-assurance-case-v26.9.28.md`
* `actuator/lib/actuator/fence.ex`, `authority_service/lib/authority_service/issuer.ex`
