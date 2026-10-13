# STANDING-RECEIPT — ash_a2a (v26.10.8 wave)

- **Subject**: `b40abf82c7e2da1360f52ca072fbc71e74d0490b` (main)
- **Standing**: PARTIAL-ALIVE
- **Minted**: 2026-10-09 (lane R93)

## Denominator law

Counts and figures in this receipt were re-read from the receipt/report at use
time, per [[no-overclaiming-conversational]] ("Receipt-cited counts are re-read
from the receipt at use time"). The 26/26 figure is from a re-run executed this
session at the exact subject; the TCK 79.0% figure is bound to `cadb6534` (an
ancestor), not to this subject — it is cited as-of-date, not re-witnessed here.

## Drift disclosure vs older subjects

- The prior coordinator figure "26/26 PASS @ `a9cc903b`" was not witnessed
  in-repo; this receipt re-witnesses it at `b40abf82` instead (same totals:
  26 PASS / 0 FAIL).
- The doc's earlier "73.6% MUST" figure binds to `2379635c` and is superseded
  at `cadb6534` by 79.0%. Receipts citing 73.6% as current are stale.
- If R30-r lands a certify receipt at or after `b40abf82`, this receipt should
  be re-minted (standing may rise to CERTIFIED); a certify ACCEPTED at a
  descendant subject does not certify this subject by itself.

## Falsifiers

- `totals.fail != 0` on a fresh `mix ash_a2a.v1_conformance_report` at HEAD
  falsifies the 26/26 claim.
- A doc-hdit certify receipt at `b40abf82` with verdict ACCEPTED falsifies the
  PARTIAL-ALIVE choice (upgrade to CERTIFIED).
## Verification

Canonical form: sections sorted by header, per-line trailing whitespace
stripped, LF endings, single trailing newline. The attestation is stored at
`STANDING-RECEIPT.attestation.json` next to this file.

```sh
cd /Users/sac/graphlaw
cargo build --bin graphlaw-attest
SEED=$(python3 -c "import hashlib; print(hashlib.sha256(b'graphlaw-attest:STANDING-RECEIPT:ash_a2a:v26.10.8').hexdigest()[:64])")
PUBKEY=$(./target/debug/graphlaw-attest pubkey --key-seed-hex "$SEED")
./target/debug/graphlaw-attest verify \
  --in /Users/sac/ash_a2a/docs/sjira/v26.10.8/STANDING-RECEIPT.md \
  --attestation /Users/sac/ash_a2a/docs/sjira/v26.10.8/STANDING-RECEIPT.attestation.json \
  --trusted-key d3fcc7395405739f76d7570e0804e79d6a1e4e60b42b1b93642bf033e62d239b
# expected: VERIFIED (exit 0); any byte changed in this file: REFUSED (exit 1)
```
## Why not CERTIFIED

doc-hdit certify is mid-flight and has not landed a receipt at this subject.
All other witnessed evidence is green at or ancestor-of the subject, so the
subject is PARTIAL-ALIVE, not FAIL-HONEST.

## Witnessed evidence at or ancestor-of subject

| Evidence | Subject | Witness | Result |
|---|---|---|---|
| v1.0 conformance courts | `b40abf82` (subject itself) | `mix ash_a2a.v1_conformance_report` re-run 2026-10-09T18:45:51Z, report `/tmp/r93-conformance.json` | **26/26 PASS, 0 FAIL** (26 courts selected of 26) |
| Official A2A TCK compatibility | `cadb6534` (ancestor, verified) | `docs/reference/a2a-v1-conformance.md` final-verdict section | **79.0% overall** (235 passed / 30 skipped / 0 FAIL; MUST 87/87, SHOULD 7/7, MAY 4/4) |
| Earlier TCK run | `2379635c` (ancestor) | same doc, earlier-run section | 73.6% overall, MUST 73.6% (92 PASS / 7 FAIL / 4 SKIPPED / 26 NOT TESTED) — superseded by the `cadb6534` verdict |
| Inner conformance machine report | `059ff0e3` (ancestor) | same doc | 25 PASS / 0 FAIL (25 courts); gate `totals.fail == 0` |
| doc-hdit certify | — | **not witnessed** | R30-r rollout mid-flight at mint time (rollout PID 74217, certify PID 8919 running against this checkout); no certify receipt landed at `b40abf82` |
