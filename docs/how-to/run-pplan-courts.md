# How-To: Run the pplan integration courts

One command runs every cross-repo ash_pplan integration court landed by the
I-lanes:

```console
$ mix ash_a2a.pplan_courts
```

## Prerequisites

- The `ash_a2a` checkout compiles (`mix compile`).
- For path mode (see below): a local `~/ash_pplan` checkout.
- Optional, for parity courts only: `python3` on PATH and
  `~/ash_pplan/scripts/airbus_oracle_daemon.py` (started with `--with-oracle`).

## Court convention

A court is any ExUnit file under `test/` whose module is tagged:

```elixir
@moduletag :pplan_court
```

Discovery is content-based: any `.exs` under `test/` containing the tag
string is a court file. The default tag is `pplan_court`; override with
`--only <tag>` if a wave used a different convention.

## Path mode vs hex mode

- **Hex mode** (default of the repo's deps): tests run against the released
  `ash_pplan` hex package. No path configuration needed.
- **Path mode**: set the ash_pplan checkout explicitly so the courts hit
  your in-flight local changes:

  ```console
  $ mix ash_a2a.pplan_courts --ash-pplan-path ~/ash_pplan
  ```

  The task exports `ASH_PPLAN_PATH` into each court's environment; parity
  courts that shell out to the oracle read it from there. Default is
  `~/ash_pplan` when that directory exists.

## Options

| Option | Meaning |
|---|---|
| `--only TAG` | filter tag (default `pplan_court`) |
| `--no-run-serial` | run each court file WITHOUT `--include serial` (default is WITH it, so `@tag :serial` tests still run) |
| `--with-oracle` | start `~/ash_pplan/scripts/airbus_oracle_daemon.py` for the run, stop it after |
| `--ash-pplan-path PATH` | ash_pplan checkout for path mode (default `~/ash_pplan` if present) |
| `--receipt PATH` | receipt output path (default `receipts/pplan-courts-<date>.md`) |

## Fail-closed law

- A court file that fails to **compile** makes the task exit nonzero naming
  the file. Compile-abort is not zero failures.
- A court test failure makes the task exit nonzero with the receipt path.
- **Zero discovered courts is never a pass.** The receipt says
  `Standing: UNVERIFIED` and the census prints loudly; exit is 0 only
  because an honest empty census is a legal mid-wave state.
- `--with-oracle` with a missing daemon script is a loud skip, never a
  silent pass.

## Serial pass and the Z18 kill-court loud skip

All four landed courts (`test/replan/port_ashpplan_conformance_court_test.exs`,
`test/execution/task_run_binding_test.exs`,
`test/telemetry_bridge/pplan_hazard_bridge_test.exs`,
`test/execution/pplan_dispatch_durability_test.exs`) carry
`@moduletag :pplan_court`, so the default invocation discovers exactly those
four. By default each file is run ONCE with `--only <tag> --include serial`
(`--include serial` cancels ExUnit's alias-level `--exclude serial`, so tests
tagged `@tag :serial` are not silently filtered to 0 tests). Pass
`--no-run-serial` to opt out.

The I2 dispatch-durability court contains one **loud-skip** test: the
kill-between-effect-and-checkpoint case. Its skip reason names the precise
residual boundary — kill between a step's effect execution and its `record`
checkpoint. Upstream ash_pplan's atomic consume-once `take_signal` (one
serialized store transition: find/adopt-or-insert checkpoint + consume signal
+ release waiter) closed the Await replay window, but that boundary has no
intent-before-effect guard, so resume re-executes the effect (observed
2026-11-07 on the real Dets stack: `%{prepare: 2, finish: 1}`, all other law
assertions passing). Pending upstream intent-before-effect (claim_undo before
the effect); not fixable from the ash_a2a repo. A skip is honest census, not
a pass: it appears in the ExUnit summary line and never silences.

## Current census (as of 2026-11-08, path mode vs `~/ash_pplan`)

True numbers from the settled post-wave runner run
(`receipts/pplan-courts-20261108.md`): 4 courts discovered, Standing
`BLOCKED` (exit 1).

| Court | Result | Note |
|---|---|---|
| `test/replan/port_ashpplan_conformance_court_test.exs` | pass (12 tests) | stable |
| `test/telemetry_bridge/pplan_hazard_bridge_test.exs` | pass (11 tests) | stable |
| `test/execution/task_run_binding_test.exs` | fail rc=1 under the runner, but **passes standalone** (6 tests, 0 failures) | cross-court state bleed in the shared runner VM, not a real defect |
| `test/execution/pplan_dispatch_durability_test.exs` | fail 4 tests, 4 failures | ash_pplan substrate regression — see below |

Durability-court failure class (new, distinct from the loud-skip boundary
above): dispatch effects never execute at all — prepare/finish counts come
back 0 (tests at lines 433, 467, 493). The known loud-skip boundary showed
`prepare: 2, finish: 1` (resume re-executes an effect that ran); this class
shows the effect never ran. Source is in-flight `lib/` edits in the ash_pplan
checkout, not the ash_a2a courts; not fixable from the ash_a2a repo. When
ash_pplan's dispatch path is repaired, re-run the runner for the true
full-PASS receipt.

## Receipt

The runner writes a receipt at `receipts/pplan-courts-<date>.md` (or the
`--receipt` path) with a `Standing:` line (`PASS` when every court passes,
`BLOCKED` on any failure/compile-abort, `UNVERIFIED` on honest empty census),
the discovered-file count, overall status, and per-file exits
(`rc=/status=/<summary line>` per file).

## Example receipt

```markdown
# pplan courts receipt (2026-11-07T12:00:00Z)

Standing: UNVERIFIED

- tag: :pplan_court
- discovered files: 0
- overall: no_courts
- receipt path: receipts/pplan-courts-20261107.md

## Per-file exits

  (no court files discovered for tag :pplan_court -- honest empty census, UNVERIFIED)
```

A full run lists one row per file:

```markdown
## Per-file exits

  - test/replan/replan_court_test.exs: rc=0 status=pass 3 tests, 0 failures
```

## See Also

- `lib/mix/tasks/ash_a2a.pplan_courts.ex` (the runner)
- `docs/how-to/` sibling guides
