# Manufacturing Receipt — ash_a2a v26.10.8

**Subject**: `/Users/sac/ash_a2a` branch `feat/tck-vuln-hardening` @ `a9cc903b`
(v26.10.8 bump commit; 67 ahead of `main` at receipt time). Minimal campaign
dir mirroring `docs/jira/v26.10.4/` (RECEIPT.md only, by coordinator
instruction).

## Gate verdicts (executed this receipt-cycle, 2026-10-08)

| Gate | Verdict | Evidence |
|---|---|---|
| w608 court test (`test/ash_a2a/w608_map_update_court_test.exs`) | **GREEN — 2 passed, 0 failures** (exit 0) | `MIX_ENV=test MIX_BUILD_ROOT=_build-lanea2aland mix test test/ash_a2a/w608_map_update_court_test.exs`; landed `b0af954c` |
| `mix ash_a2a.v1_conformance_report` at post-bump HEAD `a9cc903b` | **26/26 PASS, 0 FAIL** (`totals: {total: 26, pass: 26, fail: 0}`, task exit 0) | same env as above, 2026-10-08T10:01:27Z |
| Version-line consistency | **GREEN** — mix.exs `version: "26.10.8"` (mix.exs:29) agrees with the spec-version mapping doc's admitted version line (docs/reference/a2a-spec-version-mapping.md:9) | this bump commit, both files in one commit so the W618/W628b miss class cannot recur |

## Changes this cycle

| Commit | Content |
|---|---|
| `b0af954c` | test(w608): land the untracked OS-20 map-update court (residue of the b588c55c wave); naming already matched the post-636b7940 `*_court_test.exs` convention |
| `a9cc903b` | chore(release): bump 26.10.7 -> 26.10.8 with the W628b companion (mapping-doc Version line) folded into the same commit; no CHANGELOG entry — matches recent-bump convention (26.10.6/26.10.7 added none) |

## Standing

Not pushed, not tagged, not merged — coordinator owns those transitions.
Build root `_build-lanea2aland` is lane-local and left in place per the
lane-lease law (`.gitignore` covers `_build*`, f56c06d0).
