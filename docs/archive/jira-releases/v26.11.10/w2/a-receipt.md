# Lane a-receipt Receipt

Standing: PARTIAL_ALIVE

## Subject / files
- lib/ash_a2a/receipt_outbox.ex (deterministic encode; tmp-default warning)
- lib/ash_a2a/receipt/evidence_chain.ex, consequence_kernel/closure/receipt_digest.ex,
  replan/replay_key.ex, authority.ex (grant_token_id site), evidence/class.ex (digest):
  `term_to_binary(..., [:deterministic])`; decode unchanged (back-compat).
- lib/ash_a2a/consequence_kernel/prepared_effect_store/journal.ex (warning when no dir outside dev/test)
- test/receipt_digest_determinism_test.exs (new; 200-key map digest order independence)
- receipt_store.ex: no change needed.

## Commands + exits
- `MIX_ENV=test MIX_BUILD_ROOT=_build-w2-a-receipt mix test test/receipt_digest_determinism_test.exs
  test/ash_a2a/receipt_store test/ash_a2a/prepared_effect_test.exs test/ash_a2a/durable_prepared_journal
  test/ash_a2a/consequence_kernel test/ash_a2a/c1_w3_hardening
  test/untested_lane18/consequence_kernel_codec_test.exs` -> 79 tests, 0 failures (19 excluded by tags).
  Exit code not captured (PIPESTATUS empty under tool shell); outcome read from ExUnit summary.
- Build dir removed with rm -rf.

## Disclosures
- First compile hit lib/ash_a2a/verify.ex `undefined variable "gate"` (a-authority's in-flight file);
  I did not touch it; it compiled on retry.
- Journal 32-byte key floor: already enforced by KeyCustody.HmacSha256 (>= 32) via Journal.open
  probe -> NO_CHANGE_NEEDED. Outbox integrity_key still accepts any non-empty key (no floor added).
- The new determinism test would also pass without the change for small maps only if order matches;
  not shim-court verified (UNVERIFIED non-vacuity).

## Not done
- No outbox key >=32 floor (could break existing tests/configs; design decision).
- No test for the two new warnings; no mutation proof of the determinism test.
