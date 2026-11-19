# sa2a-approver

Native human approver for the SA2A authority service (WYSIWYS: the approver recomputes the effect
digest, renders a summary from the signed bytes only, then signs behind a human gate). Independent
of the Elixir build. See `docs/how-to/approver-apps.md` and `docs/how-to/approve-over-the-wire.md`.

Targets: `SA2AApproverCore` (library), `sa2a-approver` (CLI: `sign`, `approve`, `pubkey`,
`fixtures`), and on Apple platforms only `SA2AApproverUI` / `SA2AApproverMac` (SwiftUI). On Linux
`Package.swift` omits the SwiftUI targets and uses `swift-crypto` (module `Crypto`, pinned 3.9.1)
in place of CryptoKit. The Secure Enclave signer is compiled only where `Security` and
`LocalAuthentication` exist (`#if canImport(...)` in `Signer.swift`); the CLI's `--key enclave` is
refused on other platforms.

## What was verified (2026-11-17, Linux x86_64, Ubuntu 24.04)

Toolchain: `swift-6.0.3-RELEASE-ubuntu24.04` from download.swift.org, GPG signature verified against
the Swift 6.x release key (fingerprint 52BB 7E3D E28A 71BE 22EC 05FF EF80 A866 B47A 981F), extracted
to `/opt/swift/6.0.3`.

```bash
export PATH=/opt/swift/6.0.3/usr/bin:$PATH
cd sa2a-approver && swift build && swift test      # Build complete; 16 tests, 0 failures
```

The 16 tests are 12 in `CoreTests` (including verification of the Elixir-signed fixtures and the
Swift fixtures) and 4 in `WireApprovalTests` (stand-in unix-socket peer: request shape, framing,
refusal surfacing, bad inputs).

Interop with the real listener, from the repo root (needs python3 + `pip install cryptography`, and
`cd authority_service && MIX_ENV=test mix compile`):

```bash
python3 scripts/approver_wire_reference.py selftest --swift sa2a-approver/.build/debug/sa2a-approver
# 24 passed, 0 failed
```

This starts the real `AuthorityService.Listener` with a verifying `ApproverChannel.Mailbox`
(`scripts/authority_listener_harness.exs`, a separate `mix run` in `authority_service/`), then:
the Python reference (an independent implementation of the envelope/frame) gets acceptance and the
refusals `duplicate_approval` (same slot, first-wins slot, reused nonce), `approval_invalid` (wrong
signer, unregistered key, tampered signature, digest/generation mismatch, wrong audience, expired),
`malformed_approval` (6 shapes), `malformed_request`, `unknown_op`, and `mailbox_full` (1024-slot
cap). The Swift CLI `approve --key software` then submits to that listener (accepted; resubmit
refused `duplicate_approval`), its request body is captured and compared byte for byte with the
Python builder, and its signature is verified in Python.

Elixir side, from the repo root:

```bash
mix test --include serial test/ash_a2a/c2/approve_wire_crosscheck_test.exs test/ash_a2a/c2/approve_client_test.exs
# 9 passed
```

`ApproveClient.submit/5` accepted and refused by the real listener over a unix socket and over
mutual TLS (RSA test certs; wrong pinned CA and wrong client cert are refused at the transport);
`ApproveClient` frame bytes, pre-signature bytes and envelope bytes are byte-identical to the
Python reference; a Python signature verifies in `Sa2aCrypto.verify_envelope`.

No wire-format mismatch was found between Swift, Python and Elixir.

## Not verified

- Secure Enclave signing (`SecureEnclaveSigner`) and the biometric gate: macOS/iOS only, never
  compiled or run here. Neither were `SA2AApproverUI`, `SA2AApproverMac`, `iOS/`, or the macOS
  build of this package (CryptoKit path). Behavior on macOS is intended to be unchanged: the only
  edits are `#if canImport(CryptoKit)` import switches and the Linux-only manifest branch.
- Mutual TLS from Swift: not implemented (unix socket only).
- The Swift tests themselves still use a stand-in peer; real-listener interop is the Python-driven
  run above, not an XCTest. Only the debug build was exercised.
