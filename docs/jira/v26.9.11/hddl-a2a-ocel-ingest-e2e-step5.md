# Real HDDL->A2A->OCEL ingest e2e capture (Step 5)

## Summary

Adds the real end-to-end leg of the plan-execute-conform loop for FreedomGym:
drives the real `FacilitatorAgent :next_phase` A2A skill (Step 3's real
HDDL-plan-derived sequencing) for 3 reference meetings plus 1 deviant meeting
(a real dispatch run with the `clean_house` phase event deliberately dropped
before ingest), POSTs each real returned phase as a real OCEL v2 event to
beam4pm's real, live `BeamPM.OcelIngest.Router` (`POST /ocel/events`, real
`201` responses confirmed), and captures the real accepted-event echoes to
`../beam4pm/qualification/gym_bridge/{reference,deviant}_ocel_events.json`
for beam4pm's own `BeamPM.PowlConformance` test to read and check for real.

Also exercises the already-real `AshA2A.Telemetry.OcelForwarder` (attached
for real; fires on every real dispatch's `:telemetry.span` stop event). The
test's own moduledoc discloses that this generic forwarder's `event_type` is
skill-level (`ash_a2a.dispatch.<resource>.<skill>`), not phase-level, since
dispatch stop metadata never carries reply data and so cannot itself supply
per-phase OCEL activities — this test therefore posts the real per-phase
events the conformance check needs separately.

## Status

Done - already merged/committed.

## Commits

- `8da06e8` test(freedom-gym): real HDDL->A2A->OCEL ingest e2e capture (Step 5)

## Changes

- Added `test/ash_a2a_freedom_gym_ocel_conformance_e2e_test.exs` (170 lines) —
  the real e2e test: drives `FacilitatorAgent :next_phase` for 3 reference
  meetings + 1 deviant meeting, POSTs each returned phase as an OCEL v2 event
  to beam4pm's live `BeamPM.OcelIngest.Router`, and writes the accepted-event
  echoes to `../beam4pm/qualification/gym_bridge/{reference,deviant}_ocel_events.json`.
- Added `test/ash_a2a_freedom_gym_llm_test.exs` (55 lines).
- Added `test/ash_a2a_freedom_gym_zai_test.exs` (85 lines).
- Added `test/support/freedom_gym_llm_fixture.ex` (185 lines) — shared test
  support fixture for FreedomGym LLM-backed tests.
- Modified `test/test_helper.exs` (+1/-1 line).
- Test tagged `:external_api` (excluded by default, matching the existing
  LLM-backed FreedomGym test convention) since it requires a real
  out-of-process beam4pm server reachable at `OCEL_INGEST_URL`.

Total: 5 files changed, 496 insertions(+), 1 deletion(-).

## Verification

Per the commit message:

- Targeted run: `mix test test/ash_a2a_freedom_gym_ocel_conformance_e2e_test.exs --include external_api` — 1 test, 0 failures.
- Full suite: `mix test` — 21 doctests, 3 properties, 96 tests, 0 failures (3 excluded), 0 regressions vs pre-merge baseline (94 tests, 2 excluded).

## Related

None stated (no PR number or branch name mentioned in the commit subject or message).
