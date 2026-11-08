# Lane T11 — pplan courts census completion (restart of F4)

Standing: PARTIAL_ALIVE

- Repo: /Users/sac/ash_a2a (no git commands used)
- Runner command: `ASH_PPLAN_PATH=/Users/sac/ash_pplan MIX_BUILD_ROOT=_build-laneF4 mix ash_a2a.pplan_courts`
  - exit 1, Standing BLOCKED, receipt `receipts/pplan-courts-20261108.md`
  - resumed F4's warm build root incrementally (~17 min, incl. ash_pplan path-dep recompile)
- True 4-court verdict: 2 pass (conformance 12 tests, hazard-bridge 11 tests);
  task_run_binding passes standalone (6 tests, rc=1 under runner = cross-court
  VM state bleed, not a defect); durability court fails 4/4.
- Durability disposition: single failure class — dispatch effects never
  execute (prepare/finish 0; tests :433, :467, :493). Distinct from the known
  loud-skip boundary (prepare:2/finish:1). Regression source = in-flight
  /Users/sac/ash_pplan lib/ edits after the 2026-11-07T22:57Z PASS receipt
  (`receipts/pplan-courts-20261107.md` shows 4/0 durability). T10 unreachable
  (SendMessage refused: "No agent named 'T10'"), no path-build lock observed
  at run time — proceeded bounded. Disposition: ash_pplan-lane-owned BLOCKED;
  not repairable from ash_a2a.
- Doc finalized: docs/how-to/run-pplan-courts.md — added "Current census
  (as of 2026-11-08)" table with the true numbers + new failure class.
- Runner receipt annotated (appended census section, runner's own lines untouched).
- Falsifier for the BLOCKED row: re-run the runner after ash_pplan dispatch
  repair; a full-PASS receipt flips the doc's census table.

See Also: receipts/pplan-courts-20261108.md · docs/how-to/run-pplan-courts.md
