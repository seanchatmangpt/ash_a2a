# Lane a-docs receipt

Standing: PARTIAL

## Subject / files

- `docs/reference/a2a-v1-conformance.md` line 102: 34 -> 35 court files (verified: `@v1_courts`
  has 35 entries, all exist on disk).
- `docs/jira/v26.11.10/OPEN-ITEMS.md`: rows L17-L19 added (sourced from WAVE2-BACKLOG.md and
  beam4pm-dogfood-receipt.md; no wave-1 lane reports were on disk).
- `priv/sa2a_conformance/MANIFEST.json`: `rules/denials.n3` entry (bytes 1051->1712, sha256,
  blake3) refreshed with `shasum -a 256` / `b3sum` (b3sum confirmed equal to the recorded wasm
  blake3 on unchanged profile.ttl). Not hand-typed.

## Commands + exits

- `mix test test/ash_a2a_sa2a_corpus_test.exs test/ash_a2a/docs_truth_test.exs`: 75 tests, 0 failures.
- `mix test test/ash_a2a/docs test/docs_nav_coverage_test.exs test/ash_a2a/docs_truth_test.exs`:
  58 tests, 1 failure (CatalogsCourtTest RD2: telemetry.md lacks `ash_a2a.copilot.stage_skipped`,
  `ash_a2a.ocel.ignored`, `ash_a2a.task.orphan_sweep_unsupported`; events from other lanes, file
  `docs/reference/telemetry.md` not owned by a-docs).
- An early run failed to compile (`lib/ash_a2a/verify.ex` undefined `gate`, a-authority in-flight);
  later compile succeeded.

## Disclosures

- `docs/reference/tck-suite.md` still says 34 courts (lines 51, 53); not owned, left.
- Denials.n3 changed in committed ca22688d without a manifest update; the corpus test passes after
  the refresh. Vector `law_graph_digest` values were not recomputed (corpus test passes).
- Build lease `_build-w2-a-docs` removed.

## Not done

- `docs/reference/generated/reference.md` regeneration: no generator in this repo's ggen.toml
  produces it; `ggen sync run --dry-run` fails FM-PACK-008 (ggen.lock pack hash mismatch; re-lock
  is a decision). Left untouched.
- telemetry.md rows for the 3 new event families (owner: telemetry docs / other lanes).
