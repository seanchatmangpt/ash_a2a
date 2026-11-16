# Verify receipts

Status: verified (2026-11-16, Elixir 1.20.4 / OTP 29.1.1): `mix test test/ash_a2a/receipts/verifier_test.exs`, 9 passed; `mix ash_a2a.receipts.verify` ran over this repository's receipts and exited 1 with three `verified_without_run_log` findings.

`mix ash_a2a.receipts.verify` checks Markdown receipts against the files they cite. It is read-only and exits non-zero when any finding has error severity.

```
mix ash_a2a.receipts.verify                      # receipts/**/*.md and docs/archive/jira-releases/*/RECEIPT.md
mix ash_a2a.receipts.verify path/to/receipt.md --root . --git
```

## Receipt conventions it reads

| Convention | Meaning |
|---|---|
| `Standing: WORD` | Claimed standing. ALIVE, VERIFIED, CONFORMANT and PASS count as verified. |
| `Run log: path` | Attached evidence. The file must exist. |
| `` `path` sha256:<64 hex> `` | Hash claim, checked against the file. |
| `Commit: <hex>` | Must be 7 to 40 hex; with `--git`, must exist in the repo. |
| `` `test/..._test.exs` `` | Cited test file must exist. |
| Table row carrying a conformance label | Refused if the row, or a cited `.md` doc with `Status:`/`Standing:`, says UNVERIFIED. |

## Findings

Errors: `hash_mismatch`, `hash_file_missing`, `commit_malformed`, `commit_unknown`, `test_missing`, `run_log_missing`, `verified_without_run_log`, `conformant_on_unverified`, `receipt_unreadable`. Warnings: `standing_missing`, `unverified_with_run_log`.

## Limits

Existing archived receipts predate these conventions and mostly cite no hashes or `Run log:` lines, so a verified standing in them will be reported as `verified_without_run_log`. That is the honest result, not a bug. The verifier checks consistency of the receipt's own claims; it does not re-run tests or prove the logs are genuine.
