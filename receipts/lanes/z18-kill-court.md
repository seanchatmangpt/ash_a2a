# Lane W3 — Z18 Kill-Court Closure Receipt

Standing: PARTIAL_ALIVE

Standing note: 3 of 4 durability courts PASS in ASH_PPLAN_PATH mode; the kill
court remains SKIPPED LOUDLY, now at the precise residual boundary instead of
the vague "pending upstream W1".

## Lane / files

- test/execution/pplan_dispatch_durability_test.exs (note: moved from
  test/actuation/ to test/execution/ by another lane mid-session, mtime
  16:08 — this lane adopted the new path, zero content conflicts).
- Kill court UNSKIPPED and RUN FOR REAL in ASH_PPLAN_PATH mode against
  /Users/sac/ash_pplan: it FAILS with exactly the EXPECTED-PRE-W1 signature
  `%{prepare: 2, finish: 1}` (duplicate prepare after kill-before-checkpoint
  + resume; all other law assertions passing). So the residual boundary is
  NOT the (now-atomic) take_signal Await replay window — upstream ash_pplan
  has the atomic consume-once take_signal (dets.ex, one serialized
  transition: find/adopt-or-insert cp + consume signal + release waiter) —
  the residual window is kill between a step's EFFECT execution and its
  `record` checkpoint: no intent-before-effect guard upstream; resume
  re-executes the effect. Not fixable from ash_a2a.
- Skip tag restored as SKIP-LOUD with that precise boundary (and moduledoc
  clause 4 updated to match).
- Disclosed minimal upstream fix (ash_pplan, one line): lib/ash_pplan/reactor/
  durable/steps/await.ex — the new atomic take_signal call passed the SIGNAL
  name as the checkpoint label (tape showed `"go"` instead of the step URN
  `"urn:ash-pplan:workflow:<model>#step-await"`); the label law (step
  identity, and runtime.ex:265 keys outputs by cp label) requires the STEP
  name's label. Changed `Key.label(name)` → `Key.label(context.durable_step.name)`.
- Compile-freeze event: first re-run raced another lane's mid-write to
  ash_pplan wal.ex (mismatched-delimiter compile error at wal.ex:932); the
  file tokenized clean on retry — no unblock edit applied by this lane.

## Gates (commands / exits)

- `cd /Users/sac/ash_a2a && ASH_PPLAN_PATH=/Users/sac/ash_pplan
  MIX_BUILD_ROOT=_build-laneW3 mix test test/execution/pplan_dispatch_durability_test.exs --include serial`
  → unskipped run: 4 tests, 1 failure (`prepare: 2, finish: 1` — the
  EXPECTED-PRE-W1 signature); then 10 tests, 0 failures, 1 skipped after the
  precise skip landed.
- Combined gate: `mix test test/actuation/ test/execution/ --include serial`
  (path mode) → **19 tests, 0 failures, 1 skipped**; `mix compile` exit 0.
- Upstream regression for the await label fix:
  `cd /Users/sac/ash_pplan && MIX_BUILD_ROOT=_build-laneW3 mix test
  test/durable/await_test.exs test/durable/extra_await_test.exs` →
  **19 tests, 0 failures**.
- Clean checkout replay note: kill court unskipped fails deterministically
  with `%{prepare: 2, finish: 1}`; other 3 courts pass — the skip is
  non-vacuous (ran it, it fails for the recorded reason).
