# Test consolidation merge

How the suite was reconciled after PR #117 merged into a `main` whose tests had been
consolidated.

## What happened

`main` carries a migration snapshot (`preserve(v26.11.16)`) in which about 880 original test
files were consolidated into 50 `*_consolidated_test.exs` files (each file header lists its
source files). PR #117 had modified some of the original files. The merge kept those originals
(a modify/delete resolution) and left the consolidated copies in place, so 186 test module
names, 193 with the restored files below, were defined twice. `mix test` could not compile
(`cannot compile module AshA2A.V1TelemetryConformanceTest`).

## Resolution

For every module defined in both a consolidated file and a separate original, the consolidated
copy is the pre-PR version and the original is the repaired one. The stale module blocks were
removed from the consolidated files (193 modules in 28 files; the original files are kept).
Each edited consolidated file starts with a `# NOTE:` line. The removal is reproducible:

    mix run --no-start scripts/dedupe_consolidated_tests.exs plan.json .

Two original files that the consolidation had deleted were restored because this work edited
them: `test/ash_a2a/chicago/mutation_harness_test.exs` and `test/http_json_binding_test.exs`.

Two mutation tests assumed an exact catalog size; `main`'s catalog also carries the
`strict_*`, `authority_policy_*` and `receipt_store_boot_*` mutants, so they now require at
least the original and wave-3 mutants. One doc citation was repointed from a deleted test file
to the consolidated file that now holds it.

Status: see the commit message of the merge-repair commit for the observed test results.
