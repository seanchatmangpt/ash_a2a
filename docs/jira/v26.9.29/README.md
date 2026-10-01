# v26.9.29 Release Preparation

Release engineering state for `ash_a2a` v26.9.29. Nothing is published: no tag, no `mix
hex.publish`, no push. Version: v26.9.29. Last Updated: 2026-09-29.

## Contents

1. Scope
2. Release path
3. Conformance status
4. What changed since v26.9.22
5. See Also

## 1. Scope

- `mix.exs` version is `26.9.29`; `k8s/actuator/statefulset.yaml` image tag, docs that name
  the version and the CHANGELOG entry were bumped in the same change.
- No `v26.9.28` tag exists (tags end at `v26.9.22`); the CHANGELOG entry covers
  `v26.9.22..HEAD` (533 commits).
- Owned by other lanes and not bumped here: see `HANDOFF.md` section "Cross-lane version
  sites".

## 2. Release path

Exactly one workflow can publish: `.github/workflows/release.yml` (`push` of `v*` tag
publishes; `workflow_dispatch` is a non-publishing dry run). Court:
`test/ash_a2a/supply_chain/release_path_test.exs`. Procedure: `docs/how-to/release.md`.
Cutting the tag is an operator action and is not done by this lane.

## 3. Conformance status

Observed with `mix ash_a2a.verify_conformance --profile c0..c3` at `b812fe0` on a dirty
working tree (concurrent lanes), security profile `:dev_bypass`. All four: NOT CONFORMANT.
Detail and per-probe results: `HANDOFF.md`. No claim line is emitted; C1, C2 and C3 are
not claimed.

## 4. What changed since v26.9.22

See `CHANGELOG.md` `[26.9.29]`. Assurance arguments and defect status:
`docs/assurance/sa2a-assurance-case-v26.9.29.md`.

## See Also

- `docs/jira/v26.9.29/HANDOFF.md`
- `docs/how-to/release.md`
- `docs/reference/conformance-claim.md`
