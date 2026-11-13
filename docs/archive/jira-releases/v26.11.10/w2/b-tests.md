# Lane b-tests Receipt

Standing: PARTIAL_ALIVE

## Subject / files

- NEW test/beam4pm_a2a_router_http_test.exs (card vs domain count, message/send round trip on
  public skill -> TASK_STATE_COMPLETED, unknown path 404) via real BeamPM.A2ARouter + Plug.Test.
- test/beam4pm_dfcm_sa2a_validate_card_test.exs: dropped 1194/protocolVersion-absent
  assumptions; asserts fixture matches the live router card (name, interfaces, skill count).
- qualification/fixtures/a2a/agent-card.json: regenerated from live router (1346 skills).
- qualification/sa2a_e2e_qualification.exs: stale "consuming hex ash_a2a" comment fixed.

## Commands + exits

- `MIX_ENV=test MIX_BUILD_ROOT=.../_build-w2-b-tests mix test
  test/beam4pm_a2a_router_http_test.exs test/beam4pm_dfcm_sa2a_validate_card_test.exs`
  -> 7 tests, 0 failures (observed).
- Earlier attempts failed on other lanes' in-flight edits (ash_a2a verify.ex undefined `gate`;
  transient deps lock mismatch; b-app router Mount defined after use). Each cleared on retry.
- _build-w2-b-tests removed (rm -rf succeeded).

## Disclosures

- New test file needs coordinator admission (UNADMITTED authorship).
- Fixture card advertises `url: http://localhost:4000` (not the router base_url): possible
  ash_a2a/b-app finding, not asserted.
- Test depends on b-app's router (Mount) landing; passes against the tree as of 13:44.
- No git state commands run; no mix.lock edits by this lane.

## Not done

- .github/workflows/beam4pm-ci.yml sibling ash_a2a checkout / ASH_A2A_PATH: file is GENERATED
  by ggen (first line "GENERATED"), not hand-edited; needs gha:Step facts in the ontology.
