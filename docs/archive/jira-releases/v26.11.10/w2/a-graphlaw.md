# Lane a-graphlaw receipt

Standing: PARTIAL_ALIVE

## Subject / files

- lib/ash_a2a/graphlaw.ex: new `resolve_wasm_path/1` (existence-checked, typed
  `:graphlaw_wasm_missing`) and `wasm_path_unchecked/1`; single env var `PRAXIS_GRAPHLAW_WASM`.
- graph_law/{wasm_driver,runtime,wasmex_host,wasmtime_runtime}.ex and
  semantic/root_manifest/engine_probe.ex: resolvers delegate to it (legacy
  `GRAPHLAW_WASM_PATH`/`GRAPHLAW_WASM` env reads removed).
- graph_law/engine_load.ex: `:unpinned` refused (`:graphlaw_wasm_unpinned_refused`) unless compiled in test env.
- semantic/hook_reactor/engine.ex: `open/1` returns real sha256 of the resolved wasm (nil removed);
  `close/1` documented no-op on the shared pool.

## Commands + exits

- `MIX_ENV=test MIX_BUILD_ROOT=_build-w2-a-graphlaw mix test test/ash_a2a/graph_law*
  test/ash_a2a/semantic/engine* test/semantic_lane12_engine_test.exs
  test/ash_a2a/chicago/wasm_default_resolution_test.exs`: exit 0, 43 tests, 0 failures, 54 excluded.

## Disclosures

- 54 tests excluded by tags; not run. No new test added for unpinned refusal / missing-path.
- hook_reactor digest is sha256 of the resolved artifact, not proof that AshGraphLaw loaded those bytes.
- Test file wasm_default_resolution_test.exs and semantic_admission_hash_test.exs mention the old env
  names (not owned; test still passed).

## Not done

- Tests for the new refusals; Wasmex session path-override unpin logic unchanged in test env.
