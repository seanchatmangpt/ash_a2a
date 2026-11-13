# Lane a-semantic receipt

Standing: PARTIAL

## Subject / files

- lib/ash_a2a/semantic/vocabulary.ex: added `sa_namespace/0` (single canonical `sa:` IRI; not in `@prefixes`,
  which is envelope-serialized and test-pinned).
- lib/ash_a2a/semantic/falsifier_suite.ex: `@sa` now `Vocabulary.sa_namespace()`.
- test/ash_a2a/semantic/sa_namespace_test.exs (new).

## Commands + exits

- `MIX_ENV=test MIX_BUILD_ROOT=_build-w2-a-semantic mix test test/ash_a2a/semantic test/ash_a2a/semantic_vocabulary_test.exs`
  exit 0: 8 doctests, 287 tests, 0 failures (1 excluded).
- Earlier runs hit a transient compile break in another lane's lib/ash_a2a/verify.ex (undefined `gate`);
  it resolved without my intervention. No edits made to other lanes' files.
- Build lease removed.

## Disclosures

- The oracle test (falsifier_sparql_oracle_test) is tag-skipped/excluded if no external engine; not asserted here.

## Not done

- SPARQL `:ask` via AshGraphLaw with structural differential oracle: BLOCKED. The vendored
  priv/graphlaw/praxis_graphlaw.wasm exports no sparql_ask (only blake3_hex, graph_hash, graphlaw_version,
  run_hooks, validate_all); a Praxis-side export is required. Structural evaluator unchanged.
