# c2-certificate

The C2 actuation certificate has one canonical model, `AshA2A.C2.Certificate`. It is the
control-plane wire form, the input of `AshA2A.C2.CertificateVerifier`, and convertible without
loss to the actuator's certificate JSON and to the authority service's reply. Last updated
2026-09-29 (v26.9.28 merge of the control-plane externalization with the crypto standing work).

## Contents

- Struct
- Signed message
- Time representation decision
- Conversions
- Verification identity in the actuator profile
- Complete mediation
- See also

## Struct

Field names follow the merged control-plane wire (`AshA2A.C2.Wire`):

| field | type | in signed message |
|---|---|---|
| `version` | pos integer | `v` |
| `effect_digest` | `sha256:<hex>` | yes |
| `principal` | string | yes |
| `policy_epoch`, `revocation_epoch`, `generation` | non-negative integers | yes |
| `nonce` | string; fall-back for a signature entry without its own | yes (per signature) |
| `not_before_ms`, `expires_at_ms` | integer milliseconds | `not_before`, `expires` (seconds) |
| `audience` | string | yes |
| `threshold` | pos integer (quorum the certificate claims; the actuator's pinned quorum decides) | no |
| `signatures` | list of `%{signer, kid, alg, nonce, signature}`, `signature` raw bytes | one message per entry |
| `alg`, `kid` | optional certificate-level fall-backs for an entry that omits them | yes (via entry) |

## Signed message

Unchanged from `Sa2aCrypto.SignedMessage` (RFC-SA2A-007 E-E):
`"SA2A-C2-APPROVAL-v1" <> <<0>> <> JCS({v, alg, kid, effect_digest, principal, policy_epoch,
revocation_epoch, generation, nonce, not_before, expires, audience})`. The verifier rebuilds the
bytes from the effect identity, the certificate and the context, never from a signature body.
The signed message, `Sa2aCrypto`, `authority_service/` and `actuator/` were not modified for the
model merge.

## Time representation decision

- The struct holds integer **milliseconds** because the merged control-plane code and tests use
  `not_before_ms` / `expires_at_ms`.
- The signed message binds integer unix **seconds**. This is what all three deployed projects
  implement (`SignedMessage` typed check `is_integer`, the actuator certificate JSON, the
  authority `mint`). No RFC 3339 string form exists in code; the RFC-007 text is read as
  "UTC instants", carried as unix seconds. Switching the signed message to RFC 3339 strings would
  change every signature in three projects and is not done.
- Conversion is explicit (`Certificate.to_seconds/1`, `from_seconds/1`, `window_seconds/1`):
  ms to s is accepted only for whole seconds and otherwise returns `{:error, :sub_second_time}`;
  the verifier then yields `{:invalid, :malformed_certificate}` rather than truncating a
  validity bound. Tests: `test/ash_a2a/crypto_standing/certificate_verifier_test.exs`,
  `test/ash_a2a/c2/certificate_model_test.exs`.

## Conversions

- `AshA2A.C2.Wire.certificate/1` and `decode_certificate/1`: control-plane JSON (HTTP remote
  clients). Raw signature bytes are base64url on the wire; an entry with no `signature` bytes
  (opaque external evidence) passes through untouched.
- `AshA2A.C2.ActuatorProfile.certificate_json/1`: actuator JSON (exact key set, seconds,
  per-signature `kid`/`alg`/`nonce`, no keys or standing claims).
- `AshA2A.C2.ActuatorProfile.certificate_from_authority/1`: authority reply
  `{"envelope", "message"}` to the struct (`threshold: 1`, one signature); envelope and message
  must agree on digest, kid, alg, nonce.

## Verification identity in the actuator profile

Certificates for actuator-profile effects bind the actuator digest (SHA-256 over the actuator's
canonical effect bytes), not `PreparedEffect.digest`. `CertificateVerifier` therefore takes the
identity `%{digest: actuator_digest, principal: principal}` (`ActuatorProfile.effect/2` computes
it). See `c2-wire-interop.md`.

## Complete mediation

`AshA2A.C2.CompleteMediation.admit/3` runs before any signature is checked. Beyond the
digest/principal binding and the policy epoch, revocation epoch and generation checks it refuses
(`{:error, :refused}`) a certificate whose `audience` differs from `ctx.audience`, whose
`[not_before_ms, expires_at_ms)` window does not contain the current time, or whose `nonce` is
shorter than 16 bytes. The clock is `ctx.now_ms` (milliseconds) when present, else `ctx.now`
(unix seconds, the value passed to Sa2aCrypto), else the system clock. Signature verification
itself stays in `CertificateVerifier` through `AshA2A.CryptoStanding`; the c2c3 branch's
algorithm-atom `CryptoVerifier` provider hook was not adopted because it would bypass that path.

## See also

- `docs/reference/c2-wire-interop.md`
- `docs/reference/c2-compromise-court.md`
- `sa2a_crypto/lib/sa2a_crypto/signed_message.ex`
