# Approve Over The Wire

Status: PARTIAL. Elixir client, listener, Python reference and the Swift CLI (Linux, swift 6.0.3) were run against
the real listener on 2026-11-17; the Secure Enclave path, the macOS build and Swift mutual TLS were not. No row below
is CONFORMANT.

The authority service accepts signed human approvals on its `"approve"` op (only when it is
started with a `:mailbox`). The approval is deposited, not trusted: the issuer re-verifies it
when `issue` runs. Submitting grants nothing.

## Wire

One frame per connection, `<<len::32 big-endian, json>>`, answered by one frame over a unix
socket (or mutual TLS):

```json
{"op":"approve","approver":"alice","effect_digest":"sha256:...","generation":9,
 "approval":{"envelope":{"v":1,"alg":"ES256","kid":"...","profile":"classical",
   "signed_bytes_digest":"sha256:...","signature":"<b64url DER>","nonce":"...",
   "not_before":0,"expires":0,"audience":"..."},"message":"<b64url signed bytes>"}}
```

Reply `{"ok":true}` or `{"ok":false,"refusal":"duplicate_approval|malformed_approval|malformed_request|mailbox_full|unknown_op",...}`.

## Elixir client

```elixir
AshA2A.C2.ApproveClient.submit(%{authority_socket: "/run/authority.sock"},
  "alice", effect_digest, generation, approval)
# :ok | {:error, {:refused, code}} | {:error, :authority_transport_refused}
```

With `ctx.c2_tls` (see `AshA2A.C2.L07Tls.Transport`) it uses mutual TLS and never falls back
to the socket.

## sa2a-approver

```bash
swift run sa2a-approver approve --message msg.bin --effect effect.json \
  --key enclave --approver alice --socket /run/authority.sock
```

It applies the normal WYSIWYS gate (digest recomputed locally, summary rendered, biometric
signature) and then submits. Unix socket only; the Swift side has no TLS client. On Linux use
`--key software --key-file F` with `SA2A_APPROVER_DEV=1` (CI/dev only; not a human approval).

## What is and is not evidenced

| Claim | Status |
|---|---|
| `ApproveClient` against the real `AuthorityService.Listener`, unix socket and mutual TLS (RSA test certs), acceptance and refusals | Tested: `mix test --include serial test/ash_a2a/c2/approve_wire_crosscheck_test.exs`, with `approve_client_test.exs` 9 passed |
| `ApproveClient`, Python reference and Swift CLI produce the same bytes | Tested: Elixir vs Python pre-signature, envelope and frame bytes identical; Swift request body byte-identical to the Python builder |
| `sa2a-approver approve` against the real listener | Tested on Linux: `python3 scripts/approver_wire_reference.py selftest --swift sa2a-approver/.build/debug/sa2a-approver`, 24 passed |
| `swift build` / `swift test` | Linux x86_64, swift 6.0.3 + swift-crypto 3.9.1: build complete, 16 tests, 0 failures |
| Secure Enclave signer, biometric gate, SwiftUI apps, macOS build | UNVERIFIED: need macOS/iOS |
| Mutual TLS from Swift | NOT IMPLEMENTED |

Details and exact commands: `sa2a-approver/README.md`.
