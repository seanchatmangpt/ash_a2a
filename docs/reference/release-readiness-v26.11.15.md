# Release readiness: v26.11.15

Status: UNVERIFIED. Written without an Elixir toolchain; nothing below was run. This
file is a checklist of remaining blockers, not a conformance or release claim.

## Version identity contradictions found

| Location | Says | Needed for v26.11.15 |
|---|---|---|
| `mix.exs` `@version` | `26.11.13` (commit 52e6632: "first publish", 26.11.14/15 notes folded in) | Owner decision: publish as 26.11.13, or bump to 26.11.15 |
| `CITATION.cff` `version` / `date-released` | `26.11.13` / `2026-11-13` | Match the chosen version and real release date |
| `README.md` lines 20 and 391 | `~> 26.11.13` | Match the chosen version |
| `docs/tutorials/getting-started.md` line 22 | `~> 26.11.13` | Match the chosen version |
| `docs/reference/a2a-spec-version-mapping.md` `Version:` | `v26.11.13` | That file states it must equal `mix.exs`; update together |
| `CHANGELOG.md` | `[Unreleased]` holds the 26.11.14/15 notes; no `[26.11.15]` heading | Rename `[Unreleased]` to the released version and date at publish |
| `docs/reference/a2a-v1-1-conformance.md` | Evidence bound to commit `d8f593dc` | Re-bind to the release commit or state it is older |
| `docs/explanation/pplan-seams.md` | `mix.lock` resolves `ash_pplan` 26.11.10 | Confirm against `mix.lock` at release |
| `engineering-standards.json` | Schema 26.9.21, base_sha `43ac109...`; carries no package version | Consistent with itself; refresh only if the owner regenerates the adoption header |

## Blockers

1. Owner picks the publish version (see table); no file other than `mix.exs` should lead.
2. No run is recorded for this tree: `mix compile --warnings-as-errors`, `mix format --check-formatted`,
   `mix test.all`, `mix check`, `mix hex.build` (confirm the `files:` list ships every ExDoc
   extra, including `docs/reference/release-readiness-v26.11.15.md` via `docs/reference/*.md`).
3. Every `[Unreleased]` Security and Fixed entry is labelled Unverified; none has a cited
   test driving the real transport. Add or cite those tests before relying on the claims.
4. A2A v1.1 stays PARTIAL: no v1.1 TCK verdict exists and upstream `v1.1.0-rc` is not a GitHub release.
5. Optional-dependency claim (consumer compiles without `oban`, `postgrex`, `flame`,
   `durable_server`, `req_llm`, ...) needs a fresh path-consumer build.
6. `README.md` says `main` runs ahead of published Hex; confirm no Hex release exists yet
   so "first publish" is accurate.
7. `mix.exs` `files:` omits `docs/archive`, yet `a2a-v1-1-conformance.md` links to
   `docs/archive/jira-releases/v26.11.13/RECEIPT.md`; the Hex copy will carry a dead link.
   Either mark the link repo-only or ship the file.

## After the owner decides

- Edit `mix.exs`, `CITATION.cff`, `README.md`, `getting-started.md`, `a2a-spec-version-mapping.md`
  in one change.
- Rename `## [Unreleased]` in `CHANGELOG.md` and drop the version-note paragraph beneath it.
- Run the commands in blocker 2 and record the results; only then change any label from UNVERIFIED.
