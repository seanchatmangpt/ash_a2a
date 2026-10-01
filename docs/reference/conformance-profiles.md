# Conformance profiles and the strict C1 run

`mix ash_a2a.verify_conformance --profile c0|c1|c2|c3` computes a claim from
real probes (see `conformance-claim.md`). C1 requires three checks that depend
on the build's security profile and its durable stores:

| check | passes when |
|---|---|
| `c1.security_profile_strict` | `AshA2A.SecurityProfile.current() == :strict` |
| `c1.durable_claim_store` | `:claim_store` is a module exporting `durable?/0 == true`, `claim/2`, `complete/2`, not Memory/ETS |
| `c1.keyed_journal` | `:receipt_outbox_dir` is non-tmp and writable, and the HMAC key provider MACs, verifies and rejects a tampered payload |

None of these is weakened for the run: each fails on weak configuration
(`test/ash_a2a/durable_conformance/strict_c1_checks_test.exs` flips every
input and asserts the check fails).

## Real configuration that passes

| concern | module | config |
|---|---|---|
| durable claim store | `AshA2A.ConsequenceKernel.EffectClaimStore.DurableFile` | `claim_store`, `claim_store_dir` |
| keyed prepared journal | `AshA2A.ConsequenceKernel.PreparedEffectStore.Journal` | `prepared_journal_dir` (default `<receipt_outbox_dir>/prepared_journal`), key = `receipt_outbox_key` |
| keyed receipt outbox | `AshA2A.ReceiptOutbox` | `receipt_outbox_dir`, `receipt_outbox_key` |

`DurableFile` is process-free: compare-and-set claim files (temp file, fsync,
rename), a `fence` high-water mark updated under the same directory lock as
the claim write, and a SHA-256 over every record. State is the filesystem, so
a BEAM restart loses nothing (proved in
`test/ash_a2a/durable_claim_store/durable_file_test.exs` with a second BEAM).

`Journal` is an append-only log where entry `n` is HMAC'd together with entry
`n-1`'s tag and the sequence number `n`, plus a MAC'd `head`. Edits, swaps,
gaps and truncation are refused. The key is mandatory (>= 32 bytes) and a
tmp directory is refused.

## Where the profile comes from

The profile is a build constant (`Application.compile_env/3`), never an option,
request field or call-time env lookup.

| build env | profile | config file |
|---|---|---|
| `test` | `:dev_bypass` | `config/config.exs` |
| `dev` | `:dev_bypass` | `config/dev.exs` |
| `prod` | `:strict` | `config/prod.exs` |
| `conformance` | `:strict` | `config/conformance.exs` |

`config/runtime.exs` applies to `:prod` and `:conformance` alike: it requires
`ASH_A2A_DATA_DIR` and `ASH_A2A_OUTBOX_KEY_B64` (>= 32 bytes decoded), and
wires the outbox, prepared journal, durable claim store, EKV receipt store and
broker, `capability_release_mode: :strict` and the kill switch.

## Boot enforcement

`AshA2A.Application.start/2` calls `AshA2A.SecurityProfile.Boot.run!/0` before
any child starts. Under `:strict` it refuses (typed
`AshA2A.Authority.SecurityPreflight.Error`): missing or weak (< 32 byte) key,
tmp outbox dir, in-memory receipt store, missing or non-durable claim store,
tmp claim store dir, legacy capability release mode, missing broker or kill
switch class, the transport-verified authority policy. It then runs
`SecurityPreflight.check!(force: true)` and `ReceiptStore.boot_check/0`.

## Running C1 under `:strict`

```sh
export MIX_ENV=conformance
export ASH_A2A_DATA_DIR=/var/lib/ash_a2a                 # durable, not tmp
export ASH_A2A_OUTBOX_KEY_B64="$(head -c 48 /dev/urandom | base64)"
mix ash_a2a.verify_conformance --profile c1 --json receipts/conf-c1.json
```

The first run compiles the `conformance` build environment. The task loads
config (`app.config`) without starting the application, so the report is
produced even when boot preflight would refuse. Under `test`/`dev` the same
command reports `c1.security_profile_strict` as FAIL by design. The subprocess
court is opt-in: `ASH_A2A_STRICT_CONFORMANCE_COURT=1 mix test
test/ash_a2a/durable_conformance`.

## See Also

`conformance-claim.md` · `c2-certificate.md` · `c2-wire-interop.md`
