# SA2A finish wave — 2026-11-19

Standing: PARTIAL (C1 CONFORMANT; C2/C3 code PASS, supply operator-blocked)

Subject: branch `cursor/finish-semantic-a2a-bde4`. Machine reports under
`receipts/conf-c{1,2,3}.json` bind the exact subject SHA they name.

## What this wave closed

1. **Machine Diátaxis edges** — `semantic/sa2a-diataxis.ttl` types each export
   as `sa2a:Capability` and binds all seven CapabilityShape edges
   (`learnedBy` / `executedBy` / `specifiedBy` / `constrainedBy` /
   `verifiedBy` / `repairedBy` / `evidencedBy`) for
   discover/select/construct/do/receipt/replay. Closure query matches
   engineering-standards `closure.rq`. Court:
   `test/ash_a2a/sa2a_diataxis_closure_test.exs`.
2. **Honest how-tos + thin-waist tutorial** for select / construct / replay /
   discover-repair, plus `docs/tutorials/walk-the-sa2a-thin-waist.md`.
3. **Receipts verify** — `receipts/pplan-courts-20261118.md` is
   `Standing: UNVERIFIED` (no false PASS).
4. **Hex package files** — ExDoc extras shipped in `mix.exs` `files:`.
5. **CHANGELOG Unverified rows** — tenant / `:rest_for_one` /
   `authorize?: true` cite courts.
6. **C1 claim (executed)** — see below.
7. **C2/C3 code probes (executed)** — all PASS including
   `c2.release_distribution_none` after building sibling releases and
   `c3.signer_set_quorum` with real Ed25519 custodian-distinct quorum.

## Verifier claim (C1)

```text
SA2A v26.9.29 conforms to profile C1 at independence tier I1,
hosting scope same-host-os-user, on subject SHA <see receipts/conf-c1.json>
```

Re-run:

```bash
export MIX_ENV=conformance
export ASH_A2A_DATA_DIR=$HOME/ash_a2a_data   # not under /tmp
export ASH_A2A_OUTBOX_KEY_B64="$(head -c 48 /dev/urandom | base64)"
mix ash_a2a.verify_conformance --profile c1 --json receipts/conf-c1.json
```

## Still open (operator / external)

| Item | Why |
|---|---|
| C2/C3 CONFORMANT claim | `supply.signed_tag` FAIL (no annotated signed tag at HEAD); `supply.protected_main` UNVERIFIED (GH 403 on this token) |
| C3 tier I2 claim | Secure Enclave custody evidence (Mac + iPhone) + policy key; pass `--tier I2` only with that evidence |
| Hex publish | `HEX_API_KEY` + owner version decision |
| Issue #79 close | Diátaxis + C1 DoD rows closed; full DoD still wants C2/C3 supply + I2 evidence |

## Falsifiers

- Diátaxis closure test failing, or any `sa2a:path` target missing.
- C1 NOT CONFORMANT on a clean tree with the documented conformance env.
- `mix ash_a2a.receipts.verify` exiting non-zero on non-legacy findings.
- Any C2/C3 code check flipping from PASS without a matching receipt.
