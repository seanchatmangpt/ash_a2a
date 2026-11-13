# Lane a-chicago receipt

Standing: PASS

## Subject / files
Added `# SLEEP-CLASS: SCHEDULING|POLL-STEP (reason)` annotations (comment-only, no logic change)
to all 14 unannotated `Process.sleep` sites: chicago/mutation.ex, chicago/fixtures/{chaos_reconciliation(3),
autonomy_bounds,logic_sparql,fibo_finance}.ex, chicago/courts/{safe_logic,mutation_court,grant_lifecycle,
crash_reconciliation(2)}.ex, telemetry/siem.ex, runtime_identity/execution.ex.
POLL-STEP: mutation soft_purge, chaos wait_until, logic_sparql wait_for, execution RSS sampler.
SCHEDULING: fixture stalls, real-time lease/expiry/backoff intervals, parked processes.

## Commands + exits
- `bash scripts/sleep_gate.sh` before: exit 1 (14 UNANNOTATED); after: exit 0 "sleep_gate: clean".
- `mix compile --warnings-as-errors` (lease build root): exit 0.
- `mix test test/hardening_lane09_test.exs test/ash_a2a_command_bus_crash_window_chicago_test.exs
  test/ash_a2a_freedom_gym_chicago_core_test.exs`: exit 0, 12 tests, 0 failures (1 excluded).

## Disclosures
- No other lane's files touched. safe_logic settle_connections (150ms) and grant/lease waits are
  annotated, not converted to polls (real-time intervals / no clear observable target).
- hardening_lane09_test.exs not edited.

## Not done
- safe_logic.ex:929 settle window could become a stable-count poll; left as SCHEDULING.
