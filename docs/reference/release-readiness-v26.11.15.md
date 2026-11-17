# Release readiness: v26.11.15

Status: PARTIAL. This file is a checklist of remaining blockers and the exact commands that
check them, not a conformance or release claim. Observations below were made on 2026-11-17
(Elixir 1.20.4 / OTP 29.1.1, `MIX_ENV=test`, a shared working tree that other work was
changing at the same time). A command that was not run says so.

## Owner decision: the version is not bumped

`mix.exs` `@version` stays `26.11.13`. The version to publish (26.11.13 as already
described by commit 52e6632, or a bump to 26.11.15) is the owner's decision, and this
documentation pass did not make it. Until the owner chooses, no file other than `mix.exs`
should lead, and `CHANGELOG.md` keeps its `[Unreleased]` heading with a paragraph that says so.

| Location | Says | Needed once the owner decides |
|---|---|---|
| `mix.exs` `@version` | `26.11.13` | The chosen version |
| `CITATION.cff` `version` / `date-released` | `26.11.13` / `2026-11-13` | Match the chosen version and the real release date |
| `README.md` install snippet and the versioning paragraph | `~> 26.11.13` | Match the chosen version |
| `docs/tutorials/getting-started.md` | `~> 26.11.13` | Match the chosen version |
| `docs/reference/a2a-spec-version-mapping.md` `Version:` | `v26.11.13` | That file states it must equal `mix.exs`; update together |
| `CHANGELOG.md` | `[Unreleased]` holds the 26.11.14/15 notes | Rename to the released version and date; drop the version paragraph |
| `docs/reference/a2a-v1-1-conformance.md` | Evidence re-run on 2026-11-16 | Re-run at the clean release commit |
| `docs/explanation/pplan-seams.md` | `mix.lock` resolves `ash_pplan` 26.11.10 | Confirm against `mix.lock` at release |
| `engineering-standards.json` | Schema 26.9.21, carries no package version | Refresh only if the owner regenerates the adoption header |

`source_ref` in the ExDoc config is `"v#{@version}"`, so the source links in the published
docs point at the tag for whatever `@version` says; tag before publishing docs.

## Gates observed on 2026-11-17

Green means the command printed what is quoted and exited 0 in this tree on that day.

| Gate | Command | Observed |
|---|---|---|
| Prover | `mix ash_a2a.sim --prove` | green: `243 probes over 86 surface items: 243 pass, 0 fail, 0 skip` |
| Parity | `mix ash_a2a.sim --parity --strict` | green: `total 1283 pass, 0 fail, 0 known, 0 skip` (venv from `scripts/a2a_v1_1_parity/setup.sh`) |
| Docs tests | `mix test test/docs_truth_wave2_test.exs test/ash_a2a/docs_truth_test.exs test/docs_nav_coverage_test.exs test/ash_a2a/docs/catalogs_court_test.exs test/lane_l05/resubscribe_claim_test.exs` | green at the start of the pass (65 passed); re-run result at the end is in the hand-off |
| Breaking-change tests | `mix test.all` on the 15 files named in the CHANGELOG Breaking section | green: 132 passed and 34 passed across two runs; the first run's 34 failures were `The module AshA2A.Test.Fixture.* does not exist` while another process recompiled the shared build, and the same files passed on rerun |
| Other CHANGELOG-cited files | `mix test.all` on 19 more files (grpc must, generation stream, live session, card signatures, event journal ets/writer/ekv, doctor, grpc supervisor, email dkim/ledger, parity test) | green: 137 passed (24 excluded by the `serial_solo`/`serial_shard` tags) |
| Hex package | `mix hex.build --unpack -o <dir>` | green: exit 0; every file listed in the ExDoc extras is in the package |
| Install task | `mix test test/mix/tasks/ash_a2a_install_test.exs` | green: 11 passed |
| Doctor | `mix ash_a2a.doctor` | exits 1 on this repository (`authenticated_caller_disabled`, `config_receipt_binding_key_unset`); expected for the test configuration |
| Receipts | `mix ash_a2a.receipts.verify` | **red**: exit 1, three `verified_without_run_log` findings (`a10-ingress-wire.md`, `f2-copilot-wire-verify.md`, `z11-actuation.md`) |
| MCP drive | `python3 scripts/mcp_drive.py` | **red**: exit 1, 141 items served, 47 uncovered (email and authority surface items with no MCP mapping, added while this pass ran). Last clean run: 2026-11-16, 93 of 93. `--call` and `--list` work |
| Mutation gate | `mix ash_a2a.chicago.mutate --require-killed` | partly green: the full run killed 43 of 46 mutants and exited 1 (`blocked: 3`, `loaded AshA2A.Protocol.AgentCardSignature differs from its on-disk BEAM`: that module was recompiled in the shared build during the run); the three blocked ids (`card_alg_allowlist_ok`, `card_key_alg_ok`, `card_signature_verify_true`) rerun alone with `--only` were all killed and exited 0. Rerun the whole gate on a private build at the release commit |
| ExDoc | `MIX_ENV=dev mix docs` | DOCS_RESULT |

Not run in this pass: `mix test.all` over the whole suite (the coordinator runs it; the last
full run, on an earlier tree on 2026-11-16, was 5906 of 5955 with the failures environment-bound
or listed in the hand-off), `mix check`, `mix compile --warnings-as-errors` (a forced compile
prints about 40 compiler warnings, so expect it to fail until they are cleared) and
`mix format --check-formatted` over the whole tree (the pass formatted only its own files).
`scripts/verify_all.sh` runs the compile, format, prove, parity and MCP gates in one command.

## Blockers

1. The owner picks the publish version (see the table). Nothing else leads.
2. `mix ash_a2a.receipts.verify` exits 1 on three receipts that claim PASS without a run log.
   Attach the run logs or drop the PASS claim.
3. `python3 scripts/mcp_drive.py` exits 1 until every served surface item (including the email
   and authority items) has an MCP tool path in `AshA2A.Sim.MCP.Coverage`.
4. Run at the clean release commit, and record: `mix test.all --max-cases 6`, `mix check`,
   `mix compile --warnings-as-errors`, `mix format --check-formatted`, the mutation gate.
5. A2A v1.1 stays PARTIAL: no v1.1 TCK verdict exists, and upstream `v1.1.0-rc` is not a
   GitHub release. All 17 rows of `a2a-v1-1-conformance.md` are CONFORMANT in its sense (named
   courts pass), with the statement as a whole PARTIAL.
6. CI workflows that have never run on a remote runner: `.github/workflows/proofs.yml` and
   `.github/workflows/optional-deps.yml`. The local runs above are not CI evidence.
7. Three statements in `CHANGELOG.md` stay Unverified: the root supervisor strategy, the mount
   `tenant` row, and "`authorize?: true` is passed explicitly / extended-card provider failures
   carry no internal detail".
8. `README.md` says `main` runs ahead of published Hex; confirm no Hex release exists yet so
   "first publish" is accurate.
9. `mix.exs` `files:` omits `docs/archive`, yet `a2a-v1-1-conformance.md` links to
   `docs/archive/jira-releases/v26.11.13/RECEIPT.md`; the Hex copy carries a dead link. Mark the
   link repo-only or ship the file.

## Verification commands

```console
mix test.all --max-cases 6
mix check
mix compile --warnings-as-errors
mix format --check-formatted
mix ash_a2a.sim --prove
mix ash_a2a.sim --parity --strict
python3 scripts/mcp_drive.py
mix ash_a2a.chicago.mutate --require-killed
mix ash_a2a.receipts.verify
mix ash_a2a.doctor
mix hex.build --unpack -o /tmp/ash_a2a_hex
MIX_ENV=dev mix docs
mix test test/docs_truth_wave2_test.exs test/ash_a2a/docs_truth_test.exs test/docs_nav_coverage_test.exs test/ash_a2a/docs/catalogs_court_test.exs test/lane_l05/resubscribe_claim_test.exs
```

Run the mutation gate alone: it replaces loaded modules in its own VM while it runs.

## After the owner decides

- Edit `mix.exs`, `CITATION.cff`, `README.md`, `getting-started.md` and `a2a-spec-version-mapping.md`
  in one change.
- Rename `## [Unreleased]` in `CHANGELOG.md` and drop the version paragraph beneath it.
- Run the commands above at the release commit and record the results here.
