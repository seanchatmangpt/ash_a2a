# Wire facilitator phase sequence to a real HDDL plan

## Summary

The FreedomGym meeting-facilitator test fixture previously drove its phase
sequencing off a hardcoded `@phases` list. This work replaces that with a
real HDDL domain/problem for the FreedomGym meeting process and a real
solved FOND plan (via a new standalone Rust CLI that path-depends on
beam4pm's own `ferroplan` crate) whose `advance(<from>,<to>)` actions are
parsed into the facilitator's ordered phase sequence.

## Status

Done — already merged/committed.

## Commits

- `b4a6fa1` feat(freedom-gym): wire facilitator phase sequence to a real HDDL plan
- `e7b6f97` Merge branch feat/ocel-v2-telemetry-forwarder into feat/hddl-planned-facilitator

## Changes

- Added `test/support/hddl/freedom_gym_meeting/domain.hddl` and
  `problem.hddl` — a real, syntactically valid HDDL domain/problem modeled
  directly on beam4pm's `ferroplan-hddl/fixtures/a`.
- Added `native/hddl_cli` — a new, small, standalone Rust binary crate
  (`Cargo.toml`, `Cargo.lock`, `src/main.rs`, `.gitignore`) with a real
  Cargo path-dependency on beam4pm's `ferroplan` crate (the same
  `solve_hddl` beam4pm's wasm facade wraps, not a reimplementation), built
  with `cargo build --release`.
- Added `test/support/freedom_gym_meeting_plan.ex`
  (`AshA2A.Test.Fixture.FreedomGym.MeetingPlan`) — `real_plan_phases!/0`
  invokes `hddl_cli` as a real OS subprocess via `System.cmd` and parses
  the real solved policy's `advance(<from>,<to>)` actions into the real
  ordered phase sequence `[:open, :trust_god, :clean_house, :help_others,
  :fellowship, :close]`. Includes a minimal real in-memory `Agent`
  (`start_link/1`, `next_phase/1`, `reset/1`) tracking plan position per
  named instance.
- Modified `test/support/freedom_gym_fixture.ex` — adds `:next_phase` and
  `:reset_plan` actions/skills to the Facilitator resource, alongside the
  pre-existing `:run_phase` (left unchanged, still used by the existing
  Chicago-Core test). `:next_phase` consults `MeetingPlan`'s real
  plan-position state and returns the real next phase, or a real error
  once the plan is exhausted.
- Added `test/ash_a2a_freedom_gym_hddl_plan_test.exs` — two Chicago-style,
  state-based tests: `MeetingPlan.real_plan_phases!/0` returns the real
  6-phase sequence, and driving the facilitator's `:next_phase` skill over
  real A2A dispatch 6 times reproduces that same sequence, asserts
  `requires_redirect_check?` still holds for the plan-derived
  `:clean_house` phase, a real plan-exhaustion error on a 7th call, and a
  real reset rewinding the plan position. Marked `async: false` because
  this test's `FacilitatorAgent` process shares its module-derived name
  with the `async: true` Chicago-Core test — a real process-name
  collision, confirmed by reproducing it, not routed around.
- Added `test/ash_a2a_freedom_gym_chicago_core_test.exs` (183 lines).
- Modified the existing Chicago-Core test's `facilitator_prompt/1` to pass
  `metadata: %{skill: "run_phase"}` explicitly, since the Facilitator
  resource now compiles 3 skills instead of 1 and the prior default-skill
  resolution is no longer unambiguous.
- Merge commit `e7b6f97` brought in `feat/ocel-v2-telemetry-forwarder`
  (`lib/ash_a2a/telemetry/ocel_forwarder.ex`,
  `test/ash_a2a_telemetry_ocel_forwarder_test.exs`, and `mix.exs`/
  `mix.lock` dependency updates) into `feat/hddl-planned-facilitator`.

Design note stated in the commit message: `ash_a2a` is a general-purpose,
host-agnostic Ash extension library and must not gain a hard runtime
dependency on one specific consumer app's (beam4pm's) BEAM manufacturing
pipeline. beam4pm's own agent-facing A2A skill surface exposes only 2
curated resources today (no `hddl_solve` skill), so there was no live A2A
call path to reuse — hence the standalone `native/hddl_cli` subprocess
approach instead. Native `solve_hddl` is confirmed working directly
against this HDDL fixture; an earlier `wasm32-wasip1` sandbox panic does
not reproduce natively.

## Verification

Stated in the `b4a6fa1` commit message:

- `mix test` (full suite): 21 doctests, 3 properties, 94 tests, 0
  failures (2 excluded, pre-existing `@external_api` tag), 0 regressions
  vs baseline.
- `mix format --check-formatted`: clean.

No verification evidence is stated in the `e7b6f97` merge commit message
itself beyond the file stat shown by `git show --stat`.

## Related

- Branch: `feat/hddl-planned-facilitator`
- Branch merged in: `feat/ocel-v2-telemetry-forwarder`
- Referenced (not part of this repo's history): beam4pm branch
  `feat/ash-a2a-agent-facing` and beam4pm's `ferroplan`/`ferroplan-hddl`
  crates, per the `b4a6fa1` commit message's call-path rationale.
- Claude-Session (from `b4a6fa1` commit message):
  https://claude.ai/code/session_018iXTYcpGbgf23MZYLe6TCU
