# Lane a-copilot receipt

Standing: PARTIAL_ALIVE

## Subject / files

- lib/ash_a2a/strain/bridge.ex: no auto-register of unknown coordinator ids (unchanged mesh_state; unknown type still raises).
- lib/ash_a2a/copilot/pipeline.ex: opt-in `:coordinator_binding` (map or 1-arity fun, actor_id -> coordinator_id);
  mismatch/missing actor refused `:coordinator_mismatch`, no observation folded. Observable skip telemetry
  `[:ash_a2a,:copilot,:stage_skipped]` for binding / mechanical_prior / authority_source absent.
  `init/2` registers mesh ids in bridge; `record` registers only ids present in the COO mesh.
- test/copilot/f8_adversarial_test.exs: forged-coordinator test, no-auto-register test, skip-telemetry test (test file, outside owned list; disclosed).

## Commands + exits

- `MIX_ENV=test MIX_BUILD_ROOT=_build-w2-a-copilot mix test test/copilot test/strain test/twin test/attention test/ingress`
  - first run after fix: 202 tests, 1 failure (twin/server_test.exs:53, 1s deadline, load flake; file not owned by this lane).
    Alone: 10 tests 0 failures, twice. Second full run: 202 tests, 1 failure (same test, reproducible in full run, passes alone; twin/server.ex has other dirty edits, not this lane). Build dir removed.

## Disclosures

- Binding is opt-in; without it behavior is unchanged except telemetry (callers must pass it to get protection).
- Pre-existing warning: unused advance_shift/3 in test/copilot/pipeline_test.exs.

## Not done

- CEO default-prior reconciliation (RefuseAll default vs pipeline detect_prior): not changed, needs design decision.
- ingress/channel.ex not touched (no binding wiring from channel to Pipeline opts).
