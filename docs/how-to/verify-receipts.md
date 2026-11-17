# Verify receipts

Status: verified (2026-11-17): `mix test test/ash_a2a/receipts/verifier_test.exs` and `mix ash_a2a.receipts.verify` (exit 0, three `legacy_exempt` warnings).

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

Errors: `hash_mismatch`, `hash_file_missing`, `commit_malformed`, `commit_unknown`, `test_missing`, `run_log_missing`, `verified_without_run_log`, `conformant_on_unverified`, `receipt_unreadable`. Warnings: `standing_missing`, `unverified_with_run_log`, `legacy_exempt`.

## Legacy allowlist

Three archived receipts predate the `Run log:` convention. They are listed in `receipts/legacy-receipts.json` (override with `--legacy`). Each entry has the receipt `path` (relative to the root), its `sha256`, the exempted `code` (only `verified_without_run_log` today) and a `reason`. A receipt whose current hash matches is reported as `warning legacy_exempt` with its reason, so it stays visible; the run exits 0 only when every non-legacy receipt passes. Editing a legacy receipt changes its hash, so it is checked normally again. Do not add new receipts to the list: attach a run log instead, and review any change to the file.

## Limits

Archived receipts that are not in the allowlist and cite no `Run log:` are reported as `verified_without_run_log`. The verifier checks consistency of the receipt's own claims; it does not re-run tests or prove the logs are genuine.
