# A2A-2602: OCEL async forwarding is unbounded supervised-task fan-out

- **Status**: Closed — implemented + Chicago-validated (2026-09-15)
- **Severity**: Medium
- **Standing**: ALIVE for this fix (full suite: 382 tests, 0 failures, `fix/v26.9.15-commandbus-outbox` @ 1e35c30, worktree `wt-v26915/ash_a2a`)
- **Closure evidence**: `AshA2A.Application` starts the telemetry `Task.Supervisor` with `max_children` (`:ocel_max_in_flight`, default 256); beyond the ceiling the forwarder accounts an explicit shed (`:counters` total via `shed_count/0` + one `[:ash_a2a, :ocel, :shed]` telemetry per drop, no log flood). Chicago suite `test/ash_a2a_telemetry_ocel_forwarder_bounded_test.exs` bursts 12 real dispatches against a real slow Bandit ingest with `max_children: 2` and proves observed concurrency stays <= 2 and `served + shed == burst` (every drop accounted).
- **Found by**: 14-hour cross-repo code review, window 2026-09-14 9:40 PM → 2026-09-15 11:40 AM PDT (inspection, not execution)

## Evidence

OCEL egress was correctly moved out of the single agent mailbox this window. But the forwarder starts one supervised task per event (`lib/ash_a2a/telemetry/ocel_forwarder.ex:97`, supervisor declared at `lib/ash_a2a/application.ex:39` as `AshA2A.Telemetry.TaskSupervisor`) with:

- no `max_children`,
- no queue,
- no shedding policy,
- no bounded buffer.

The HTTP timeout merely bounds each task's lifetime.

## Impact

A sufficiently large telemetry burst can turn an observational subsystem into BEAM resource pressure — process count and in-flight HTTP connections grow with the event burst, not with a configured budget. Ranked #5 in the cross-repo closure order.

## Fix

Bound the fan-out: set `max_children` on the `Task.Supervisor`, add a bounded queue/buffer with explicit overflow policy, and shed/backpressure excess events with a typed refusal or shed-counter so dropped telemetry is observable rather than silent.

## Falsifier (acceptance)

Burst N ≫ max events at the forwarder. Assert:

- observed concurrency never exceeds the configured bound,
- process count does not grow unboundedly with the burst,
- shed events are accounted (counter/refusal), not silently lost.
