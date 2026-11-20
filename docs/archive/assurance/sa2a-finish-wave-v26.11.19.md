# SA2A finish wave — 2026-11-19

Standing: PARTIAL

Subject: branch `cursor/finish-semantic-a2a-bde4` on top of main
`3f7aac592538886e7282e2257108200a29884911` (exact SHA after this wave's
commit is recorded in the PR / C1 JSON receipt).

## What this wave closed

1. **Machine Diátaxis edges** — `semantic/sa2a-diataxis.ttl` now binds
   `specifiedBy` / `executedBy` / `verifiedBy` / `repairedBy` for all six
   exported capabilities. Court:
   `test/ash_a2a/sa2a_diataxis_closure_test.exs`.
2. **Honest how-tos** for select / construct / replay / discover-repair.
3. **Receipts verify** — `receipts/pplan-courts-20261118.md` no longer
   claims PASS without a run log (`Standing: UNVERIFIED`).
4. **Hex package files** — ExDoc extras that were linked but not shipped
   (`CONTRIBUTING.md`, three explanation pages) added to `mix.exs` `files:`.
5. **CHANGELOG Unverified rows** — tenant / `:rest_for_one` /
   `authorize?: true` now cite courts.

## C1 probe (clean-tree requirement)

Under `MIX_ENV=conformance` with durable `ASH_A2A_DATA_DIR` (not under tmp)
and `ASH_A2A_OUTBOX_KEY_B64` (≥32 decoded bytes), every C0/C1 check except
`c0.subject_identity` passed on the dirty pre-commit tree. After this
commit lands on a clean checkout, re-run:

```bash
export MIX_ENV=conformance
export ASH_A2A_DATA_DIR=$HOME/ash_a2a_data
export ASH_A2A_OUTBOX_KEY_B64="$(head -c 48 /dev/urandom | base64)"
mix ash_a2a.verify_conformance --profile c1 --json receipts/conf-c1.json
```

Expected: CONFORMANT to C1 at I1 / same-host-os-user.

## Still open (operator / external)

| Item | Why |
|---|---|
| C2 `release_distribution_none` | Needs built `authority_service` + `actuator` releases |
| C2/C3 supply (`--github`) | Signed annotated tag at HEAD; branch-protection token |
| C3 tier I2 claim | Secure Enclave custody evidence (Mac + iPhone) + policy key |
| Hex publish | `HEX_API_KEY` + owner version decision |
| Issue #79 close | After C1 green on clean subject + Diátaxis edges (this wave); remaining DoD rows need C2/C3 evidence |

## Falsifiers

- Diátaxis closure test failing, or any `sa2a:path` target missing.
- C1 NOT CONFORMANT on a clean tree with the documented conformance env.
- `mix ash_a2a.receipts.verify` exiting non-zero on non-legacy findings.
