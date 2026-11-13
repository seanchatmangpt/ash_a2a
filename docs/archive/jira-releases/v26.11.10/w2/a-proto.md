# Wave 2 lane a-proto receipt

Standing: PASS

## Subject / files

- lib/ash_a2a/protocol/agent.ex: `{:ash_a2a_list_tasks, principal, params}` now answers via
  `AshA2A.Transport.Runtime.list_tasks_for/3` (owner-scoped, store read-through, anonymous never lists).
- lib/ash_a2a/protocol/task/orphan_sweep.ex: missing `list_all/2` -> Logger.error + telemetry
  `[:ash_a2a,:task,:orphan_sweep_unsupported]` + typed error; `list_all` non-ok result -> typed error
  (was a MatchError).
- New test: test/ash_a2a/protocol/orphan_sweep_unsupported_test.exs.
- protocol/task_store.ex: no change needed.

## Commands + exits

- `mix test test/ash_a2a/protocol test/ash_a2a/a2a_transport test/ash_a2a_v1_bidi_test.exs`
  (MIX_ENV=test, lease root _build-w2-a-proto): exit 0, 105 tests, 0 failures (after doc unblock).
  First run: 1 failure (spec_mapping_doc_test, doc said bare plug -32004) -> introduced by this change, fixed.
- New orphan-sweep test run: see coordinator re-run (run once, result below).

## Disclosures

- Minimal-unblock outside owned files: docs/reference/a2a-spec-version-mapping.md (ListTasks row
  and tasks/list paragraph updated to match new behavior); a-docs lane should not revert.
- Early compile failure at lib/ash_a2a/verify.ex (undefined `gate`, a-authority in-flight) cleared by itself; not touched.

## Not done

- No dedicated owner-scoping test for a bare Protocol.Agent listing beyond the existing doc-observation court.
