# HANDOFF

State handoff for v26.9.29 in `ash_a2a`. Subject: `main` at
`b812fe0b77693424654a460219a4322b55b2f026` plus 38 uncommitted paths from concurrent lanes
(OBSERVED by `git rev-parse HEAD` and the verifier's dirty-tree probe). Labels: OBSERVED =
run or read in this session; UNVERIFIED = not run.
Last Updated: 2026-09-29.

## Contents

1. Conformance verifier output
2. Not run
3. Release state
4. Cross-lane version sites
5. See Also

## 1. Conformance verifier output

Command: `mix ash_a2a.verify_conformance --profile cN` (dev build, `:dev_bypass`, EKV_BUILD=1),
OBSERVED. Every profile exits non-zero: `NOT CONFORMANT ... security profile :dev_bypass can
never conform`.

| Profile | Failing | Unverified |
|---|---|---|
| c0 | c0.subject_identity | none |
| c1 | c0.subject_identity, c1.security_profile_strict, c1.closure_report, c1.durable_claim_store, c1.keyed_journal | none |
| c2 | same 5 as c1 | c2.release_distribution_none, supply.protected_main, supply.signed_tag, supply.single_release_workflow |
| c3 | same 5 as c1 | same 4 as c2 |

Passing probes (all profiles that run them): c0.refusal_totality (20 codes),
c0.standing_derived, c0.canonical_digest, c1.command_bus_no_direct_dispatch,
c1.canonical_at_boundaries (9 modules), c2.certificate_verifier_signatures (real Ed25519),
c2.crypto_verifier_primitives, c2.authority_service_project, c2.actuator_project,
c2.no_signing_key_material, c3.signer_set_quorum (custodian-distinct 2-of-n accepted; two
keys of one custodian refused), claim.tier_supported, claim.scope_supported.

Failure reasons: dirty tree (38 paths) so the SHA does not describe the tree; profile is
`:dev_bypass`; `ClosureCourt.report/0` was absent when the probes ran (module now present in the
working tree, probe not re-run); no `:claim_store` configured; `:receipt_outbox_dir` unset. The last three are configuration and
lane-landing facts, not proof the components are broken. Claim standing: none of C1, C2, C3
is claimed.

## 2. Not run

- Verifier with `--github` (supply.*): UNVERIFIED.
- Built prod releases of `authority_service` and `actuator` for `RELEASE_DISTRIBUTION=none`:
  UNVERIFIED.
- Verifier on a clean tree under a `:strict` build: UNVERIFIED (the only way to get a claim).
- Full `mix test` gate: not run by this lane.

## 3. Release state

- `mix.exs` 26.9.29; one publishing workflow (`release.yml`); no tag created; no publish.
- Latest tag `v26.9.22`; the CHANGELOG entry is built from `v26.9.22..HEAD`.
- Next operator steps: land other lanes, run the verifier clean under `:strict` with
  `--github`, dry-run via `workflow_dispatch`, then tag per `docs/how-to/release.md`.

## 4. Cross-lane version sites

Still naming v26.9.28 (owned outside this lane): `lib/ash_a2a/sa2a/conformance/context.ex:27`,
`lib/mix/tasks/ash_a2a.verify_conformance.ex:28`,
`test/ash_a2a/sa2a/conformance/profiles_test.exs` (lines 650-742),
`test/ash_a2a/supply_chain/release_path_test.exs` (HANDOFF path and version fixtures),
`lib/ash_a2a/semantic/refusal.ex`, `actuator/mix.exs`, `sa2a_crypto/mix.exs`,
`authority_service/mix.exs`, `docs/reference/c2-*.md`.

## See Also

- `docs/jira/v26.9.29/README.md`
- `docs/assurance/sa2a-assurance-case-v26.9.29.md`
- `docs/jira/v26.9.28-kernel/HANDOFF.md` (superseded)
