# Release readiness: v26.11.15

Status: PARTIAL. On 2026-11-16 (Elixir 1.20.4 / OTP 29.1.1) some of the checks below were
run; each blocker says what was run and what was not. This file is a checklist of remaining
blockers, not a conformance or release claim.

## Version identity contradictions found

| Location | Says | Needed for v26.11.15 |
|---|---|---|
| `mix.exs` `@version` | `26.11.13` (commit 52e6632: "first publish", 26.11.14/15 notes folded in) | Owner decision: publish as 26.11.13, or bump to 26.11.15 |
| `CITATION.cff` `version` / `date-released` | `26.11.13` / `2026-11-13` | Match the chosen version and real release date |
| `README.md` lines 20 and 391 | `~> 26.11.13` | Match the chosen version |
| `docs/tutorials/getting-started.md` line 22 | `~> 26.11.13` | Match the chosen version |
| `docs/reference/a2a-spec-version-mapping.md` `Version:` | `v26.11.13` | That file states it must equal `mix.exs`; update together |
| `CHANGELOG.md` | `[Unreleased]` holds the 26.11.14/15 notes; no `[26.11.15]` heading | Rename `[Unreleased]` to the released version and date at publish |
| `docs/reference/a2a-v1-1-conformance.md` | Evidence re-run on 2026-11-16 against a working tree with uncommitted changes | Re-run at the clean release commit |
| `docs/explanation/pplan-seams.md` | `mix.lock` resolves `ash_pplan` 26.11.10 | Confirm against `mix.lock` at release |
| `engineering-standards.json` | Schema 26.9.21, base_sha `43ac109...`; carries no package version | Consistent with itself; refresh only if the owner regenerates the adoption header |

## Blockers

1. Owner picks the publish version (see table); no file other than `mix.exs` should lead.
2. Runs recorded on 2026-11-16: `mix format --check-formatted` exits 0; `MIX_ENV=dev mix compile`
   exits 0; `mix ash_a2a.sim --prove` passes 221 of 221 probes in `test` and `dev`;
   `mix ash_a2a.chicago.mutate --require-killed` kills 19 of 19 mutants. Not run on the final
   tree: `mix test.all` (the last full run, on an earlier tree, was 5841 of 5866 with
   environment-bound failures), `mix check`, `mix hex.build` (confirm the `files:` list ships
   every ExDoc extra, including `docs/reference/release-readiness-v26.11.15.md` via
   `docs/reference/*.md`). `mix compile --warnings-as-errors` was not run; a forced compile of
   the library prints 43 compiler warnings, so it is expected to fail until they are cleared.
3. `[Unreleased]` Security and Fixed entries now cite the test files that were run. Three
   statements stay Unverified in `CHANGELOG.md`: the root supervisor strategy, the mount
   `tenant` row, and "`authorize?: true` is passed explicitly / extended-card provider failures
   carry no internal detail".
4. A2A v1.1 stays PARTIAL: no v1.1 TCK verdict exists, upstream `v1.1.0-rc` is not a GitHub
   release, and the row standings in `a2a-v1-1-conformance.md` bind to a working tree, not a
   clean commit.
5. Optional-dependency claim: a path-consumer build with none of the optional deps added
   compiled on 2026-11-16, but `scripts/check_optional_deps.sh` was not run and would fail its
   warning gate (see `docs/how-to/optional-dependencies.md`).
6. `README.md` says `main` runs ahead of published Hex; confirm no Hex release exists yet
   so "first publish" is accurate.
7. `mix.exs` `files:` omits `docs/archive`, yet `a2a-v1-1-conformance.md` links to
   `docs/archive/jira-releases/v26.11.13/RECEIPT.md`; the Hex copy will carry a dead link.
   Either mark the link repo-only or ship the file.

## After the owner decides

- Edit `mix.exs`, `CITATION.cff`, `README.md`, `getting-started.md`, `a2a-spec-version-mapping.md`
  in one change.
- Rename `## [Unreleased]` in `CHANGELOG.md` and drop the version-note paragraph beneath it.
- Run the remaining commands in blocker 2 at the release commit and record the results.
