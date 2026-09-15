# A2A-2602: bounded OCEL forwarding fan-out

- **Status**: Implemented; exact-head verification required before merge.
- **Severity**: Medium.
- **Standing**: `BUILD_UNVERIFIED` for the current PR head. No publication, production, runtime-standing, or `ALIVE` claim.
- **Found by**: 14-hour cross-repo review, 2026-09-14 9:40 PM → 2026-09-15 11:40 AM PDT.

## Boundary

`AshA2A.Application` starts `AshA2A.Telemetry.TaskSupervisor` with `max_children` from `:ocel_max_in_flight` (default 256). That supervisor admission limit is the hard concurrency ceiling for asynchronous OCEL HTTP forwarding.

An event that cannot enter the supervisor is shed rather than spawning outside the budget. `AshA2A.Telemetry.OcelForwarder.shed_count/0` increments once per shed and one `[:ash_a2a, :ocel, :shed]` telemetry event is emitted with the admission-failure reason.

The accounting applies to `:max_children` and to other task-admission failures such as an unavailable task supervisor. HTTP failures *after* a task has been admitted remain best-effort observational delivery failures; they do not increase task concurrency beyond the supervisor bound.

## Chicago falsifiers

`test/ash_a2a_telemetry_ocel_forwarder_bounded_test.exs` defines two acceptance falsifiers:

1. Burst 12 real dispatch events against a real slow Bandit ingest with `max_children: 2`; observed HTTP concurrency and supervised workers must stay `<= 2`, and `served + shed == 12`.
2. Route an event to a missing task supervisor; the dispatch caller must not crash and the event must increment the shed counter and emit shed telemetry.

## Evidence boundary

The predecessor head `429246c` had a hosted CI run that admitted the exact SHA but failed at `mix format --check-formatted`; compile and tests were skipped. The earlier local 382-test report therefore does not qualify the current head.

Current-head admission requires repository-native exact-head CI to pass checkout identity, formatter, warnings-as-errors compile, and the full test suite including both bounded-fan-out falsifiers.
