# Conformance Claim

`mix ash_a2a.verify_conformance --profile c0|c1|c2|c3` computes the RFC-SA2A-007
section 4 conformance statement from executed probes. The statement is an output of
the verifier, never hand-written. Version marker: v26.9.29.

## Quick reference

- [Usage](#usage)
- [Claim grammar](#claim-grammar)
- [Status semantics](#status-semantics)
- [Requirement checks](#requirement-checks)
- [Probe interfaces for lanes](#probe-interfaces-for-lanes)
- [See also](#see-also)

## Usage

```bash
mix ash_a2a.verify_conformance --profile c1
mix ash_a2a.verify_conformance --profile c2 --github --json receipts/conf-c2.json
mix ash_a2a.verify_conformance --profile c3 --tier I2 --scope physical-host --report
```

The task exits non-zero (`Mix.raise/1`) on `NOT CONFORMANT` unless `--report` is
given. `--json PATH` writes the machine report (claim, subject SHA, security profile,
every check with status and evidence). The task loads config and compiles
(`app.config`) but does not start the application, so it can report on a tree whose
boot preflight refuses to start. Without `--profile` the legacy RFC-SA2A-001 report
(`--claim`, `--verbose`, `--explain`) runs unchanged.

## Claim grammar

```text
SA2A v<verifier-emitted version> conforms to profile Cn at independence tier Ti, hosting scope S, on subject SHA H
```

Emitted only if every check of `C0..Cn` (cumulative) plus the claim-scope checks and,
from C2, the supply-chain block is `pass`. Otherwise the output is
`NOT CONFORMANT to Cn: <failing and unverified check ids>`. It is always
`NOT CONFORMANT` when the security profile is `:dev_bypass` or `:legacy_compat`, when
the tree is dirty, or when there is no subject SHA.

Tier defaults to `I1` and scope to `same-host-os-user`; anything stronger is
`unverified` (needs operator deployment evidence).

## Status semantics

- `pass`: an executed probe supported the requirement (a call into the code, a real
  court, inspection of compiled BEAM chunks, evaluating a real `mix.exs`).
  Documentation greps never pass.
- `fail`: the probe ran and the requirement is not met, or the module the requirement
  depends on does not exist yet. Evidence names the reason.
- `unverified`: needs an operator prerequisite or is not executable here (no
  `--github`, no built release to inspect, no deployment evidence for tier/scope).

## Requirement checks

| id | profile | probe |
|---|---|---|
| `c0.subject_identity` | C0 | `git rev-parse HEAD` and empty `git status --porcelain` |
| `c0.refusal_totality` | C0 | every registered code refuses as itself; unknown inputs refuse as unknown |
| `c0.standing_derived` | C0 | `Standing.derive/1` on evidence cases; a literal standing refuses |
| `c0.canonical_digest` | C0 | `Identity.Canonical.digest/1` key-order invariant, value sensitive |
| `c1.security_profile_strict` | C1 | `AshA2A.SecurityProfile.current/0 == :strict` |
| `c1.closure_report` | C1 | `ConsequenceKernel.ClosureCourt.report/0` has zero `violating_edges` |
| `c1.command_bus_no_direct_dispatch` | C1 | compiled imports of `CommandBus` contain no `Dispatcher` call |
| `c1.canonical_at_boundaries` | C1 | boundary modules: no `term_to_binary`; hashing implies `Identity.Canonical` |
| `c1.durable_claim_store` | C1 | configured store exports callbacks and `durable?/0 == true`, not Memory/ETS |
| `c1.keyed_journal` | C1 | non-tmp writable dir; key provider MACs, verifies, refuses tampered payload |
| `c2.certificate_verifier_signatures` | C2 | garbage/unregistered/wrong-effect signatures refused, real one accepted |
| `c2.crypto_verifier_primitives` | C2 | real Ed25519 verifies; hostile inputs refused without raising; ML-DSA typed |
| `c2.authority_service_project` | C2 | `authority_service/mix.exs` evaluated: no dependency on the control plane |
| `c2.actuator_project` | C2 | `actuator/mix.exs` evaluated: no dependency on the control plane |
| `c2.no_signing_key_material` | C2 | `:ash_a2a` env and `SA2A_*` env vars carry no private/signing key |
| `c2.release_distribution_none` | C2 | `rel/env.sh.eex` and the built release `env.sh` set `RELEASE_DISTRIBUTION=none` |
| `supply.protected_main` | C2 | `gh api .../branches/main/protection` (only with `--github`) |
| `supply.signed_tag` | C2 | annotated tag at HEAD verified by `git tag -v` (only with `--github`) |
| `supply.single_release_workflow` | C2 | exactly one workflow triggered by `release` or pushed tags (`--github`) |
| `c3.signer_set_quorum` | C3 | `SignerSet.quorum/2` over standings, plus real-key end-to-end probe |
| `claim.tier_supported`, `claim.scope_supported` | all | declared tier/scope within evidence |

## Probe interfaces for lanes

Where a dependency is another lane's deliverable the check is written against this
interface and fails until it exists:

- `AshA2A.ConsequenceKernel.ClosureCourt.report/0 :: %{violating_edges: [term]}`
- claim store module (`config :ash_a2a, :claim_store`): `durable?/0` returning `true`
  plus `claim/2` and `complete/2`
- journal: `:receipt_outbox_dir` (outside tmp) and a key provider
  (`:receipt_outbox_key` or `:receipt_binding_key`, at least 32 bytes, HMAC-SHA256)
- `AshA2A.C3.SignerSet.quorum([standing], k) :: {:ok, %{custodians: [id], tier: :i1..:i4}} | {:error, code}`
  where `standing` is `AshA2A.CryptoStanding` output; independence counts distinct
  `custodian_id` among valid standings, minimum tier
- `authority_service/` and `actuator/` mix projects under the repo root, with
  `rel/env.sh.eex` setting `RELEASE_DISTRIBUTION=none`

## Standing receipt — post-hardening wave (2026-10-05, subject `059ff0e3`)

Standing-scoped verdicts from the post-hardening verification wave. Each
row: verdict, the executed command that produced it, and its falsifier
(the observation that would retire the claim). All three are
point-in-time at subject `059ff0e3` (branch `feat/tck-vuln-hardening`);
none is a certification.

| Verdict surface | Verdict | Command (executed) | Falsifier |
|---|---|---|---|
| Official A2A TCK compatibility | **7 FAIL / 92 PASS** on the first all-three-binding run (G6 integration, 2026-10-06T01:30:52Z, branch tip `2379635c`): overall **73.6%** (MUST 73.6%, SHOULD 63.6%, MAY 100%); 129 requirements: 92 PASS / 7 FAIL / 4 SKIPPED / 26 NOT TESTED. Failing classes enumerated: push lifecycle (PUSH-CREATE-001, PUSH-DELIVER-001/002/003 — no TCK-webhook delivery observed; config-create refuses over gRPC/http_json), gRPC extended card (CARD-EXT-001/002 — `UNIMPLEMENTED`), gRPC stream-close isolation (STREAM-ORDER-004). Streaming converted (STREAM-SUB/ORDER-001..003 PASS on all three bindings); agent_card 10/10. | `./run_tck.py --sut-host http://127.0.0.1:9999 --transport jsonrpc,http_json,grpc` against the SUT on Bandit + gRPC:10000; reports `/tmp/a2a-tck/reports/compatibility.json` (`2026-10-06T01:30:52Z`) | any TCK test that executes and fails, or a fix landing without a corresponding re-run verdict flip |
| In-repo v1.0 conformance runner | **23 PASS / 3 FAIL** across 26 courts at the G6 integration re-run (machine report `/tmp/g6-report.json`, `2026-10-06T01:35:19Z`, branch tip `2379635c`); the 3 FAILs are the resubscribe/SSE-streaming semantics changes landing in the streaming lane — `test/ash_a2a_v1_owner_scope_test.exs` (2), `test/ash_a2a_v1_sse_replay_test.exs` (1), `test/ash_a2a_v1_multinode_continuity_test.exs` (1), reproducible standalone with `--include serial`. The prior wave verdict was 25 PASS / 0 FAIL across 25 courts (`/tmp/at8_conformance_report.json`, `2026-10-05T23:24:48Z`, subject `059ff0e3`). | `MIX_ENV=test MIX_BUILD_ROOT=_build-g6 mix ash_a2a.v1_conformance_report --out /tmp/g6-report.json` | `totals.fail > 0` in a fresh report, or a court failing standalone with `--include serial` |
| Vulnerability scan (sobelow) | **NOT GREEN — 11 high-confidence findings** (1 `Config.HTTPS`, `config/prod.exs`; 10 `Misc.BinToTerm` in receipt/journal/fixture file-decode paths) + 343 low-confidence, at `059ff0e3`; `mix sobelow --exit high` exits 1. The gate landed in CI (`security` job, `059ff0e3`) and will fail until the 11 are fixed or `# sobelow-ignore`-dispositioned | `MIX_ENV=dev mix sobelow --exit high` (2026-10-05) | the scan exiting 0 on `--exit high`, or a finding class fixed without re-scan |

Also gated: hex.audit (supply-chain job, `ci.yml` + `release.yml`).
TCK-in-CI landed as the `tck` job in `.github/workflows/ci.yml`
(`6342ab2d`) — the official suite against the in-tree SUT; the
earlier `REFUSED(ci:tck-not-in-tree)` framing is retired.

## See also

- `docs/rfc/RFC-SA2A-007-errata-v26.9.28.md` section 4 (claim grammar)
- `docs/rfc/RFC-SA2A-006-adversarial-control-plane-v26.9.28.md` (C0..C3 profiles)
- `docs/assurance/sa2a-assurance-case-v26.9.28.md`
- `docs/reference/mix-tasks.md`
