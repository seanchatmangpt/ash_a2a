# R-04 WebCrypto ↔ SessionActor channel-bind

Standing: **ALIVE** (court EXIT 0; not Foundry; not zero-HITL)

Subject: Chromium ECDSA P-256 `extractable:false` → IndexedDB → refuse export →
`AshA2A.Session.Statem` verifies Wi-Fi↔cellular reconnect with zero cookie/token.

## Claim boundary

| Surface | Status |
|---|---|
| `AshA2A.Session.Statem` lifecycle (SESS) | Pre-existing; ≠ R-04 bind |
| WebCrypto non-extractable P-256 + IndexedDB | Proven in Chromium via CDP |
| Export refusal (`InvalidAccessError`) | Proven |
| SessionActor channel-bind / reconnect verify | `bind_channel/2`, `verify_reconnect/2` |
| Cookie / token ambient credentials | Typed refuse (`:cookie_refused` / `:token_refused`) |
| Production WebAuthn / passkeys | **Not claimed** |

## Court

```bash
. scripts/env.sh   # or A2A_PREFIX=$HOME/opt . scripts/env.sh
MIX_ENV=test mix test test/ash_a2a/session/r04_webcrypto_channel_bind_court_test.exs --only serial_solo
```

Observed (this lane):

```text
Result: 2 passed
EXIT 0
```

Host: `test/support/hosts/r04_webcrypto_channel_bind.mjs` (real Google Chrome + CDP).
Actor: `lib/ash_a2a/session/statem.ex` + `lib/ash_a2a/session/channel_bind.ex`.

## Falsifiers

- Chrome absent → court `flunk("BLOCKED: ...")` (no silent skip).
- `extractable != false` or export succeeds → fail.
- Cookie/token accepted on reconnect → fail.
- Signature verify against OTP ECDSA fails after IndexedDB reload → fail.
