# Approver Apps

The native approver (`sa2a-approver/`) is the independent renderer required by RFC-SA2A-007
E-I (WYSIWYS): it receives the canonical PreparedEffect bytes and the signed-message bytes,
recomputes `effect_digest` locally, renders a summary from those bytes only, and asks a
biometric-gated P-256 key to sign. Touch ID (macOS) and Face ID (iOS) use the same core.

Last Updated: 2026-09-28 (v26.9.28 kernel). Status: software path ALIVE (build + tests);
Secure Enclave path UNVERIFIED (needs biometrics and a signed app bundle).

## Layout

- `SA2AApproverCore`: strict integer-only JSON parser, JCS serializer, message parser,
  WYSIWYS digest and summary, `ApprovalSigner` protocol, `SecureEnclaveSigner`,
  `SoftwareP256Signer` (CI only), strict-DER check and verifier.
- `sa2a-approver` CLI, `SA2AApproverMac` (SwiftUI app), `SA2AApproverUI` (shared view),
  `iOS/SA2AApproverIOSApp.swift` (source for an Xcode iOS app target).
- Nothing under `sa2a-approver/` is referenced by `mix.exs`; the Elixir build is unaffected.

## Signed message (contract)

```text
"SA2A-C2-APPROVAL-v1" || 0x00 || JCS({alg, audience, effect_digest, expires, generation,
  kid, nonce, not_before, policy_epoch, principal, revocation_epoch, v})
```

Integers: `v`, `policy_epoch`, `revocation_epoch`, `generation`, `not_before`, `expires`
(unix seconds). Strings: the rest. `effect_digest` is `sha256:<64 hex>` of the canonical
effect bytes. `kid` is `base64url(sha256(SPKI DER)[0..16 bytes])`, unpadded (22 chars).
The approver refuses: unknown or missing fields, floats, duplicate keys, non-canonical
bytes, input over 64 KiB, `alg` other than `ES256`, `kid` not matching its key, TTL over
300 s, expired or not-yet-valid windows (5 s skew), and any effect whose recomputed digest
differs.

## Commands

```bash
cd sa2a-approver
swift build && swift test
# Sign (enclave key is created on first use; prompts for biometrics):
swift run sa2a-approver sign --message msg.bin --effect effect.json --key enclave --out sig.der
swift run sa2a-approver pubkey --key enclave --out spki.der   # register this SPKI + kid
# CI / fixtures only (refused unless SA2A_APPROVER_DEV=1):
SA2A_APPROVER_DEV=1 swift run sa2a-approver fixtures --out ../test/support/approver_fixtures
elixir scripts/gen_elixir_fixture.exs Tests/SA2AApproverCoreTests/Fixtures/elixir
```

Cross-runtime courts: `mix test test/ash_a2a/approver_fixture_test.exs` verifies the
Swift-signed fixtures with plain `:crypto`; `swift test` verifies the Elixir-signed fixture.

## Operator prerequisites

1. iOS target: an iPhone attached by cable, developer mode on, and an Apple ID (or team)
   signing identity selected in Xcode. `security find-identity -v -p codesigning` reported
   0 identities on this Mac at last check, so no signed bundle can be built yet.
2. Secure Enclave keys need a keychain access group: sign the app with the
   `keychain-access-groups` entitlement (`$(AppIdentifierPrefix)com.example.sa2a-approver`)
   and an `NSFaceIDUsageDescription` Info.plist key on iOS. An unsigned `swift run` binary
   may be refused by the keychain (`errSecMissingEntitlement`); use the app bundle.
3. The device must have a passcode set (key class `WhenPasscodeSetThisDeviceOnly`), and
   biometrics enrolled: `.biometryCurrentSet` invalidates the key when enrollment changes.
4. Register each device's `kid`, SPKI, and custodian in the KeyRegistry; the two human
   devices are tier I2 (device custody) unless different persons hold them.

## Key ceremony record (template)

```text
ceremony_id:        <date>-<seq>
operator / witness: <names>
device:             <model, serial, OS version>
custodian_id:       <id>        custody_tier: I2
kid:                <22 chars>  spki_sha256: <hex>
created_at (UTC):   <ts>        biometry: Touch ID | Face ID (enrolled: yes)
registered in KeyRegistry at revocation_epoch: <n>   state: active
known-answer vector signed and verified by AshA2A: <yes/no, receipt id>
signatures: operator ____  witness ____
```

## Lost-device recovery

1. Immediately mark the device's `kid` `compromised` (or `suspended` if recovery is likely)
   in the KeyRegistry, which bumps `revocation_epoch`; outstanding approvals for that kid
   die at the next verifier check.
2. Enroll a replacement device with a new ceremony record and a new `kid`.
3. Re-issue any pending approvals under the new kid; never reuse a nonce.
4. Enclave keys are non-exportable, so there is no key backup; recovery is always
   re-enrollment. Record the incident against the old ceremony record.

## See Also

- `docs/rfc/RFC-SA2A-007-errata-v26.9.28.md` (E-E signed message, E-I WYSIWYS, E-K TTL)
- `docs/assurance/sa2a-assurance-case-v26.9.28.md`
- `docs/jira/v26.9.28-kernel/_LANES_V3.md`
