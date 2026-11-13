# Standing Receipt Notes (v26.10.8)

Standing: PARTIAL_ALIVE

Sidecar to `STANDING-RECEIPT.md`, whose bytes are attested by
`STANDING-RECEIPT.attestation.json` and must not change. The corrections below were
authored by the lane-16 receipt hygiene pass and kept out of the attested file.

- The attested file spells its standing `PARTIAL-ALIVE` (hyphen); the closed vocabulary
  value is `PARTIAL_ALIVE`.
- It is also missing the Standing line directly after the H1.

## Lane-16 reconciliation note (verbatim diff)

```diff
diff --git a/docs/sjira/v26.10.8/STANDING-RECEIPT.md b/docs/sjira/v26.10.8/STANDING-RECEIPT.md
index 3c1947dc..df58ff95 100644
--- a/docs/sjira/v26.10.8/STANDING-RECEIPT.md
+++ b/docs/sjira/v26.10.8/STANDING-RECEIPT.md
@@ -1,7 +1,8 @@
 # STANDING-RECEIPT — ash_a2a (v26.10.8 wave)
 
+Standing: PARTIAL_ALIVE
+
 - **Subject**: `b40abf82c7e2da1360f52ca072fbc71e74d0490b` (main)
-- **Standing**: PARTIAL-ALIVE
 - **Minted**: 2026-10-09 (lane R93)
 
 ## Denominator law
@@ -61,3 +62,21 @@ subject is PARTIAL-ALIVE, not FAIL-HONEST.
 | Earlier TCK run | `2379635c` (ancestor) | same doc, earlier-run section | 73.6% overall, MUST 73.6% (92 PASS / 7 FAIL / 4 SKIPPED / 26 NOT TESTED) — superseded by the `cadb6534` verdict |
 | Inner conformance machine report | `059ff0e3` (ancestor) | same doc | 25 PASS / 0 FAIL (25 courts); gate `totals.fail == 0` |
 | doc-hdit certify | — | **not witnessed** | R30-r rollout mid-flight at mint time (rollout PID 74217, certify PID 8919 running against this checkout); no certify receipt landed at `b40abf82` |
+
+## Reconciliation note (lane L16, 2026-11-11)
+
+`candidates.jsonl` carries standing UNKNOWN; `WORKGRAPH.ttl` carries `sj:standing "ALIVE"`
+for G3-SelfCard and G4-ReleaseBump. Not promoted. The WORKGRAPH ALIVE lines cite landed
+commits only, with no command+exit evidence. Evidence re-derived now:
+
+- G3-SelfCard: `git show --stat 7d646598` shows `lib/mix/tasks/ash_a2a.self_card.ex`
+  (+147) and `priv/sa2a/self-agent-card.json` (+61). Commit existence only; the self_card
+  court test was not run.
+- G4-ReleaseBump: `mix.exs:29` reads `version: "26.10.9"` at the current tree, not 26.10.8
+  (later bump); the a9cc903b bump is not re-observable from HEAD.
+- Narrowest relevant re-run: `MIX_ENV=test MIX_BUILD_ROOT=_build-lane16 mix test
+  test/ash_a2a_v1_proto_fidelity_test.exs` exit 0, 11 tests, 0 failures (dirty tree, no SHA).
+  It does not cover self_card.
+- `/tmp/r93-conformance.json` (cited above) is a non-reproducible witness: a /tmp path, not
+  tracked, not replayable from the repo.
+
```
