# Release

The Hex release has one path: `.github/workflows/release.yml`. A pushed
`v<version>` tag publishes; `workflow_dispatch` is a dry run that publishes
nothing. Version: v26.9.29.

## Contents

- Cut a release
- Dry run
- Authority and secrets
- What the workflow proves

## Cut a release

1. Set `version` in `mix.exs`; keep the `Version:` lines in
   `docs/reference/a2a-spec-version-mapping.md` and
   `docs/jira/v26.9.29/HANDOFF.md` equal to it (`release_path_test` checks it against `mix.exs`).
2. Merge to `main`, then push the tag `v<version>` (for example `v26.9.29`).
3. Approve the `hex-release` environment deployment when prompted.

The workflow refuses if the tag differs from `mix.exs`, if `mix.lock` drifts, if
`mix hex.audit` reports advisories, or if the prod closure does not compile.

## Dry run

Run the workflow from the Actions tab (`workflow_dispatch`). It builds the
tarball, the CycloneDX SBOMs (Hex closure, `hddl_cli`, `graphlaw_host`), attests
provenance and all three SBOMs, runs `gh attestation verify` against the exact
tarball, and uploads the files as an artifact. It never runs `mix hex.publish`
and never creates a GitHub release.

## Authority and secrets

Secrets cannot be created from the repository. An operator sets them once:

```bash
gh secret set HEX_API_KEY --env hex-release
```

Configure required reviewers on the `hex-release` environment. The first step of
the job fails with `BLOCKED(authority:HEX_API_KEY)` on a tag push when the secret
is missing, before any build time is spent.

## What the workflow proves

- Hex's registry checksum equals the sha256 of the attested tarball.
- No scheduled or push trigger other than the tag can publish.
- Dependabot (`mix`, `cargo` x2, `github-actions`) and the OpenSSF Scorecard
  workflow keep pins current and report posture.

## See Also

- `.github/workflows/release.yml`
- `test/ash_a2a/supply_chain/`
- `docs/reference/a2a-spec-version-mapping.md`
