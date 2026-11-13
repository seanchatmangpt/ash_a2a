# Wave 2 lane a-tests receipt

Standing: PARTIAL_ALIVE

## Subject / files

- test/ash_a2a_pplan_notify_test.exs: 3 negative-wait `Process.sleep(120/150)` replaced by
  `tick_barrier/1` (manual `:tick` + same-sender call, ordered); 2 poll steps annotated POLL-STEP.
- test/ash_a2a/telemetry/obs_hardening_test.exs: 3 `Process.sleep(50)` -> `Logger.flush()`.
- test/support/c2_harness/faults.ex: removed `sleep(120)` after `arm_crash` (synchronous file
  write); `wait_at_fault` now a monotonic 5s deadline poll (POLL-STEP annotated).
- test/telemetry_bridge/pplan_hazard_bridge_test.exs: `skip: not @live_producer` ->
  `skip: @live_skip_reason` (reason string).
- test/ash_a2a_skip_reason_discipline_test.exs: added `@boolean` regex catching
  `skip: true|not|!`.
- test/support/wo_checkin_sim_fixture.ex: unneeded quoted atoms unquoted.

## Commands + exits

- `mix compile --warnings-as-errors --force` (MIX_ENV=test, lease root): exit 0, no warnings
  (first attempt exit 1 on wo_checkin quoted atoms, fixed; an earlier attempt hit a-authority's
  in-flight verify.ex `gate` error, which its owner fixed; no edit by me).
- `mix test --seed {1,2,3}` on the 4 test files: exit 0 each, 19 tests, 0 failures (12 excluded).
- repo grep `skip: true|not|!` outside the discipline test: none found.
- `rm -rf _build-w2-a-tests`: done.

## Disclosures

- 12 tests excluded (by tags in test_helper / live-producer skip); the pplan_notify tests may be
  among the excluded, so the tick_barrier and faults.ex changes are compile-verified, with
  run-verification UNVERIFIED if those tests were excluded (c2 faults are subprocess-heavy).
- No other lane's files edited.

## Not done

- c2 faults.ex court not executed (needs prod subprocess harness).
- Baseline re-run on untouched tree not needed (no failures observed).
