# Lane a-replan receipt

Standing: PARTIAL_ALIVE

## Subject / files
- lib/ash_a2a/replan/port/ferroplan.ex: rewritten to HTTP A2A (`:ferroplan_url`, falls back to
  `:beam4pm_url`); typed `{:error, :ferroplan_unavailable}` with no URL.
- lib/ash_a2a/planning.ex: `plan_with_ferroplan` delegates to Port.Ferroplan; no `BeamPM.*`.
- lib/ash_a2a/callback_registry.ex: removed `BeamPM.Ferroplan` member.
- lib/ash_a2a/replan/provider_registry.ex: `boot_check/0` warning (not wired to boot, see below).
- lib/ash_a2a/consequence_kernel/closure/exceptions.ex: dropped Ferroplan apply/3 entry; fixed
  Beam4pm entry (propose/2 -> propose_local/2, was stale + unlisted).
- Tests: test/ash_a2a/replan/ferroplan_port_test.exs (extended).
- Minimal unblock (not owned): test/ash_a2a/safe_exec/callback_registry_test.exs, BeamPM.Ferroplan
  assertions updated to match the removed registry member.

## Commands + exits
- `mix test test/ash_a2a/replan test/ash_a2a/planning test/ash_a2a/planning_test.exs
  test/ash_a2a/c1_closure test/ash_a2a/safe_exec` -> exit 2: 145 tests, 2 failures (closure court).
  Initial failures included my Beam4pm entry; after fixing, `ClosureCourt.report()` shows only
  OrphanSweep.fail_orphans/6 unlisted + OrphanSweep.sweep/2 stale (a-proto's file; not re-run
  as a full test after the fix).
- `grep -rn 'BeamPM\.' lib` -> only 2 doc-comment hits in telemetry/castle_ocel.ex (not owned).
- First compile blocked by a-authority's in-flight verify.ex error; retried by bounded poll, cleared.

## Disclosures
- Ferroplan HTTP skill name `ferroplan_plan_production` is an assumption; no live server exercised.
- Tests cover unavailable/unreachable paths only, no successful round trip.
- boot_check/0 needs a caller in application.ex (not owned).

## Not done
- Wire boot_check into application start; castle_ocel.ex comment hits; OrphanSweep exception (a-proto).
