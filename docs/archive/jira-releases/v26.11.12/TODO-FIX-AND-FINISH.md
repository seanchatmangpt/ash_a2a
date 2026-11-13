# TODO-FIX-AND-FINISH (ash_a2a)

Standing: UNVERIFIED

Source: `ash_surface/docs/jira/v26.11.11/PROJECT-REVIEWS.md` R1, re-read where marked confirmed.

## Fix

- HIGH `lib/ash_a2a/authority/source/allow_all.ex` prod guard exists only as uncommitted edit
  (confirmed `git status`: ` M`; guard returns `{:deny, :allow_all_in_prod}`). Check: committed
  and `git diff HEAD -- that file` empty.
- MED `lib/ash_a2a/a2a_transport/plug.ex:319-321` bare `rescue` falls back to unscoped delegate
  (confirmed, comment "delegate_fallback"). Check: court shows encode failure is scoped/typed.
- MED `lib/ash_a2a/protocol/task/orphan_sweep.ex:55` `:ok = store_mod.put(...)` can raise
  MatchError (confirmed); unbounded `list_all`, no CAS, local-only `live?` UNVERIFIED.
- MED sweep errors swallowed near `lib/ash_a2a/transport/runtime.ex:440` UNVERIFIED (path moved).
- MED `mix.exs:348-360` ash_graphlaw path-vs-Hex build skew (confirmed branch logic).
  Check: one dependency source in CI.
- MED `lib/ash_a2a/schema.ex` embedded recursion cycle guard UNVERIFIED; `maybe_required`
  (`schema.ex:215-217`) ignores defaults (confirmed allow_nil?-only).
- LOW 64 `Process.sleep` in 50 test files, unannotated; sleep_gate does not cover them
  (confirmed counts). Check: `bash scripts/sleep_gate.sh` exits 0 with test dir included.
- LOW atom minting from CLI args, narrow mock-discipline grep, stale CHANGELOG, Decimal as JSON
  number: UNVERIFIED.

## Finish

- Make `sleep_gate.sh` gate tests, not only `lib` (CI step at `.github/workflows/ci.yml:535`).
- Orphan sweep: bounded list, CAS put, error propagation. Check: `orphan_sweep_runtime_test`.
- Widen mock-discipline court to hand-rolled fakes. Check: planted fake fails the court.

## Commit hygiene

Tracked code references these untracked files (confirmed `git status ??`); clean checkout breaks:
- `lib/ash_a2a/protocol/task/orphan_sweep.ex` (used by `transport/runtime.ex`)
- `lib/ash_a2a/telemetry/dispatch_event.ex` (used by ocel_broadcaster/forwarder)
- `lib/ash_a2a/verifiers/verify_hddl_operators.ex` (used by verify_skills.ex)
- `test/support/eventually.ex`, `scripts/sleep_gate.sh` (CI references it)
- `test/ash_a2a/protocol/orphan_sweep_unsupported_test.exs`,
  `test/execution/orphan_sweep_runtime_test.exs`.
- `lib/ash_a2a/wire/jcs.ex` is tracked (R1 listed it; not a defect).
- Modified authority files (`broker.ex`, `graph_pin.ex`, `pep.ex`, `source.ex`) uncommitted.
Check: `git status --short | grep '??'` shows none of the above.

## Decide

- ash_graphlaw: Hex pin or sibling path as the canonical CI source.
- Retire or sync `ash_a2a_head` (older snapshot, same version 26.10.9).

## Reuse

- `lib/ash_a2a/schema.ex` for_action/build typed unserializable-type errors.
- `lib/ash_a2a/capability_index/compiler.ex` + `validator.ex` stable ids, fail-closed gate.
- `lib/ash_a2a/identity/canonical.ex` JCS + sha256 digest.
- `lib/ash_a2a/transport/schema_endpoints.ex` schema endpoints.

## See Also

`ash_surface/docs/jira/v26.11.11/PROJECT-REVIEWS.md` · `../../../../ash_a2a_head`
